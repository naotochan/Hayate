import SwiftUI

/// Grid view: thumbnail overview with filtering and multi-selection.
extension ContentView {

    /// Layout constants shared by the LazyVGrid definition and the column
    /// count estimate — change together or ↑↓ row navigation drifts.
    static let gridItemMinWidth: CGFloat = 160
    static let gridItemMaxWidth: CGFloat = 220
    static let gridSpacing: CGFloat = 6
    static let gridPadding: CGFloat = 8

    var filteredFiles: [(index: Int, url: URL)] {
        session.files.enumerated().compactMap { index, url in
            let entry = session.entries[url.lastPathComponent]
            let triage = CullingSession.TriageState.of(entry)
            switch gridFilter {
            case .all: return (index, url)
            case .favorites, .keep: return entry?.isFavorite == true ? (index, url) : nil
            case .rejected, .out: return entry?.isRejected == true ? (index, url) : nil
            case .rated: return (entry?.rating ?? 0) > 0 ? (index, url) : nil
            case .maybe: return triage == .maybe ? (index, url) : nil
            case .unrated: return (entry?.rating ?? 0) == 0 ? (index, url) : nil
            case .undecided: return triage == .undecided ? (index, url) : nil
            }
        }
    }

    var gridView: some View {
        VStack(spacing: 0) {
            // Filter bar
            HStack(spacing: 8) {
                folderSwitcher

                Divider()
                    .frame(height: 14)

                ForEach(GridFilter.visible(triage: cullingProfileTriage), id: \.self) { filter in
                    Button {
                        gridFilter = filter
                    } label: {
                        Text(filter.title)
                            .font(.system(size: 11, weight: gridFilter == filter ? .bold : .regular))
                            .foregroundColor(gridFilter == filter ? HayateTheme.fg(1) : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(gridFilter == filter ? HayateTheme.wash(0.2) : Color.clear)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Text("\(filteredFiles.count) / \(session.files.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray)

                if !selectedIndices.isEmpty {
                    Text(L.t("\(selectedIndices.count) selected", ja: "\(selectedIndices.count) 件選択"))
                        .font(.system(size: 11))
                        .foregroundColor(HayateTheme.fg(1))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.5))
                        .cornerRadius(3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .onChange(of: cullingProfileTriage) { _, _ in
                if !GridFilter.visible(triage: cullingProfileTriage).contains(gridFilter) {
                    gridFilter = .all
                }
            }

            // Grid — one LazyVGrid per scene so separators span the full width.
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: Self.gridSpacing) {
                            ForEach(Array(sceneChunks.enumerated()), id: \.element.id) { chunkIndex, chunk in
                                if chunkIndex > 0 {
                                    sceneSeparator
                                }
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: Self.gridItemMinWidth, maximum: Self.gridItemMaxWidth), spacing: Self.gridSpacing)],
                                    spacing: Self.gridSpacing
                                ) {
                                    ForEach(chunk.items, id: \.index) { item in
                                        gridCell(for: item.url, index: item.index)
                                            .id(item.index)
                                    }
                                }
                            }
                        }
                        .padding(Self.gridPadding)
                    }
                    .onAppear {
                        updateGridColumnCount(width: geo.size.width)
                        proxy.scrollTo(session.currentIndex, anchor: .center)
                        refreshSceneBoundaries()
                    }
                    .onChange(of: geo.size.width) { _, width in
                        updateGridColumnCount(width: width)
                    }
                    .onChange(of: session.currentIndex) { _, newIndex in
                        proxy.scrollTo(newIndex, anchor: nil)
                    }
                    .onChange(of: sceneGapMinutes) { _, _ in
                        refreshSceneBoundaries()
                    }
                    .onChange(of: session.files) { _, _ in
                        refreshSceneBoundaries()
                    }
                }
            }
        }
    }

    /// Filtered grid items split wherever `sceneStartIndices` marks a new scene.
    private var sceneChunks: [(id: Int, items: [(index: Int, url: URL)])] {
        let items = filteredFiles
        guard !items.isEmpty else { return [] }
        guard sceneGapMinutes > 0, !sceneStartIndices.isEmpty else {
            return [(id: items[0].index, items: items)]
        }
        var chunks: [(id: Int, items: [(index: Int, url: URL)])] = []
        var current: [(index: Int, url: URL)] = []
        var chunkId = items[0].index
        for item in items {
            if !current.isEmpty && sceneStartIndices.contains(item.index) {
                chunks.append((id: chunkId, items: current))
                current = [item]
                chunkId = item.index
            } else {
                current.append(item)
            }
        }
        if !current.isEmpty {
            chunks.append((id: chunkId, items: current))
        }
        return chunks
    }

    private var sceneSeparator: some View {
        Rectangle()
            .fill(HayateTheme.wash(0.14))
            .frame(height: 1)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
    }

    /// Scan EXIF DateTimeOriginal for the open folder and recompute scene starts.
    func refreshSceneBoundaries() {
        captureDateTask?.cancel()
        guard sceneGapMinutes > 0, !session.files.isEmpty else {
            sceneStartIndices = []
            return
        }
        let files = session.files
        let gap = sceneGapMinutes
        captureDateTask = Task {
            var dates: [Date?] = Array(repeating: nil, count: files.count)
            await withTaskGroup(of: (Int, Date?).self) { group in
                for (i, url) in files.enumerated() {
                    group.addTask {
                        (i, ImageDecoder.captureDate(url: url))
                    }
                }
                for await (i, date) in group {
                    guard !Task.isCancelled else { return }
                    dates[i] = date
                }
            }
            guard !Task.isCancelled else { return }
            let starts = SceneBoundary.startIndices(dates: dates, gapMinutes: gap)
            await MainActor.run {
                sceneStartIndices = starts
            }
        }
    }

    /// Estimate the adaptive grid's column count from the available width:
    /// floor((width − h-padding + spacing) / (min item width + spacing)).
    private func updateGridColumnCount(width: CGFloat) {
        let usable = width - Self.gridPadding * 2 + Self.gridSpacing
        gridColumnCount = max(1, Int(usable / (Self.gridItemMinWidth + Self.gridSpacing)))
    }

    /// Move the current photo by `delta` positions within the *filtered* grid
    /// order (so navigation doesn't jump to photos hidden by the filter).
    /// With `clamping` off, an out-of-range move is a no-op instead of jumping
    /// to the first/last photo — used by ↑↓ row navigation at the edges.
    func moveGridSelection(by delta: Int, clamping: Bool = true) {
        let items = filteredFiles
        guard !items.isEmpty else { return }
        if let pos = items.firstIndex(where: { $0.index == session.currentIndex }) {
            let target = pos + delta
            let newPos: Int
            if clamping {
                newPos = max(0, min(items.count - 1, target))
            } else {
                guard items.indices.contains(target) else { return }
                newPos = target
            }
            session.currentIndex = items[newPos].index
        } else {
            // Current photo is filtered out — snap to the first visible one.
            session.currentIndex = items[0].index
        }
    }

    private func gridCell(for url: URL, index: Int) -> some View {
        let isCurrent = index == session.currentIndex
        let isSelected = selectedIndices.contains(index)
        let entry = session.entries[url.lastPathComponent]

        return VStack(spacing: 0) {
            ZStack {
                // Thumbnail: use .fit to prevent overflow
                if let nsImage = thumbnails[url] {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .frame(height: 140)
                        .background(Color.black)
                        .saturation(CullThumbnailStyle.saturation(for: entry, enabled: colorizeKeepOnly))
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 140)
                        .overlay {
                            ProgressView()
                                .scaleEffect(0.5)
                        }
                        .onAppear { loadThumbnail(for: url) }
                }

                // Selection checkmark (top left)
                VStack {
                    HStack {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.accentColor)
                                .padding(4)
                        }
                        Spacer()
                        // Badges (top right)
                        PhotoBadgeView(entry: entry, triageStyle: cullingProfileTriage)
                            .padding(4)
                    }
                    Spacer()
                }
            }
            .frame(height: 140)
            .clipped()

            // File name
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.system(size: 10))
                .foregroundColor(isCurrent ? HayateTheme.fg(1) : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(isCurrent ? HayateTheme.wash(0.15) : Color.clear)
        }
        .background(HayateTheme.wash(0.06))
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? Color.accentColor : (isCurrent && selectedIndices.isEmpty ? HayateTheme.fg(1) : Color.clear), lineWidth: 2)
        )
        .opacity(entry?.isRejected == true ? 0.5 : 1.0)
        .onTapGesture(count: 2) {
            // Double-click: open in single photo view
            session.currentIndex = index
            selectedIndices.removeAll()
            showGrid = false
            loadCurrentImage()
        }
        .onTapGesture(count: 1) {
            if NSEvent.modifierFlags.contains(.shift) {
                // Shift+click: range select from last selected
                let anchor = selectedIndices.max() ?? session.currentIndex
                let range = min(anchor, index)...max(anchor, index)
                for i in range { selectedIndices.insert(i) }
            } else if NSEvent.modifierFlags.contains(.command) {
                // Cmd+click: add currentIndex on first multi-select, then toggle
                if selectedIndices.isEmpty {
                    selectedIndices.insert(session.currentIndex)
                }
                if selectedIndices.contains(index) {
                    selectedIndices.remove(index)
                } else {
                    selectedIndices.insert(index)
                }
            } else {
                // Plain click: select single, clear multi-select
                selectedIndices.removeAll()
                session.currentIndex = index
            }
        }
    }
}
