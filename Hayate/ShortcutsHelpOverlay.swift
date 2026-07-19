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
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    Text(L.t("Keyboard Shortcuts", ja: "キーボードショートカット"))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer(minLength: 8)
                    Text(L.t("Press ? / ⎋ to close", ja: "? または ⎋ で閉じる"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.55))
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 14)

                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 1)

                ScrollView {
                    HStack(alignment: .top, spacing: 36) {
                        column(for: leftSections)
                        column(for: rightSections)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
            }
            .frame(maxWidth: 720, maxHeight: 560)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(nsColor: NSColor(red: 0.14, green: 0.14, blue: 0.15, alpha: 0.98)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.5), radius: 32, y: 14)
            .padding(28)
        }
        .transition(.opacity)
    }

    // MARK: - Columns

    @ViewBuilder
    private func column(for sections: [Section]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(sections, id: \.title) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.title)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.5))
                        .textCase(.uppercase)
                        .tracking(0.8)

                    VStack(spacing: 2) {
                        ForEach(section.rows, id: \.label) { row in
                            shortcutRow(row)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortcutRow(_ row: Row) -> some View {
        HStack(spacing: 14) {
            Text(row.keys)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .frame(minWidth: 72, alignment: .center)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )

            Text(row.label)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(Color.white.opacity(0.92))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
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

    /// Cull-first order on the left; secondary tools on the right.
    private var leftSections: [Section] {
        let lang = L.resolved
        var result: [Section] = []

        var essentials: [Row] = [
            Row(keys: navKeys, label: lang.t("Previous / next photo", ja: "前 / 次の写真")),
        ]
        if triageMode {
            essentials.append(contentsOf: [
                Row(keys: key(.toggleFavorite) ?? "K", label: "Keep"),
                Row(keys: key(.setTriageMaybe) ?? "M", label: "Maybe"),
                Row(keys: key(.toggleRejected) ?? "O", label: "Out"),
            ])
        } else {
            essentials.append(Row(keys: "0–5", label: lang.t("Star rating", ja: "星評価")))
            if let k = key(.toggleFavorite) {
                essentials.append(Row(keys: k, label: lang.t("Favorite", ja: "お気に入り")))
            }
            if let o = key(.toggleRejected) {
                essentials.append(Row(keys: o, label: lang.t("Reject", ja: "リジェクト")))
            }
        }
        essentials.append(Row(
            keys: "⎋",
            label: lang.t("Cancel / exit / reset zoom", ja: "キャンセル・終了・ズームリセット")
        ))
        result.append(Section(
            title: lang.t("Essentials", ja: "基本"),
            rows: essentials
        ))

        var viewRows: [Row] = []
        for action in [ActionID.toggleGrid, .toggleCompare, .toggleFitZoom] {
            if let shortcut = bindings[action] {
                viewRows.append(Row(
                    keys: shortcut.display,
                    label: action.helpTitle(triageMode: triageMode, lang: lang)
                ))
            }
        }
        viewRows.append(Row(keys: "⌘E", label: lang.t("Export picks", ja: "選別結果を書き出す")))
        if !viewRows.isEmpty {
            result.append(Section(title: lang.t("View & export", ja: "表示・書き出し"), rows: viewRows))
        }

        return result
    }

    private var rightSections: [Section] {
        let lang = L.resolved
        var result: [Section] = []

        var tools: [Row] = []
        for action in [
            ActionID.toggleFocusPeaking,
            .toggleInfo,
            .toggleHistogram,
            .toggleSidebar,
            .toggleShortcutsHelp,
        ] {
            if let shortcut = bindings[action] {
                tools.append(Row(
                    keys: shortcut.display,
                    label: action.helpTitle(triageMode: triageMode, lang: lang)
                ))
            }
        }
        if !tools.isEmpty {
            result.append(Section(title: lang.t("Tools", ja: "ツール"), rows: tools))
        }

        var edit: [Row] = []
        for action in [ActionID.deletePhoto, .undo, .selectAllGrid, .openFolder] {
            if let shortcut = bindings[action] {
                edit.append(Row(
                    keys: shortcut.display,
                    label: action.helpTitle(triageMode: triageMode, lang: lang)
                ))
            }
        }
        if !edit.isEmpty {
            result.append(Section(title: lang.t("Edit & file", ja: "編集・ファイル"), rows: edit))
        }

        var compare: [Row] = []
        for action in [ActionID.pickCompare, .skipNextBaseline] {
            if let shortcut = bindings[action] {
                compare.append(Row(
                    keys: shortcut.display,
                    label: action.helpTitle(triageMode: triageMode, lang: lang)
                ))
            }
        }
        if !compare.isEmpty {
            result.append(Section(title: lang.t("Compare", ja: "比較"), rows: compare))
        }

        return result
    }

    private var navKeys: String {
        let pair = [key(.navigateBack), key(.navigateForward)].compactMap { $0 }
        if pair.count == 2 { return "\(pair[0])  \(pair[1])" }
        return "←  →"
    }

    private func key(_ action: ActionID) -> String? {
        bindings[action]?.display
    }
}
