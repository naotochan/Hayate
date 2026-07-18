import SwiftUI

/// Full-screen cheat sheet of current keybindings. Dismiss with ⎋ or the
/// same toggle shortcut (? by default).
struct ShortcutsHelpOverlay: View {
    let bindings: [ActionID: Shortcut]
    let triageMode: Bool
    let onDismiss: () -> Void

    @EnvironmentObject private var L: LocalizationStore

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L.t("Keyboard Shortcuts", ja: "キーボードショートカット"))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Text(L.t("? or / or ⎋ to close", ja: "? または / または ⎋ で閉じる"))
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

                Divider().background(Color.white.opacity(0.12))

                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 28),
                            GridItem(.flexible(), spacing: 28),
                        ],
                        alignment: .leading,
                        spacing: 22
                    ) {
                        ForEach(sections, id: \.title) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.45))
                                    .textCase(.uppercase)
                                    .tracking(0.6)

                                ForEach(section.rows, id: \.label) { row in
                                    HStack(spacing: 12) {
                                        Text(row.keys)
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(Color.white.opacity(0.1))
                                            .cornerRadius(4)
                                            .frame(minWidth: 52, alignment: .center)
                                        Text(row.label)
                                            .font(.system(size: 12))
                                            .foregroundColor(.white.opacity(0.85))
                                            .lineLimit(2)
                                        Spacer(minLength: 0)
                                    }
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .frame(maxWidth: 640, maxHeight: 520)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 0.97)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.45), radius: 28, y: 12)
            .padding(24)
        }
        .transition(.opacity)
    }

    // MARK: - Content

    private struct Section {
        let title: String
        let rows: [Row]
    }

    private struct Row {
        let keys: String
        let label: String
    }

    private var sections: [Section] {
        var result: [Section] = []

        // Fixed keys that never go through KeybindingStore.
        // Labels stay English — short chrome, same as the rest of the cheat sheet.
        var fixed: [Row] = [
            Row(keys: "← →", label: "Previous / next photo"),
            Row(keys: "⎋", label: "Cancel / exit mode / reset zoom"),
        ]
        if !triageMode {
            fixed.append(Row(keys: "0–5", label: "Set star rating"))
        }
        result.append(Section(title: "Always", rows: fixed))

        for category in ActionID.Category.allCases {
            let actions = ActionID.allCases.filter { $0.category == category }
            let rows = actions.compactMap { action -> Row? in
                guard let shortcut = bindings[action] else { return nil }
                return Row(keys: shortcut.display, label: action.helpTitle(triageMode: triageMode))
            }
            if !rows.isEmpty {
                result.append(Section(title: category.title, rows: rows))
            }
        }
        return result
    }
}

extension ActionID {
    /// Overlay-friendly titles that reflect Keep/Maybe/Out vs stars.
    /// Kept in English on purpose (product chrome).
    func helpTitle(triageMode: Bool) -> String {
        switch self {
        case .toggleFavorite:
            return triageMode ? "Keep" : "Toggle favorite"
        case .toggleRejected:
            return triageMode ? "Out" : "Toggle rejected"
        case .setTriageMaybe:
            return triageMode ? "Maybe" : "Maybe (triage)"
        case .toggleShortcutsHelp:
            return "Show / hide this cheat sheet"
        default:
            return title
        }
    }
}
