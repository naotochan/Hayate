import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var keybindings: KeybindingStore
    @State private var recordingAction: ActionID?

    var body: some View {
        TabView {
            shortcutsTab
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 520, height: 560)
    }

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
