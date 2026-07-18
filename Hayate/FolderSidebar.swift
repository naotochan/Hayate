import SwiftUI

/// Cursor-style left pane: pinned folders + recent folders, with collapse.
struct FolderSidebar: View {
    @EnvironmentObject private var session: CullingSession

    let isOpen: Bool
    let onToggle: () -> Void
    let onOpenFolder: () -> Void
    let onSelect: (URL) -> Void

    private let openWidth: CGFloat = 236
    private let closedWidth: CGFloat = 44

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
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(width: isOpen ? openWidth : closedWidth, alignment: .top)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 1)
        }
        .animation(.easeOut(duration: 0.18), value: isOpen)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: onToggle) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
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
                        .foregroundColor(.white.opacity(0.75))
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
            if session.pinnedFolders.isEmpty {
                emptyHint("Pin folders you revisit often")
            } else {
                ForEach(session.pinnedFolders, id: \.path) { url in
                    folderRow(url, pinActionTitle: "Unpin") {
                        session.unpinFolder(url)
                    }
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Recent")
            if session.unpinnedRecentFolders.isEmpty {
                emptyHint("Opened folders appear here")
            } else {
                ForEach(session.unpinnedRecentFolders, id: \.path) { url in
                    folderRow(url, pinActionTitle: "Pin") {
                        session.pinFolder(url)
                    }
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white.opacity(0.38))
            .textCase(.uppercase)
            .tracking(0.6)
            .padding(.horizontal, 6)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.white.opacity(0.28))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
    }

    private func folderRow(
        _ url: URL,
        pinActionTitle: String,
        pinAction: @escaping () -> Void
    ) -> some View {
        let available = FileManager.default.isReadableFile(atPath: url.path)
        let isCurrent = session.folderURL?.standardizedFileURL.path == url.standardizedFileURL.path

        return HStack(spacing: 4) {
            Button {
                guard available else { return }
                onSelect(url)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12))
                        .foregroundColor(available
                                         ? (isCurrent ? Color.accentColor : Color.white.opacity(0.55))
                                         : Color.white.opacity(0.22))
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent)
                            .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                            .foregroundColor(available
                                             ? (isCurrent ? .white : .white.opacity(0.82))
                                             : .white.opacity(0.32))
                            .lineLimit(1)
                        Text(url.deletingLastPathComponent().path)
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(available ? 0.28 : 0.16))
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
                Image(systemName: pinActionTitle == "Pin" ? "pin" : "pin.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(pinActionTitle == "Pin" ? .white.opacity(0.35) : .accentColor.opacity(0.85))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(pinActionTitle)
            .padding(.trailing, 4)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isCurrent ? Color.white.opacity(0.1) : Color.clear)
        )
        .contextMenu {
            Button("Open") {
                guard available else { return }
                onSelect(url)
            }
            .disabled(!available)
            Divider()
            Button(pinActionTitle, action: pinAction)
            if session.recentFolders.contains(where: {
                $0.standardizedFileURL.path == url.standardizedFileURL.path
            }) {
                Button("Remove from Recent", role: .destructive) {
                    session.removeFromRecents(url)
                }
            }
        }
    }
}
