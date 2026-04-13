import SwiftUI
import MetalKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var session: CullingSession
    @Environment(\.ciContext) private var ciContext
    @Environment(\.metalDevice) private var metalDevice

    @State private var currentTexture: MTLTexture?
    @State private var decoder: ImageDecoder?
    @State private var prefetchManager: PrefetchManager?
    @State private var isLoading = false
    @State private var showDeleteConfirmation = false
    @State private var decodeTimeMs: Double = 0
    @State private var keyMonitor: Any?
    @State private var currentDecodeTask: Task<Void, Never>?
    @State private var focusPeakingEnabled = false
    @State private var thumbnails: [URL: NSImage] = [:]
    @State private var thumbnailLoadTask: Task<Void, Never>?
    @State private var zoomScale: CGFloat = 1.0
    @State private var panOffset: CGPoint = .zero
    @State private var scrollMonitor: Any?
    @State private var dragMonitor: Any?
    @State private var lastDragPoint: NSPoint?
    @State private var showGrid = false
    @State private var selectedIndices: Set<Int> = []
    @State private var gridFilter: GridFilter = .all
    @State private var compareMode = false
    @State private var compareIndices: [Int] = []
    @State private var compareActiveSlot: Int = 0  // which photo is "active" for rating
    @State private var compareTextures: [Int: MTLTexture] = [:]

    enum GridFilter: String, CaseIterable {
        case all = "All"
        case favorites = "♥ Favorites"
        case rejected = "✗ Rejected"
        case rated = "★ Rated"
        case unrated = "Unrated"
    }

    var body: some View {
        ZStack {
            Color(nsColor: NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0))
                .ignoresSafeArea()

            if ciContext == nil {
                // Loading screen while CIContext initializes
                VStack(spacing: 16) {
                    Text("Hayate")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.white)
                    Text("RAW Photo Culling")
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 8)
                }
            } else if session.files.isEmpty {
                // "Open Folder" prompt
                VStack(spacing: 16) {
                    Text("Hayate")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.white)
                    Text("RAW Photo Culling")
                        .font(.system(size: 14))
                        .foregroundColor(.gray)

                    Button("Open Folder...") {
                        session.requestOpenFolder()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if showGrid {
                gridView
            } else if compareMode {
                compareView
            } else {
                // Single photo view
                if let device = metalDevice {
                    MetalImageView(texture: currentTexture, device: device, zoomScale: zoomScale, panOffset: panOffset)
                }

                // Bottom overlay: filmstrip + status bar
                VStack(spacing: 0) {
                    Spacer()
                    filmstrip
                    statusBar
                }
            }
        }
        .onAppear {
            initializeDecoder()
            installKeyHandler()
        }
        .onChange(of: ciContext != nil) { _, available in
            // Re-initialize decoder when CIContext becomes available (async load)
            if available && decoder == nil {
                initializeDecoder()
            }
        }
        .onDisappear {
            removeKeyHandler()
        }
        .confirmationDialog(
            "Delete this photo?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                _ = session.deleteCurrentFile()
                loadCurrentImage()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let file = session.currentFile {
                Text(file.lastPathComponent)
            }
        }
        .onChange(of: session.currentIndex) { _, _ in
            loadCurrentImage()
        }
        .onChange(of: session.openFolderRequest) { _, _ in
            openFolderDialog()
        }
    }

    // MARK: - Grid View

    private var filteredFiles: [(index: Int, url: URL)] {
        session.files.enumerated().compactMap { index, url in
            let entry = session.entries[url.lastPathComponent]
            switch gridFilter {
            case .all: return (index, url)
            case .favorites: return entry?.isFavorite == true ? (index, url) : nil
            case .rejected: return entry?.isRejected == true ? (index, url) : nil
            case .rated: return (entry?.rating ?? 0) > 0 ? (index, url) : nil
            case .unrated: return (entry?.rating ?? 0) == 0 ? (index, url) : nil
            }
        }
    }

    private var gridView: some View {
        VStack(spacing: 0) {
            // Filter bar
            HStack(spacing: 8) {
                ForEach(GridFilter.allCases, id: \.self) { filter in
                    Button {
                        gridFilter = filter
                    } label: {
                        Text(filter.rawValue)
                            .font(.system(size: 11, weight: gridFilter == filter ? .bold : .regular))
                            .foregroundColor(gridFilter == filter ? .white : .gray)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(gridFilter == filter ? Color.white.opacity(0.2) : Color.clear)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Text("\(filteredFiles.count) / \(session.files.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray)

                if !selectedIndices.isEmpty {
                    Text("\(selectedIndices.count) selected")
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.5))
                        .cornerRadius(3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)

            // Grid
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 6)], spacing: 6) {
                        ForEach(filteredFiles, id: \.index) { item in
                            gridCell(for: item.url, index: item.index)
                                .id(item.index)
                        }
                    }
                    .padding(8)
                }
                .onAppear {
                    proxy.scrollTo(session.currentIndex, anchor: .center)
                }
            }
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
                        if let entry = entry, entry.isFavorite || entry.isRejected || entry.rating > 0 {
                            HStack(spacing: 3) {
                                if entry.isFavorite {
                                    Image(systemName: "heart.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(.red)
                                }
                                if entry.isRejected {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(.orange)
                                }
                                if entry.rating > 0 {
                                    HStack(spacing: 0) {
                                        ForEach(1...entry.rating, id: \.self) { _ in
                                            Image(systemName: "star.fill")
                                                .font(.system(size: 7))
                                                .foregroundColor(.yellow)
                                        }
                                    }
                                }
                            }
                            .padding(4)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(4)
                            .padding(4)
                        }
                    }
                    Spacer()
                }
            }
            .frame(height: 140)
            .clipped()

            // File name
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.system(size: 10))
                .foregroundColor(isCurrent ? .white : .gray)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(isCurrent ? Color.white.opacity(0.15) : Color.clear)
        }
        .background(Color.gray.opacity(0.1))
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? Color.accentColor : (isCurrent && selectedIndices.isEmpty ? Color.white : Color.clear), lineWidth: 2)
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

    // MARK: - Compare View

    private var compareView: some View {
        VStack(spacing: 0) {
            // Photos side by side
            HStack(spacing: 2) {
                ForEach(Array(compareIndices.enumerated()), id: \.element) { slot, fileIndex in
                    let isActive = slot == compareActiveSlot
                    let url = session.files[fileIndex]
                    let entry = session.entries[url.lastPathComponent]

                    VStack(spacing: 0) {
                        ZStack {
                            if let device = metalDevice {
                                MetalImageView(
                                    texture: compareTextures[fileIndex],
                                    device: device,
                                    zoomScale: zoomScale,
                                    panOffset: panOffset
                                )
                            }

                            // Top-left: slot number + active badge
                            VStack {
                                HStack(spacing: 6) {
                                    // Slot number (always visible)
                                    Text("\(slot + 1)")
                                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                        .frame(width: 24, height: 24)
                                        .background(isActive ? Color.accentColor : Color.white.opacity(0.3))
                                        .cornerRadius(12)
                                        .padding(8)

                                    Spacer()

                                    // Status badges (top right)
                                    HStack(spacing: 4) {
                                        if entry?.isFavorite == true {
                                            Image(systemName: "heart.fill")
                                                .foregroundColor(.red)
                                                .font(.system(size: 14))
                                        }
                                        if entry?.isRejected == true {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.orange)
                                                .font(.system(size: 14))
                                        }
                                        if (entry?.rating ?? 0) > 0 {
                                            HStack(spacing: 1) {
                                                ForEach(1...(entry?.rating ?? 1), id: \.self) { _ in
                                                    Image(systemName: "star.fill")
                                                        .font(.system(size: 9))
                                                        .foregroundColor(.yellow)
                                                }
                                            }
                                        }
                                    }
                                    .padding(6)
                                    .background(Color.black.opacity(0.6))
                                    .cornerRadius(4)
                                    .padding(8)
                                }
                                Spacer()

                                // "PICK" hint on active slot
                                if isActive {
                                    Text("⏎ Pick")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.accentColor.opacity(0.8))
                                        .cornerRadius(6)
                                        .padding(.bottom, 12)
                                }
                            }
                        }

                        // Per-photo file name bar
                        Text(url.deletingPathExtension().lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity)
                            .background(isActive ? Color.accentColor.opacity(0.3) : Color.black.opacity(0.4))
                            .foregroundColor(.white)
                            .font(.system(size: 11))
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 0)
                            .stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 3)
                    )
                }
            }

            // Compare mode footer
            HStack {
                Text("COMPARE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.accentColor)

                Text("←→ select  |  ⏎ pick  |  Tab skip  |  Esc exit")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
        }
    }

    private func enterCompareMode() {
        guard let device = metalDevice, let decoder = decoder else { return }

        // Determine which photos to compare
        if showGrid && selectedIndices.count >= 2 {
            // From grid: use selected indices (up to 4)
            compareIndices = Array(selectedIndices.sorted().prefix(4))
        } else {
            // From single view: current + next (or previous if at end)
            var indices = [session.currentIndex]
            if session.currentIndex < session.files.count - 1 {
                indices.append(session.currentIndex + 1)
            } else if session.currentIndex > 0 {
                indices.insert(session.currentIndex - 1, at: 0)
            }
            guard indices.count >= 2 else { return }
            compareIndices = indices
        }

        compareActiveSlot = 0
        compareTextures = [:]
        showGrid = false
        selectedIndices.removeAll()
        compareMode = true

        loadCompareTextures()
    }

    /// Enter: "Pick" the active photo. Keep it on the left, reject the other,
    /// load the next photo on the right for continued comparison.
    private func pickActivePhoto() {
        guard compareIndices.count == 2 else { return }

        let pickedIndex = compareIndices[compareActiveSlot]
        let otherSlot = compareActiveSlot == 0 ? 1 : 0
        let rejectedIndex = compareIndices[otherSlot]

        // Favorite the picked one
        let pickedFileName = session.files[pickedIndex].lastPathComponent
        if session.entries[pickedFileName]?.isFavorite != true {
            session.currentIndex = pickedIndex
            session.toggleFavorite()
        }

        // Reject the other
        let rejectedFileName = session.files[rejectedIndex].lastPathComponent
        if session.entries[rejectedFileName]?.isRejected != true {
            session.currentIndex = rejectedIndex
            session.toggleRejected()
        }

        // Next photo = one after the rightmost in the current pair
        let maxIndex = compareIndices.max() ?? pickedIndex
        let nextIndex = maxIndex + 1

        if nextIndex < session.files.count {
            // Keep picked on left, load next on right
            compareIndices = [pickedIndex, nextIndex]
            compareActiveSlot = 0
            // Keep the picked texture, clear only the new slot
            compareTextures[rejectedIndex] = nil
            session.currentIndex = pickedIndex
            loadCompareTexture(for: nextIndex)
        } else {
            // No more photos, exit
            session.currentIndex = pickedIndex
            exitCompareMode()
        }
    }

    /// Tab: Skip. The right photo becomes the new baseline (left),
    /// next photo loads on the right. Used when moving to a new angle.
    private func skipToNextBaseline() {
        guard compareIndices.count == 2 else { return }

        let rightIndex = compareIndices[1]
        let maxIndex = compareIndices.max() ?? rightIndex
        let nextIndex = maxIndex + 1

        if nextIndex < session.files.count {
            let oldLeftIndex = compareIndices[0]
            compareIndices = [rightIndex, nextIndex]
            compareActiveSlot = 0
            // Keep the right texture (now left), clear old left
            compareTextures[oldLeftIndex] = nil
            session.currentIndex = rightIndex
            loadCompareTexture(for: nextIndex)
        } else {
            // No more photos, exit
            session.currentIndex = rightIndex
            exitCompareMode()
        }
    }

    private func loadCompareTextures() {
        guard let device = metalDevice, let decoder = decoder else { return }
        let indices = compareIndices
        let usePeaking = focusPeakingEnabled
        let displaySize = CGSize(
            width: Double(device.recommendedMaxWorkingSetSize > 0 ? 3840 : 1920),
            height: Double(device.recommendedMaxWorkingSetSize > 0 ? 2160 : 1080)
        )

        // Single Task to avoid @State dictionary concurrent write race
        Task {
            for fileIndex in indices {
                let url = session.files[fileIndex]

                // Try cache first (only when peaking is off)
                if !usePeaking,
                   let prefetchManager = prefetchManager,
                   let cached = await prefetchManager.cachedTexture(for: url) {
                    compareTextures[fileIndex] = cached.texture
                    continue
                }

                // JPEG first for instant feedback (skip if peaking)
                if !usePeaking {
                    if let jpeg = await decoder.extractJPEG(url: url),
                       let sendable = await decoder.cgImageToTexture(jpeg) {
                        compareTextures[fileIndex] = sendable.texture
                    }
                }

                // Full RAW (with or without focus peaking)
                if let sendable = await decoder.decodeRAW(url: url, displaySize: displaySize, focusPeaking: usePeaking) {
                    compareTextures[fileIndex] = sendable.texture
                }
            }
        }
    }

    private func loadCompareTexture(for fileIndex: Int) {
        guard let device = metalDevice, let decoder = decoder else { return }
        let url = session.files[fileIndex]
        let usePeaking = focusPeakingEnabled
        let displaySize = CGSize(
            width: Double(device.recommendedMaxWorkingSetSize > 0 ? 3840 : 1920),
            height: Double(device.recommendedMaxWorkingSetSize > 0 ? 2160 : 1080)
        )

        Task {
            // Try cache first (only when peaking is off)
            if !usePeaking,
               let prefetchManager = prefetchManager,
               let cached = await prefetchManager.cachedTexture(for: url) {
                compareTextures[fileIndex] = cached.texture
                return
            }
            // JPEG first
            if !usePeaking {
                if let jpeg = await decoder.extractJPEG(url: url),
                   let sendable = await decoder.cgImageToTexture(jpeg) {
                    compareTextures[fileIndex] = sendable.texture
                }
            }
            // Full RAW
            if let sendable = await decoder.decodeRAW(url: url, displaySize: displaySize, focusPeaking: usePeaking) {
                compareTextures[fileIndex] = sendable.texture
            }
        }
    }



    private func exitCompareMode() {
        compareMode = false
        compareIndices = []
        compareTextures = [:]
        compareActiveSlot = 0
        loadCurrentImage()
    }

    // MARK: - Filmstrip

    private var filmstrip: some View {
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
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 80, height: 60)
                    .onAppear { loadThumbnail(for: url) }
            }

            // Rating/favorite/rejected indicator
            if let entry = entry, entry.rating > 0 || entry.isFavorite || entry.isRejected {
                HStack(spacing: 1) {
                    if entry.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 7))
                            .foregroundColor(.red)
                    }
                    if entry.isRejected {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(.orange)
                    }
                    if entry.rating > 0 {
                        Text("\(entry.rating)")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(.yellow)
                    }
                }
                .padding(2)
                .background(Color.black.opacity(0.6))
                .cornerRadius(2)
                .padding(2)
            }
        }
        .border(isCurrent ? Color.white : Color.clear, width: 2)
        .opacity(isCurrent ? 1.0 : 0.6)
        .onTapGesture {
            session.currentIndex = index
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            if !session.files.isEmpty {
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

                // Rating stars + favorite
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

                Spacer()

                // Focus peaking indicator
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
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .foregroundColor(.white)
        .font(.system(size: 13))
    }

    // MARK: - Actions

    private func initializeDecoder() {
        guard let ciContext = ciContext, let device = metalDevice else { return }
        let dec = ImageDecoder(ciContext: ciContext, device: device)
        decoder = dec
        prefetchManager = PrefetchManager(decoder: dec, device: device)
    }

    private func installKeyHandler() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if handleKeyEvent(event) {
                return nil
            }
            return event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
            handleScrollEvent(event)
            return event
        }
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseDown, .leftMouseUp]) { event in
            handleDragEvent(event)
            return event
        }
    }

    private func removeKeyHandler() {
        for monitor in [keyMonitor, scrollMonitor, dragMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitor = nil
        scrollMonitor = nil
        dragMonitor = nil
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Cmd+Z undo
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "z" {
            session.undo()
            loadCurrentImage()
            return true
        }

        // Cmd+A select all (grid only)
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "a" && showGrid {
            if selectedIndices.count == filteredFiles.count {
                selectedIndices.removeAll()
            } else {
                selectedIndices = Set(filteredFiles.map(\.index))
            }
            return true
        }

        // Ignore events with command/ctrl modifiers for remaining keys
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            return false
        }

        switch event.keyCode {
        case 123: // left arrow
            if compareMode && !compareIndices.isEmpty {
                compareActiveSlot = max(0, compareActiveSlot - 1)
                session.currentIndex = compareIndices[compareActiveSlot]
                return true
            }
            navigateBack()
            return true
        case 124: // right arrow
            if compareMode && !compareIndices.isEmpty {
                compareActiveSlot = min(compareIndices.count - 1, compareActiveSlot + 1)
                session.currentIndex = compareIndices[compareActiveSlot]
                return true
            }
            navigateForward()
            return true
        case 49: // space — toggle fit ↔ 2x
            if zoomScale > 1.01 {
                zoomScale = 1.0
                panOffset = .zero
            } else {
                zoomScale = 2.0
                panOffset = .zero
            }
            return true
        case 48: // tab — in compare mode: skip to next baseline (new angle)
            if compareMode && !compareIndices.isEmpty {
                skipToNextBaseline()
                return true
            }
            return false
        case 36: // return — pick in compare mode, or exit grid
            if compareMode {
                pickActivePhoto()
                return true
            }
            if showGrid {
                showGrid = false
                loadCurrentImage()
                return true
            }
            return false
        case 53: // escape — exit compare, grid, or reset zoom
            if compareMode {
                exitCompareMode()
                return true
            }
            if showGrid {
                showGrid = false
                loadCurrentImage()
                return true
            }
            if zoomScale > 1.01 {
                resetZoom()
                return true
            }
            return false
        case 51: // delete
            showDeleteConfirmation = true
            return true
        default:
            break
        }

        // Batch-aware operations: apply to selection if grid has multi-select
        // In compare mode, operations apply to the active slot's photo
        let batch = showGrid && !selectedIndices.isEmpty
        let compareActive = compareMode && !compareIndices.isEmpty

        switch event.charactersIgnoringModifiers {
        case "c":
            if compareMode {
                exitCompareMode()
            } else {
                enterCompareMode()
            }
            return true
        case "p":
            if compareActive {
                session.currentIndex = compareIndices[compareActiveSlot]
                session.toggleFavorite()
            } else if batch { session.toggleFavoriteForIndices(selectedIndices) }
            else { session.toggleFavorite() }
            return true
        case "x":
            if compareActive {
                session.currentIndex = compareIndices[compareActiveSlot]
                session.toggleRejected()
            } else if batch { session.toggleRejectedForIndices(selectedIndices) }
            else { session.toggleRejected() }
            return true
        case "g":
            if compareMode { exitCompareMode() }
            showGrid.toggle()
            if !showGrid { selectedIndices.removeAll() }
            return true
        case "1", "2", "3", "4", "5", "0":
            let rating = Int(event.charactersIgnoringModifiers!)!
            if compareActive {
                session.currentIndex = compareIndices[compareActiveSlot]
                session.setRating(rating)
            } else if batch { session.setRatingForIndices(selectedIndices, rating: rating) }
            else { session.setRating(rating) }
            return true
        case "f":
            if compareMode { return false }
            focusPeakingEnabled.toggle()
            loadCurrentImage()
            return true
        default:
            return false
        }
    }

    private func handleScrollEvent(_ event: NSEvent) {
        if event.type == .magnify {
            // Trackpad pinch-to-zoom
            let delta = event.magnification
            zoomScale = max(1.0, min(zoomScale * (1.0 + delta), 10.0))
            if zoomScale <= 1.01 { panOffset = .zero }
        } else if event.type == .scrollWheel {
            if event.modifierFlags.contains(.option) || zoomScale <= 1.01 {
                // Option+scroll or not zoomed: zoom in/out
                let delta = event.scrollingDeltaY * 0.01
                zoomScale = max(1.0, min(zoomScale * (1.0 + delta), 10.0))
                if zoomScale <= 1.01 { panOffset = .zero }
            } else {
                // Zoomed in: pan
                let sensitivity: CGFloat = 0.005 / zoomScale
                panOffset = CGPoint(
                    x: panOffset.x + event.scrollingDeltaX * sensitivity,
                    y: panOffset.y - event.scrollingDeltaY * sensitivity
                )
            }
        }
    }

    private func handleDragEvent(_ event: NSEvent) {
        guard zoomScale > 1.01 else {
            lastDragPoint = nil
            return
        }

        switch event.type {
        case .leftMouseDown:
            lastDragPoint = event.locationInWindow
        case .leftMouseDragged:
            guard let last = lastDragPoint else {
                lastDragPoint = event.locationInWindow
                return
            }
            let current = event.locationInWindow
            let dx = current.x - last.x
            let dy = current.y - last.y

            // Convert pixel delta to NDC units
            guard let window = event.window else { return }
            let viewSize = window.contentView?.bounds.size ?? CGSize(width: 1, height: 1)
            let sensitivity: CGFloat = 2.0 / min(viewSize.width, viewSize.height)

            panOffset = CGPoint(
                x: panOffset.x + dx * sensitivity,
                y: panOffset.y + dy * sensitivity
            )
            lastDragPoint = current
        case .leftMouseUp:
            lastDragPoint = nil
        default:
            break
        }
    }

    private func resetZoom() {
        zoomScale = 1.0
        panOffset = .zero
    }

    private func openFolderDialog() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder containing RAW photos"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Only wipe view state if the session successfully switched folders;
        // otherwise we'd clear the screen while still pointing at the old folder.
        guard session.openFolder(url) else { return }
        resetViewState()
        loadCurrentImage()
    }

    /// Clear all view-local state when switching to a new folder mid-session.
    /// Session-level state (files, entries, undoStack) is reset by `CullingSession.openFolder`.
    /// The `decoder` and `prefetchManager` instances are kept — they're bound to CIContext/device,
    /// not to a specific folder.
    private func resetViewState() {
        // Cancel in-flight work
        currentDecodeTask?.cancel()
        currentDecodeTask = nil
        thumbnailLoadTask?.cancel()
        thumbnailLoadTask = nil

        // Textures / decode results
        currentTexture = nil
        thumbnails.removeAll()
        decodeTimeMs = 0
        isLoading = false

        // Drop cached decodes from the previous folder. Cache keys are absolute URLs,
        // so a not-yet-completed clear() can't cause stale hits in the new folder.
        if let pm = prefetchManager {
            Task { await pm.clear() }
        }

        // Grid / Compare / selection
        showGrid = false
        selectedIndices.removeAll()
        gridFilter = .all
        compareMode = false
        compareIndices.removeAll()
        compareActiveSlot = 0
        compareTextures.removeAll()

        // View helpers
        focusPeakingEnabled = false
    }

    private func navigateForward() {
        session.navigateForward()
    }

    private func navigateBack() {
        session.navigateBack()
    }

    private func loadCurrentImage() {
        // Cancel any in-flight decode. Only the latest navigation matters.
        currentDecodeTask?.cancel()
        // Reset zoom for new photo
        resetZoom()

        guard let file = session.currentFile,
              let decoder = decoder,
              let device = metalDevice else {
            currentTexture = nil
            return
        }

        // Fire the neighbor prefetch in its own Task so rapid navigation can't
        // cancel it. (Previously this lived at the tail of the decode Task and
        // got wiped on every keystroke during fast culling — neighbors never
        // actually warmed up.)
        if let prefetchManager = prefetchManager {
            let currentIdx = session.currentIndex
            let allFiles = session.files
            let prefetchSize = CGSize(width: 3840, height: 2160)
            Task {
                await prefetchManager.prefetch(
                    currentIndex: currentIdx,
                    files: allFiles,
                    displaySize: prefetchSize
                )
            }
        }

        isLoading = true
        let start = CFAbsoluteTimeGetCurrent()

        currentDecodeTask = Task {
            let usePeaking = focusPeakingEnabled

            // Use cache only when focus peaking is off (cache stores non-peaking textures)
            if !usePeaking,
               let prefetchManager = prefetchManager,
               let cached = await prefetchManager.cachedTexture(for: file) {
                guard !Task.isCancelled else { return }
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                let tex = cached.texture
                currentTexture = tex
                decodeTimeMs = elapsed
                isLoading = false
            } else {
                // No cache hit, or focus peaking is on. Show JPEG first.
                if !usePeaking {
                    if let jpeg = await decoder.extractJPEG(url: file) {
                        guard !Task.isCancelled else { return }
                        if let sendable = await decoder.cgImageToTexture(jpeg) {
                            guard !Task.isCancelled else { return }
                            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                            let tex = sendable.texture
                            currentTexture = tex
                            decodeTimeMs = elapsed
                        }
                    }
                }

                guard !Task.isCancelled else { return }

                // Decode full RAW (with or without focus peaking)
                let displaySize = CGSize(
                    width: Double(device.recommendedMaxWorkingSetSize > 0 ? 3840 : 1920),
                    height: Double(device.recommendedMaxWorkingSetSize > 0 ? 2160 : 1080)
                )
                if let sendable = await decoder.decodeRAW(url: file, displaySize: displaySize, focusPeaking: usePeaking) {
                    guard !Task.isCancelled else { return }
                    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                    currentTexture = sendable.texture
                    decodeTimeMs = elapsed
                    isLoading = false

                    // Only cache non-peaking textures
                    if !usePeaking, let prefetchManager = prefetchManager {
                        await prefetchManager.store(texture: sendable.texture, for: file, isRAW: true)
                    }
                }
            }
        }
    }

    private func loadThumbnail(for url: URL) {
        guard let decoder = decoder else { return }
        Task.detached(priority: .utility) {
            if let cgImage = await decoder.extractThumbnail(url: url) {
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                await MainActor.run {
                    thumbnails[url] = nsImage
                }
            }
        }
    }

}

