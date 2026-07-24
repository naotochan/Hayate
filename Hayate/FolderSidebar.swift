import SwiftUI

/// Cursor-style left pane: pinned folders + recent folders, with collapse.
struct FolderSidebar: View {
    @EnvironmentObject private var session: CullingSession
    @EnvironmentObject private var keybindings: KeybindingStore
    @EnvironmentObject private var L: LocalizationStore
    @AppStorage("cullingProfileTriage") private var cullingProfileTriage = true

    let isOpen: Bool
    let onToggle: () -> Void
    let onOpenFolder: () -> Void
    let onSelect: (URL) -> Void
    /// Open the export sheet for the current session (⌘E).
    var onExport: () -> Void = {}
    /// Reload the viewer after Out / rejected photos were trashed from the menu.
    var onAfterTrashOut: () -> Void = {}
    /// Show the shortcuts cheat sheet (?).
    var onShowShortcuts: () -> Void = {}

    @State private var showTrashOutConfirmation = false

    private let openWidth: CGFloat = 236
    private let closedWidth: CGFloat = 44

    private var outCount: Int {
        session.files.reduce(0) { count, url in
            session.entries[url.lastPathComponent]?.isRejected == true ? count + 1 : count
        }
    }

    private var outIndices: Set<Int> {
        Set(session.files.enumerated().compactMap { index, url in
            session.entries[url.lastPathComponent]?.isRejected == true ? index : nil
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isOpen {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        pinnedSection
                        recentSection
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onboardingAnchor(.folderList)
                }
                shortcutsFooter
            } else {
                Spacer(minLength: 0)
                collapsedHelpButton
            }
        }
        .frame(width: isOpen ? openWidth : closedWidth, alignment: .top)
        .frame(maxHeight: .infinity)
        .background(HayateTheme.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(HayateTheme.separator)
                .frame(width: 1)
        }
        .animation(.easeOut(duration: 0.18), value: isOpen)
        .confirmationDialog(
            cullingProfileTriage
                ? "Move \(outCount) Out photos to Trash?"
                : "Move \(outCount) rejected photos to Trash?",
            isPresented: $showTrashOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                session.deleteFilesAtIndices(outIndices)
                onAfterTrashOut()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Shortcuts footer

    private var shortcutsFooter: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(HayateTheme.separator)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 5) {
                Text(L.t("Shortcuts", ja: "ショートカット"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(HayateTheme.fg(0.38))
                    .textCase(.uppercase)
                    .tracking(0.6)

                ForEach(commonShortcutHints, id: \.label) { hint in
                    HStack(spacing: 8) {
                        Text(hint.keys)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(HayateTheme.fg(0.88))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(HayateTheme.wash(0.1))
                            .cornerRadius(4)
                            .frame(minWidth: 48, alignment: .center)
                        Text(hint.label)
                            .font(.system(size: 11))
                            .foregroundColor(HayateTheme.fg(0.62))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }

                Button(action: onShowShortcuts) {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 11, weight: .medium))
                        Text(L.t("All shortcuts", ja: "すべてのショートカット"))
                            .font(.system(size: 11, weight: .medium))
                        Spacer(minLength: 0)
                        Text(keyDisplay(for: .toggleShortcutsHelp) ?? "?")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(HayateTheme.fg(0.4))
                    }
                    .foregroundColor(HayateTheme.fg(0.72))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(HayateTheme.wash(0.06))
                    .cornerRadius(6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L.t("Show all keyboard shortcuts", ja: "キーボードショートカット一覧を表示"))
                .padding(.top, 4)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
    }

    private var collapsedHelpButton: some View {
        Button(action: onShowShortcuts) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(HayateTheme.fg(0.65))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L.t("Keyboard shortcuts", ja: "キーボードショートカット"))
        .padding(.bottom, 10)
    }

    private struct ShortcutHint: Equatable {
        let keys: String
        let label: String
    }

    private var commonShortcutHints: [ShortcutHint] {
        var rows: [ShortcutHint] = []
        let nav = [keyDisplay(for: .navigateBack), keyDisplay(for: .navigateForward)]
            .compactMap { $0 }
            .joined(separator: " ")
        if !nav.isEmpty {
            rows.append(ShortcutHint(
                keys: nav,
                label: L.t("Prev / Next", ja: "前へ / 次へ")
            ))
        }

        if cullingProfileTriage {
            let triage = [
                keyDisplay(for: .toggleFavorite),
                keyDisplay(for: .setTriageMaybe),
                keyDisplay(for: .toggleRejected),
            ].compactMap { $0 }.joined(separator: " ")
            if !triage.isEmpty {
                // Keep / Maybe / Out are product terms — same in both languages.
                rows.append(ShortcutHint(keys: triage, label: "Keep / Maybe / Out"))
            }
        } else {
            rows.append(ShortcutHint(keys: "1–5", label: L.t("Rate", ja: "評価")))
            if let k = keyDisplay(for: .toggleFavorite) {
                rows.append(ShortcutHint(
                    keys: k,
                    label: L.t("Favorite", ja: "お気に入り")
                ))
            }
        }

        if let g = keyDisplay(for: .toggleGrid) {
            rows.append(ShortcutHint(keys: g, label: L.t("Grid", ja: "グリッド")))
        }
        rows.append(ShortcutHint(keys: "⌘E", label: L.t("Export", ja: "書き出し")))
        return rows
    }

    private func keyDisplay(for action: ActionID) -> String? {
        keybindings.bindings[action]?.display
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: onToggle) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(HayateTheme.fg(0.75))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Hide sidebar (⌘B)" : "Show sidebar (⌘B)")

            if isOpen {
                Spacer(minLength: 0)

                Button(action: onOpenFolder) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(HayateTheme.fg(0.75))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open folder…")
                .onboardingAnchor(.openFolderButton)
            }
        }
        .padding(.horizontal, isOpen ? 10 : 8)
        .padding(.vertical, 10)
    }

    // MARK: - Sections

    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Pinned")
            ForEach(session.pinnedFolders, id: \.path) { url in
                folderRow(url, pinned: true) {
                    session.unpinFolder(url)
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Recent")
            ForEach(session.unpinnedRecentFolders, id: \.path) { url in
                folderRow(url, pinned: false) {
                    session.pinFolder(url)
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(HayateTheme.fg(0.38))
            .textCase(.uppercase)
            .tracking(0.6)
            .padding(.horizontal, 6)
    }

    private func folderRow(
        _ url: URL,
        pinned: Bool,
        pinAction: @escaping () -> Void
    ) -> some View {
        let available = FileManager.default.isReadableFile(atPath: url.path)
        let isCurrent = session.folderURL?.standardizedFileURL.path == url.standardizedFileURL.path
        let pinTitle = pinned ? "Unpin" : "Pin"
        let folderColor = session.color(for: url)
        let iconColor: Color = {
            if !available { return HayateTheme.fg(0.22) }
            if let tint = folderColor.swatchColor { return tint }
            return isCurrent ? Color.accentColor : HayateTheme.fg(0.55)
        }()

        return HStack(spacing: 4) {
            Button {
                guard available else { return }
                onSelect(url)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12))
                        .foregroundColor(iconColor)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent)
                            .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                            .foregroundColor(available
                                             ? (isCurrent ? HayateTheme.fg(1) : HayateTheme.fg(0.82))
                                             : HayateTheme.fg(0.32))
                            .lineLimit(1)
                        Text(url.deletingLastPathComponent().path)
                            .font(.system(size: 9))
                            .foregroundColor(HayateTheme.fg(available ? 0.28 : 0.16))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.leading, 8)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!available)
            .help(available ? url.path : "This folder is not currently reachable")

            Button(action: pinAction) {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(pinned ? .accentColor.opacity(0.85) : HayateTheme.fg(0.35))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(pinTitle)
            .padding(.trailing, 4)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isCurrent ? HayateTheme.wash(0.1) : Color.clear)
        )
        .contextMenu {
            Button("Show in Finder") {
                guard available else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .disabled(!available)

            if isCurrent {
                Divider()
                Button("Export Picks…") {
                    onExport()
                }
                .disabled(session.files.isEmpty)
                Button(
                    cullingProfileTriage ? "Move Out to Trash…" : "Move Rejected to Trash…",
                    role: .destructive
                ) {
                    showTrashOutConfirmation = true
                }
                .disabled(outCount == 0)
            }

            Divider()
            folderColorMenu(for: url, current: folderColor)

            if session.recentFolders.contains(where: {
                $0.standardizedFileURL.path == url.standardizedFileURL.path
            }) {
                Divider()
                Button("Remove from Recent", role: .destructive) {
                    session.removeFromRecents(url)
                }
            }
        }
    }

    @ViewBuilder
    private func folderColorMenu(for url: URL, current: FolderColor) -> some View {
        // Product term — keep English in both languages (like Keep / Maybe / Out).
        Menu("Color") {
            Button {
                session.setFolderColor(.none, for: url)
            } label: {
                Label {
                    Text(FolderColor.none.menuTitle)
                } icon: {
                    Image(nsImage: FolderColor.none.menuDotImage(selected: current == .none))
                }
            }
            Divider()
            ForEach(FolderColor.swatches) { color in
                Button {
                    session.setFolderColor(color, for: url)
                } label: {
                    Label {
                        Text(color.menuTitle)
                    } icon: {
                        Image(nsImage: color.menuDotImage(selected: current == color))
                    }
                }
            }
        }
    }
}
