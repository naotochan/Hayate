import SwiftUI

/// Bottom-of-screen filmstrip and status bar for the single-photo view.
extension ContentView {

    var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 2) {
                    ForEach(Array(session.files.enumerated()), id: \.offset) { index, url in
                        thumbnailView(for: url, index: index)
                            .id(index)
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(height: 68)
            .background(Color.black.opacity(0.6))
            .onChange(of: session.currentIndex) { _, newIndex in
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
            .onAppear {
                proxy.scrollTo(session.currentIndex, anchor: .center)
            }
        }
    }

    private func thumbnailView(for url: URL, index: Int) -> some View {
        let isCurrent = index == session.currentIndex
        let entry = session.entries[url.lastPathComponent]

        return ZStack(alignment: .bottomTrailing) {
            if let nsImage = thumbnails[url] {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 60)
                    .clipped()
                    .saturation(CullThumbnailStyle.saturation(for: entry, enabled: colorizeKeepOnly))
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 80, height: 60)
                    .onAppear { loadThumbnail(for: url) }
            }

            // Rating/favorite/rejected indicator
            PhotoBadgeView(
                entry: entry,
                iconSize: 7,
                starSize: 8,
                spacing: 1,
                padding: 2,
                cornerRadius: 2,
                compact: true,
                triageStyle: cullingProfileTriage
            )
                .padding(2)
        }
        .border(isCurrent ? Color.white : Color.clear, width: 2)
        .opacity(isCurrent ? 1.0 : 0.6)
        .onTapGesture {
            session.currentIndex = index
        }
    }

    var statusBar: some View {
        HStack {
            if !session.files.isEmpty {
                folderSwitcher

                Divider()
                    .frame(height: 14)

                // Position
                Text("\(session.currentIndex + 1)/\(session.files.count)")
                    .monospacedDigit()

                Spacer()

                // File name
                if let file = session.currentFile {
                    Text(file.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                // Rating / triage status
                if cullingProfileTriage {
                    triageStatusControls
                } else {
                    HStack(spacing: 2) {
                        let rating = session.currentEntry?.rating ?? 0
                        let isFav = session.currentEntry?.isFavorite ?? false
                        let isRej = session.currentEntry?.isRejected ?? false
                        ForEach(1...5, id: \.self) { i in
                            Image(systemName: i <= rating ? "star.fill" : "star")
                                .foregroundColor(i <= rating ? .yellow : .gray)
                                .font(.system(size: 12))
                        }
                        Image(systemName: isFav ? "heart.fill" : "heart")
                            .foregroundColor(isFav ? .red : .gray)
                            .font(.system(size: 12))
                            .padding(.leading, 4)
                        Image(systemName: isRej ? "xmark.circle.fill" : "xmark.circle")
                            .foregroundColor(isRej ? .orange : .gray)
                            .font(.system(size: 12))
                            .padding(.leading, 2)
                    }
                }

                Spacer()

                // Cull mode / focus peaking indicators
                if cullModeDraft {
                    Text("DRAFT")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.cyan)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.cyan.opacity(0.2))
                        .cornerRadius(3)
                        .help("Draft mode: embedded JPEG previews. Press F or zoom for full RAW.")
                }
                if focusPeakingEnabled {
                    Text("PEAK")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.red)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.red.opacity(0.2))
                        .cornerRadius(3)
                }

                // Decode time
                if decodeTimeMs > 0 {
                    Text(String(format: "%.0fms", decodeTimeMs))
                        .foregroundColor(.gray)
                        .font(.system(size: 11, design: .monospaced))
                }

                // Background build progress
                if buildProgress.isBuilding {
                    Text("Building previews: \(buildProgress.completed)/\(buildProgress.total)")
                        .foregroundColor(.gray)
                        .font(.system(size: 11, design: .monospaced))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .foregroundColor(.white)
        .font(.system(size: 13))
    }

    /// The current folder doubles as an in-context switcher. File > Open
    /// Recent remains available, but this keeps folder navigation discoverable
    /// while the user is actively culling.
    var folderSwitcher: some View {
        Menu {
            Button {
                session.requestOpenFolder()
            } label: {
                Label("Open Folder…", systemImage: "folder.badge.plus")
            }

            let recent = session.recentFolders.filter { $0 != session.folderURL }
            if !recent.isEmpty {
                Divider()
                Section("Recent Folders") {
                    ForEach(recent, id: \.self) { url in
                        Button {
                            session.requestOpen(folder: url)
                        } label: {
                            Label(url.lastPathComponent, systemImage: "folder")
                        }
                        .help(url.path)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                Text(session.folderURL?.lastPathComponent ?? "Folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.55)
            }
            .foregroundColor(.white.opacity(0.85))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(session.folderURL?.path ?? "Switch folder")
        .accessibilityLabel("Switch photo folder")
    }

    /// Keep / Maybe / Out controls for triage profile (K / M / O).
    private var triageStatusControls: some View {
        let state = CullingSession.TriageState.of(session.currentEntry)
        return HStack(spacing: 6) {
            triageChip("Keep", key: "K", active: state == .keep, color: .red) {
                session.setTriage(.keep)
            }
            triageChip("Maybe", key: "M", active: state == .maybe, color: .yellow) {
                session.setTriage(.maybe)
            }
            triageChip("Out", key: "O", active: state == .out, color: .orange) {
                session.setTriage(.out)
            }
        }
    }

    private func triageChip(
        _ title: String,
        key: String,
        active: Bool,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                    .fontWeight(active ? .bold : .regular)
                Text(key)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .opacity(0.7)
            }
            .font(.system(size: 11))
            .foregroundColor(active ? color : .gray)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(active ? color.opacity(0.2) : Color.clear)
            .cornerRadius(3)
        }
        .buttonStyle(.plain)
    }
}
