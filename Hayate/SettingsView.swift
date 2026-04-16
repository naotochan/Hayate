import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var keybindings: KeybindingStore
    @State private var recordingAction: ActionID?

    var body: some View {
        TabView {
            shortcutsTab
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            cacheTab
                .tabItem { Label("Cache", systemImage: "internaldrive") }
        }
        .frame(width: 520, height: 560)
    }

    // MARK: - Cache tab

    @AppStorage("previewCacheSizeLimitGB") private var cacheSizeLimitGB: Int = 10
    @AppStorage("previewCacheLocation") private var cacheLocationPath: String = ""
    @State private var cacheUsageBytes: Int64 = 0
    @State private var cacheFileCount: Int = 0
    @State private var showClearConfirmation = false

    private var effectiveCacheRoot: URL {
        if cacheLocationPath.isEmpty {
            return DiskCacheManager.defaultCacheRoot
        }
        return URL(fileURLWithPath: cacheLocationPath, isDirectory: true)
    }

    private var cacheTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Preview Cache")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.horizontal)
                .padding(.top)

            Form {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cache Location")
                                .fontWeight(.medium)
                            Text(effectiveCacheRoot.path)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button("Change…") {
                            chooseCacheLocation()
                        }
                        if !cacheLocationPath.isEmpty {
                            Button("Reset") {
                                cacheLocationPath = ""
                            }
                            .controlSize(.small)
                        }
                    }

                    Picker("Maximum Cache Size", selection: $cacheSizeLimitGB) {
                        Text("1 GB").tag(1)
                        Text("5 GB").tag(5)
                        Text("10 GB").tag(10)
                        Text("20 GB").tag(20)
                        Text("50 GB").tag(50)
                        Text("Unlimited").tag(0)
                    }
                    .pickerStyle(.menu)
                }

                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Current Usage")
                                .fontWeight(.medium)
                            Text("\(formattedSize(cacheUsageBytes)) — \(cacheFileCount) files")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Clear Cache") {
                            showClearConfirmation = true
                        }
                        .disabled(cacheFileCount == 0)
                    }
                }
            }
            .formStyle(.grouped)

            Text("Cache location changes take effect on next app launch.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            Spacer()
        }
        .onAppear { refreshCacheUsage() }
        .onChange(of: cacheSizeLimitGB) { _ in triggerEviction() }
        .alert("Clear Preview Cache?", isPresented: $showClearConfirmation) {
            Button("Clear", role: .destructive) { clearCache() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all \(cacheFileCount) cached preview files (\(formattedSize(cacheUsageBytes))). Previews will be regenerated as you browse.")
        }
    }

    private func chooseCacheLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.message = "Choose a folder to store preview cache files"
        if panel.runModal() == .OK, let url = panel.url {
            cacheLocationPath = url.path
        }
    }

    private func refreshCacheUsage() {
        Task {
            let cache = DiskCacheManager(cacheRoot: effectiveCacheRoot)
            let size = await cache.totalSize()
            let count = await cache.entryCount()
            await MainActor.run {
                cacheUsageBytes = size
                cacheFileCount = count
            }
        }
    }

    private func clearCache() {
        Task {
            let cache = DiskCacheManager(cacheRoot: effectiveCacheRoot)
            await cache.clear()
            await MainActor.run {
                cacheUsageBytes = 0
                cacheFileCount = 0
            }
        }
    }

    private func triggerEviction() {
        guard cacheSizeLimitGB > 0 else { return }
        let limit = Int64(cacheSizeLimitGB) * 1_073_741_824
        Task {
            let cache = DiskCacheManager(cacheRoot: effectiveCacheRoot)
            await cache.evict(maxBytes: limit)
            refreshCacheUsage()
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Shortcuts tab

    private var shortcutsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Reset to Defaults") {
                    keybindings.resetToDefaults()
                    recordingAction = nil
                }
            }
            .padding(.horizontal)
            .padding(.top)

            Text("Rating keys (0–5), ⎋, and ⌘, are fixed and cannot be rebound.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            List {
                ForEach(ActionID.Category.allCases) { category in
                    Section(category.rawValue) {
                        ForEach(actions(in: category)) { action in
                            row(for: action)
                        }
                    }
                }
            }
        }
    }

    private func actions(in category: ActionID.Category) -> [ActionID] {
        ActionID.allCases.filter { $0.category == category }
    }

    private func row(for action: ActionID) -> some View {
        HStack {
            Text(action.title)
            Spacer()
            if recordingAction == action {
                ShortcutRecorder(
                    onCapture: { shortcut in
                        keybindings.bind(shortcut, to: action)
                        recordingAction = nil
                    },
                    onCancel: {
                        recordingAction = nil
                    }
                )
            } else {
                Text(keybindings.bindings[action]?.display ?? "—")
                    .foregroundColor(.secondary)
                    .font(.system(.body, design: .monospaced))
                Button("Record") {
                    recordingAction = action
                }
                .controlSize(.small)
                if keybindings.bindings[action] != nil {
                    Button {
                        keybindings.clear(action)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear binding")
                }
            }
        }
    }
}

/// One-shot recorder: pops up a capture field that consumes the next keyDown
/// and hands the result back via `onCapture`.
private struct ShortcutRecorder: NSViewRepresentable {
    let onCapture: (Shortcut) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel
    }

    final class RecorderView: NSView {
        var onCapture: ((Shortcut) -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            bounds.fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.controlAccentColor,
            ]
            let text = "Press a key…"
            let size = (text as NSString).size(withAttributes: attrs)
            let origin = NSPoint(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2
            )
            (text as NSString).draw(at: origin, withAttributes: attrs)
        }

        override var intrinsicContentSize: NSSize {
            NSSize(width: 120, height: 22)
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { // escape — cancel
                onCancel?()
                return
            }
            guard let shortcut = Shortcut(event: event) else {
                onCancel?()
                return
            }
            onCapture?(shortcut)
        }
    }
}
