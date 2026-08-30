import SwiftUI

/// Grid view: thumbnail overview with filtering and multi-selection.
extension ContentView {

    /// Base layout constants at `gridZoomScale == 1.0`. Derived sizes multiply by scale.
    static let gridItemBaseMinWidth: CGFloat = 160
    static let gridItemBaseMaxWidth: CGFloat = 220
    static let gridCellBaseHeight: CGFloat = 140
    static let gridSpacing: CGFloat = 6
    static let gridPadding: CGFloat = 8
    static let gridZoomScaleMin: Double = 0.5
    static let gridZoomScaleMax: Double = 2.5

    private var gridItemMinWidth: CGFloat { Self.gridItemBaseMinWidth * CGFloat(gridZoomScale) }
    private var gridItemMaxWidth: CGFloat { Self.gridItemBaseMaxWidth * CGFloat(gridZoomScale) }
    private var gridCellHeight: CGFloat { Self.gridCellBaseHeight * CGFloat(gridZoomScale) }

    func clampGridZoomScale(_ scale: Double) -> Double {
        max(Self.gridZoomScaleMin, min(Self.gridZoomScaleMax, scale))
    }

    func adjustGridZoomScale(multiplier: Double) {
        gridZoomScale = clampGridZoomScale(gridZoomScale * multiplier)
    }

    /// One visible grid slot — a single photo or a collapsed burst stack.
    struct GridDisplayItem: Identifiable {
        let fileIndex: Int
        let url: URL
        /// Burst membership when grouping is active; badge UI only on the representative.
        let burstBadge: BurstBadgeInfo?

        struct BurstBadgeInfo {
            let burstID: Int
            let count: Int
            let isCollapsed: Bool
            /// Interactive count badge on the representative cell only.
            let isRepresentative: Bool
        }

        var id: Int { fileIndex }
    }

    var filteredFiles: [(index: Int, url: URL)] {
        session.files.enumerated().compactMap { index, url in
            let entry = session.entries[url.lastPathComponent]
            let triage = CullingSession.TriageState.of(entry)
            switch gridFilter {
            case .all: return (index, url)
            case .favorites, .keep: return entry?.isFavorite == true ? (index, url) : nil
            case .rejected, .out: return entry?.isRejected == true ? (index, url) : nil
            case .rated: return (entry?.rating ?? 0) > 0 ? (index, url) : nil
            case .unrated: return (entry?.rating ?? 0) == 0 ? (index, url) : nil
            case .undecided: return triage == .undecided ? (index, url) : nil
            }
        }
    }

    /// Visible grid order — respects burst collapse when grouping is active.
    var gridDisplayItems: [GridDisplayItem] {
        let items = filteredFiles
        guard burstGroupingEnabled, gridFilter == .all, burstGapSeconds > 0, !burstGroups.isEmpty else {
            return items.map { GridDisplayItem(fileIndex: $0.index, url: $0.url, burstBadge: nil) }
        }

        let burstByID = Dictionary(uniqueKeysWithValues: burstGroups.map { ($0.id, $0) })
        let memberMap = BurstGrouping.memberToBurstID(groups: burstGroups)

        return items.compactMap { item in
            guard let burstID = memberMap[item.index], let burst = burstByID[burstID] else {
                return GridDisplayItem(fileIndex: item.index, url: item.url, burstBadge: nil)
            }
            let isExpanded = expandedBurstIDs.contains(burstID)
            let badge = GridDisplayItem.BurstBadgeInfo(
                burstID: burstID,
                count: burst.memberIndices.count,
                isCollapsed: !isExpanded,
                isRepresentative: item.index == burstID
            )
            if isExpanded {
                return GridDisplayItem(
                    fileIndex: item.index,
                    url: item.url,
                    burstBadge: badge
                )
            }
            guard item.index == burstID else { return nil }
            return GridDisplayItem(fileIndex: item.index, url: item.url, burstBadge: badge)
        }
    }

    /// Burst members hidden inside a collapsed stack → their representative file index.
    private var collapsedBurstMemberMap: [Int: Int] {
        guard burstGroupingEnabled, gridFilter == .all, burstGapSeconds > 0 else { return [:] }
        var map: [Int: Int] = [:]
        for group in burstGroups where !expandedBurstIDs.contains(group.id) {
            for index in group.memberIndices {
                map[index] = group.id
            }
        }
        return map
    }

    /// Index to use for grid lookup, scroll, and highlight when `fileIndex` may be
    /// a non-representative member of a collapsed burst.
    private func gridNavigationIndex(for fileIndex: Int) -> Int {
        collapsedBurstMemberMap[fileIndex] ?? fileIndex
    }

    var gridView: some View {
        let burstMemberMap = collapsedBurstMemberMap
        let currentNavIndex = burstMemberMap[session.currentIndex] ?? session.currentIndex

        return VStack(spacing: 0) {
            // Filter bar
            HStack(spacing: 8) {
                folderSwitcher

                Divider()
                    .frame(height: 14)

                ForEach(GridFilter.visible(triage: cullingProfileTriage), id: \.self) { filter in
                    Button {
                        gridFilter = filter
                    } label: {
                        Text(
                            cullingProfileTriage
                                ? filter.tabTitle(counts: session.triageCounts, total: session.files.count)
                                : filter.title
                        )
                            .font(.system(size: 11, weight: gridFilter == filter ? .bold : .regular))
                            .monospacedDigit()
                            .foregroundColor(gridFilter == filter ? HayateTheme.fg(1) : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(gridFilter == filter ? HayateTheme.wash(0.2) : Color.clear)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                HStack(spacing: 4) {
                    Button {
                        adjustGridZoomScale(multiplier: 0.9)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundColor(HayateTheme.fg(0.55))
                    }
                    .buttonStyle(.plain)
                    .help(L.t("Smaller thumbnails (⌥+scroll)", ja: "サムネイルを小さく（⌥+スクロール）"))
                    .accessibilityLabel(L.t("Decrease grid thumbnail size", ja: "グリッドのサムネイルを縮小"))

                    Button {
                        adjustGridZoomScale(multiplier: 1.0 / 0.9)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundColor(HayateTheme.fg(0.55))
                    }
                    .buttonStyle(.plain)
                    .help(L.t("Larger thumbnails (⌥+scroll)", ja: "サムネイルを大きく（⌥+スクロール）"))
                    .accessibilityLabel(L.t("Increase grid thumbnail size", ja: "グリッドのサムネイルを拡大"))
                }

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

                    if selectedIndices.count >= 2 {
                        Text(L.t("N survey", ja: "N サーベイ"))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
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
                                    columns: [GridItem(.adaptive(minimum: gridItemMinWidth, maximum: gridItemMaxWidth), spacing: Self.gridSpacing)],
                                    spacing: Self.gridSpacing
                                ) {
                                    ForEach(chunk.items) { item in
                                        gridCell(for: item, currentNavIndex: currentNavIndex)
                                            .id(item.fileIndex)
                                    }
                                }
                            }
                        }
                        .padding(Self.gridPadding)
                    }
                    .onAppear {
                        updateGridColumnCount(width: geo.size.width)
                        normalizeGridCurrentIndex()
                        proxy.scrollTo(gridNavigationIndex(for: session.currentIndex), anchor: .center)
                        refreshGridCaptureMetadata()
                    }
                    .onChange(of: geo.size.width) { _, width in
                        updateGridColumnCount(width: width)
                    }
                    .onChange(of: gridZoomScale) { _, _ in
                        updateGridColumnCount(width: geo.size.width)
                    }
                    .onChange(of: session.currentIndex) { _, newIndex in
                        proxy.scrollTo(gridNavigationIndex(for: newIndex), anchor: nil)
                    }
                    .onChange(of: expandedBurstIDs) { _, _ in
                        proxy.scrollTo(gridNavigationIndex(for: session.currentIndex), anchor: nil)
                    }
                    .onChange(of: burstGroups) { _, _ in
                        pruneSelectionForCollapsedBursts()
                        let before = session.currentIndex
                        normalizeGridCurrentIndex()
                        if session.currentIndex != before {
                            proxy.scrollTo(gridNavigationIndex(for: session.currentIndex), anchor: nil)
                        }
                    }
                    .onChange(of: gridFilter) { _, _ in
                        pruneSelectionForCollapsedBursts()
                        normalizeGridCurrentIndex()
                    }
                    .onChange(of: sceneGapMinutes) { _, _ in
                        refreshGridCaptureMetadata()
                    }
                    .onChange(of: burstGapSeconds) { _, _ in
                        refreshGridCaptureMetadata()
                    }
                    .onChange(of: burstGroupingEnabled) { _, _ in
                        pruneSelectionForCollapsedBursts()
                        normalizeGridCurrentIndex()
                    }
                    .onChange(of: session.files) { _, _ in
                        refreshGridCaptureMetadata()
                    }
                }
            }
        }
    }

    /// Display items split wherever `sceneStartIndices` marks a new scene.
    private var sceneChunks: [(id: Int, items: [GridDisplayItem])] {
        let items = gridDisplayItems
        guard !items.isEmpty else { return [] }
        guard sceneGapMinutes > 0, !sceneStartIndices.isEmpty else {
            return [(id: items[0].fileIndex, items: items)]
        }
        var chunks: [(id: Int, items: [GridDisplayItem])] = []
        var current: [GridDisplayItem] = []
        var chunkId = items[0].fileIndex
        for item in items {
            if !current.isEmpty && sceneStartIndices.contains(item.fileIndex) {
                chunks.append((id: chunkId, items: current))
                current = [item]
                chunkId = item.fileIndex
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

    /// Scan EXIF capture times once per folder and derive scene breaks + burst groups.
    func refreshGridCaptureMetadata() {
        captureDateTask?.cancel()
        sceneStartIndices = []
        burstGroups = []

        guard !session.files.isEmpty else {
            expandedBurstIDs = []
            return
        }
        let files = session.files
        let sceneGap = sceneGapMinutes
        let burstGap = burstGapSeconds
        guard sceneGap > 0 || burstGap > 0 else {
            expandedBurstIDs = []
            return
        }
        captureDateTask = Task {
            var dates: [Date?] = Array(repeating: nil, count: files.count)
            let maxConcurrent = 8
            var scanIndex = 0
            while scanIndex < files.count {
                guard !Task.isCancelled else { return }
                let end = min(scanIndex + maxConcurrent, files.count)
                await withTaskGroup(of: (Int, Date?).self) { group in
                    for i in scanIndex..<end {
                        let url = files[i]
                        group.addTask {
                            guard !Task.isCancelled else { return (i, nil) }
                            return (i, ImageDecoder.captureDate(url: url))
                        }
                    }
                    for await (i, date) in group {
                        guard !Task.isCancelled else { return }
                        dates[i] = date
                    }
                }
                scanIndex = end
            }
            guard !Task.isCancelled else { return }
            let starts = sceneGap > 0
                ? SceneBoundary.startIndices(dates: dates, gapMinutes: sceneGap)
                : []
            let bursts = burstGap > 0
                ? BurstGrouping.groups(dates: dates, maxGapSeconds: TimeInterval(burstGap))
                : []
            let validBurstIDs = Set(bursts.map(\.id))
            await MainActor.run {
                sceneStartIndices = starts
                burstGroups = bursts
                expandedBurstIDs = expandedBurstIDs.intersection(validBurstIDs)
                pruneSelectionForCollapsedBursts()
                normalizeGridCurrentIndex()
            }
        }
    }

    /// When the grid is showing a collapsed burst, keep `currentIndex` on the visible representative.
    func normalizeGridCurrentIndex() {
        guard showGrid, burstGroupingEnabled, gridFilter == .all, burstGapSeconds > 0 else { return }
        let resolved = gridNavigationIndex(for: session.currentIndex)
        if session.currentIndex != resolved {
            session.currentIndex = resolved
        }
    }

    /// Estimate the adaptive grid's column count from the available width:
    /// floor((width − h-padding + spacing) / (min item width + spacing)).
    private func updateGridColumnCount(width: CGFloat) {
        let usable = width - Self.gridPadding * 2 + Self.gridSpacing
        gridColumnCount = max(1, Int(usable / (gridItemMinWidth + Self.gridSpacing)))
    }

    /// Move the current photo by `delta` positions within the *displayed* grid
    /// order (collapsed bursts count as one slot).
    /// With `clamping` off, an out-of-range move is a no-op instead of jumping
    /// to the first/last photo — used by ↑↓ row navigation at the edges.
    /// When `navigateUndecidedOnly` is on, skips display items whose photo is decided.
    func moveGridSelection(by delta: Int, clamping: Bool = true) {
        let items = gridDisplayItems
        guard !items.isEmpty else { return }
        let lookupIndex = gridNavigationIndex(for: session.currentIndex)

        guard let startPos = items.firstIndex(where: { $0.fileIndex == lookupIndex }) else {
            if let pos = firstUndecidedDisplayPosition(in: items, from: 0, step: 1) {
                session.currentIndex = items[pos].fileIndex
            } else {
                session.currentIndex = items[0].fileIndex
            }
            return
        }

        let step = delta >= 0 ? 1 : -1
        let count = abs(delta)

        if navigateUndecidedOnly {
            var pos = startPos
            var found = 0
            while found < count {
                let nextPos = pos + step
                guard items.indices.contains(nextPos) else {
                    if !clamping { return }
                    break
                }
                pos = nextPos
                if !isDisplayItemDecided(items[pos]) {
                    found += 1
                }
            }
            guard found == count, pos != startPos else { return }
            session.currentIndex = items[pos].fileIndex
            return
        }

        let target = startPos + delta
        let newPos: Int
        if clamping {
            newPos = max(0, min(items.count - 1, target))
        } else {
            guard items.indices.contains(target) else { return }
            newPos = target
        }
        session.currentIndex = items[newPos].fileIndex
    }

    private func isDisplayItemDecided(_ item: GridDisplayItem) -> Bool {
        let name = session.files[item.fileIndex].lastPathComponent
        return session.isDecided(fileNamed: name, triageMode: cullingProfileTriage)
    }

    /// First undecided display index at or after `from` when stepping by `step` (±1).
    private func firstUndecidedDisplayPosition(
        in items: [GridDisplayItem],
        from: Int,
        step: Int
    ) -> Int? {
        var i = from
        while items.indices.contains(i) {
            if !isDisplayItemDecided(items[i]) { return i }
            i += step
        }
        return nil
    }

    /// Shift+click range select along visible grid order (excludes collapsed burst members).
    func selectGridDisplayRange(anchorFileIndex: Int, targetFileIndex: Int) {
        let items = gridDisplayItems
        let anchor = gridNavigationIndex(for: anchorFileIndex)
        guard let anchorPos = items.firstIndex(where: { $0.fileIndex == anchor }),
              let targetPos = items.firstIndex(where: { $0.fileIndex == targetFileIndex }) else {
            return
        }
        for pos in min(anchorPos, targetPos)...max(anchorPos, targetPos) {
            selectedIndices.insert(items[pos].fileIndex)
        }
    }

    /// Visible grid slots only — excludes collapsed burst members.
    func selectAllVisibleGridItems() {
        selectedIndices = Set(gridDisplayItems.map(\.fileIndex))
    }

    private func toggleBurstExpansion(burstID: Int) {
        if expandedBurstIDs.contains(burstID) {
            expandedBurstIDs.remove(burstID)
            pruneSelectionForCollapsedBursts()
            if let group = burstGroups.first(where: { $0.id == burstID }),
               group.memberIndices.contains(session.currentIndex),
               session.currentIndex != burstID {
                session.currentIndex = burstID
            }
        } else {
            expandedBurstIDs.insert(burstID)
        }
    }

    /// Drop selections on burst members that are no longer visible after collapse.
    func pruneSelectionForCollapsedBursts() {
        guard burstGroupingEnabled, gridFilter == .all, burstGapSeconds > 0 else { return }
        let memberMap = BurstGrouping.memberToBurstID(groups: burstGroups)
        selectedIndices = selectedIndices.filter { index in
            guard let burstID = memberMap[index], !expandedBurstIDs.contains(burstID) else {
                return true
            }
            return index == burstID
        }
    }

    private func gridCell(for item: GridDisplayItem, currentNavIndex: Int) -> some View {
        gridCell(for: item.url, index: item.fileIndex, burstBadge: item.burstBadge, currentNavIndex: currentNavIndex)
    }

    private func gridCell(
        for url: URL,
        index: Int,
        burstBadge: GridDisplayItem.BurstBadgeInfo? = nil,
        currentNavIndex: Int
    ) -> some View {
        let isCurrent = index == currentNavIndex
        let isSelected = selectedIndices.contains(index)
        let entry = session.entries[url.lastPathComponent]
        let showStackChrome = burstBadge?.isCollapsed == true
        let isExpandedBurstMember = burstBadge?.isCollapsed == false

        return VStack(spacing: 0) {
            ZStack {
                if showStackChrome {
                    burstStackChrome
                }

                // Thumbnail: use .fit to prevent overflow
                if let nsImage = thumbnails[url] {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .frame(height: gridCellHeight)
                        .background(Color.black)
                        .saturation(CullThumbnailStyle.saturation(for: entry, enabled: colorizeKeepOnly))
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: gridCellHeight)
                        .overlay {
                            ProgressView()
                                .scaleEffect(0.5)
                        }
                        .onAppear { loadThumbnail(for: url) }
                        .onDisappear { cancelThumbnailLoad(for: url) }
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
                        HStack(spacing: 4) {
                            if assistedCullingEnabled, photoAnalysisStore.needsReview.contains(url) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(HayateTheme.warning)
                                    .help(L.needsReviewBadgeHelp)
                                    .accessibilityLabel(L.needsReviewBadgeLabel)
                            }
                            if let badge = burstBadge, badge.isRepresentative {
                                burstCountBadge(
                                    count: badge.count,
                                    burstID: badge.burstID,
                                    isCollapsed: badge.isCollapsed
                                )
                            }
                            PhotoBadgeView(entry: entry, triageStyle: cullingProfileTriage)
                        }
                        .padding(4)
                    }
                    Spacer()
                }
            }
            .frame(height: gridCellHeight)
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
        .background(isExpandedBurstMember ? HayateTheme.wash(0.12) : HayateTheme.wash(0.06))
        .cornerRadius(4)
        .overlay(alignment: .top) {
            if isExpandedBurstMember {
                Rectangle()
                    .fill(HayateTheme.wash(0.35))
                    .frame(height: 2)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if isExpandedBurstMember {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(HayateTheme.wash(0.35), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(
                    isSelected ? Color.accentColor : (isCurrent && selectedIndices.isEmpty ? HayateTheme.fg(1) : Color.clear),
                    lineWidth: 2
                )
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
                let anchor = selectedIndices.max() ?? session.currentIndex
                selectGridDisplayRange(anchorFileIndex: anchor, targetFileIndex: index)
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

    /// Offset frames behind the representative thumbnail for a collapsed burst.
    private var burstStackChrome: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(HayateTheme.wash(0.22), lineWidth: 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(HayateTheme.wash(0.04)))
                .offset(x: 5, y: 5)
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(HayateTheme.wash(0.18), lineWidth: 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(HayateTheme.wash(0.06)))
                .offset(x: 2.5, y: 2.5)
        }
        .allowsHitTesting(false)
    }

    private func burstCountBadge(count: Int, burstID: Int, isCollapsed: Bool) -> some View {
        Button {
            toggleBurstExpansion(burstID: burstID)
        } label: {
            Text("\(count)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(HayateTheme.fg(0.95))
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(HayateTheme.wash(0.55))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .help(
            isCollapsed
                ? L.t("Expand burst", ja: "バーストを展開")
                : L.t("Collapse burst", ja: "バーストを折りたたむ")
        )
    }
}
