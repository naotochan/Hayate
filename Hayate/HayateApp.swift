import SwiftUI
import Metal
import CoreImage
import Sparkle

@main
struct HayateApp: App {
    @StateObject private var session = CullingSession()

    private let device: MTLDevice
    /// Single shared CIContext bound to the default Metal device.
    /// CIContext is thread-safe and expensive to create (GPU shader compilation on first use).
    private let ciContext: CIContext
    private let updaterController: SPUStandardUpdaterController

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        self.device = device
        self.ciContext = CIContext(mtlDevice: device)
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
                .environment(\.ciContext, ciContext)
                .environment(\.metalDevice, device)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
    }
}

// MARK: - Sparkle Update Menu

struct CheckForUpdatesView: View {
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel
    let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
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
