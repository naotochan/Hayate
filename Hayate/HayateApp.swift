import SwiftUI
import Metal
import CoreImage
import Sparkle

/// Holds the CIContext created asynchronously to avoid blocking the main thread
/// during GPU shader compilation on first use.
@MainActor
final class CIContextHolder: ObservableObject {
    @Published var ciContext: CIContext?

    func initialize(device: MTLDevice) {
        guard ciContext == nil else { return }
        let device = device
        Task.detached {
            let ctx = CIContext(mtlDevice: device)
            await MainActor.run { self.ciContext = ctx }
        }
    }
}

/// Opens folders dropped on the Dock icon or passed via `open -a Hayate <folder>`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set from SwiftUI once the session is ready. Flushes any folder that
    /// arrived earlier (launch-with-folder race).
    var onOpenFolder: ((URL) -> Void)? {
        didSet {
            if let url = pendingFolder, let handler = onOpenFolder {
                pendingFolder = nil
                handler(url)
            }
        }
    }

    private var pendingFolder: URL?

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                if let handler = onOpenFolder {
                    handler(url)
                } else {
                    pendingFolder = url
                }
                return
            }
        }
    }
}

@main
struct HayateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = CullingSession()
    @StateObject private var ciContextHolder = CIContextHolder()
    @StateObject private var keybindings = KeybindingStore()
    @StateObject private var localization = LocalizationStore()
    @AppStorage("appAppearance") private var appAppearance: AppAppearance = .system

    private let device: MTLDevice
    private let updaterController: SPUStandardUpdaterController

    private static var windowTitle: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Hayate (\(version) · build \(build))"
    }

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        self.device = device
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        WindowGroup(Self.windowTitle) {
            ContentView()
                .environmentObject(session)
                .environmentObject(keybindings)
                .environmentObject(localization)
                .environment(\.ciContext, ciContextHolder.ciContext)
                .environment(\.metalDevice, device)
                .preferredColorScheme(appAppearance.preferredColorScheme)
                .id(localization.language)
                .onAppear {
                    appAppearance.applyToApp()
                    appDelegate.onOpenFolder = { [session] url in
                        session.requestOpen(folder: url)
                    }
                    // `Hayate.app -- /path/to/folder` for demos / scripting.
                    for arg in CommandLine.arguments.dropFirst() where !arg.hasPrefix("-") {
                        let url = URL(fileURLWithPath: arg)
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                           isDir.boolValue {
                            session.requestOpen(folder: url)
                            break
                        }
                    }
                }
                .onChange(of: appAppearance) { _, newValue in
                    newValue.applyToApp()
                }
                .task {
                    ciContextHolder.initialize(device: device)
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(localization.t("Open Folder…", ja: "フォルダを開く…")) {
                    session.requestOpenFolder()
                }
                .keyboardShortcut("o", modifiers: .command)

                Menu("Open Recent") {
                    ForEach(session.recentFolders, id: \.path) { url in
                        Button(url.lastPathComponent) {
                            session.requestOpen(folder: url)
                        }
                        .help(url.path)
                    }
                }
                .disabled(session.recentFolders.isEmpty)

                Divider()

                Button(localization.t("Export Picks…", ja: "選別結果を書き出す…")) {
                    session.requestExport()
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(session.files.isEmpty)
            }
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
                    .environmentObject(localization)
            }
            CommandGroup(before: .help) {
                Button(localization.t("Welcome Guide", ja: "ようこそガイド")) {
                    NotificationCenter.default.post(name: .showOnboarding, object: nil)
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(keybindings)
                .environmentObject(localization)
                .preferredColorScheme(appAppearance.preferredColorScheme)
                // Recreate Settings when appearance flips so Form grouped
                // backgrounds don't stay stuck on the previous scheme.
                .id("\(localization.language.rawValue)-\(appAppearance.rawValue)")
                .onAppear { appAppearance.applyToApp() }
                .onChange(of: appAppearance) { _, newValue in
                    newValue.applyToApp()
                }
        }
        .defaultSize(width: HayateChrome.windowMinWidth, height: HayateChrome.windowMinHeight)
    }
}

// MARK: - Sparkle Update Menu

struct CheckForUpdatesView: View {
    @EnvironmentObject private var L: LocalizationStore
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel
    let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button(L.t("Check for Updates…", ja: "アップデートを確認…"), action: updater.checkForUpdates)
            .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
    }
}

@MainActor
private final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }
}

// MARK: - Environment Keys

private struct CIContextKey: EnvironmentKey {
    static let defaultValue: CIContext? = nil
}

private struct MetalDeviceKey: EnvironmentKey {
    static let defaultValue: MTLDevice? = nil
}

extension EnvironmentValues {
    var ciContext: CIContext? {
        get { self[CIContextKey.self] }
        set { self[CIContextKey.self] = newValue }
    }

    var metalDevice: MTLDevice? {
        get { self[MetalDeviceKey.self] }
        set { self[MetalDeviceKey.self] = newValue }
    }
}
