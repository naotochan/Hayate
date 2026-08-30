import SwiftUI
import MetalKit

/// Survey mode: compare 2–6 photos in an adaptive grid with Keep/Out culling.
extension ContentView {

    var surveyView: some View {
        VStack(spacing: 0) {
            surveyPhotoGrid

            // Survey mode footer
            HStack {
                folderSwitcher

                Divider()
                    .frame(height: 14)

                Text(L.surveyModeLabel)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.accentColor)

                Text(L.surveyFooterHints(triage: cullingProfileTriage))
                    .font(.system(size: 11))
                    .foregroundColor(.gray)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    private var surveyPhotoGrid: some View {
        let count = surveyIndices.count
        let cols = surveyColumnCount(for: count)
        let rows = surveyRowCount(for: count)

        VStack(spacing: 2) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(0..<cols, id: \.self) { col in
                        let slot = row * cols + col
                        if slot < count {
                            let fileIndex = surveyIndices[slot]
                            if session.files.indices.contains(fileIndex) {
                                surveyPane(slot: slot, fileIndex: fileIndex)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                Color.clear
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        } else {
                            Color.clear
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func surveyPane(slot: Int, fileIndex: Int) -> some View {
        let isActive = slot == surveyActiveSlot
        let url = session.files[fileIndex]
        let entry = session.entries[url.lastPathComponent]

        VStack(spacing: 0) {
            ZStack {
                if let device = metalDevice {
                    MetalImageView(
                        texture: surveyTextures[fileIndex],
                        device: device,
                        zoomScale: zoomScale,
                        panOffset: panOffset,
                        reportedDrawableSize: isActive
                            ? $metalDrawableSize
                            : .constant(.zero)
                    )
                }

                VStack {
                    HStack(spacing: 6) {
                        Text("\(slot + 1)")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(HayateTheme.fg(1))
                            .frame(width: 24, height: 24)
                            .background(isActive ? Color.accentColor : HayateTheme.wash(0.3))
                            .cornerRadius(12)
                            .padding(8)

                        Spacer()

                        PhotoBadgeView(
                            entry: entry,
                            iconSize: 14,
                            starSize: 9,
                            spacing: 4,
                            padding: 6,
                            triageStyle: cullingProfileTriage
                        )
                        .padding(8)
                    }
                    Spacer()

                    if isActive {
                        Text(cullingProfileTriage ? "⏎ Keep" : "⏎ Pick")
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

            Text(url.deletingPathExtension().lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background(isActive ? Color.accentColor.opacity(0.3) : HayateTheme.bar)
                .foregroundColor(HayateTheme.fg(0.92))
                .font(.system(size: 11))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 3)
        )
    }

    // MARK: - Enter / exit

    func enterSurveyMode() {
        guard decoder != nil else { return }

        if showGrid && selectedIndices.count >= 2 {
            surveyIndices = Array(selectedIndices.sorted().prefix(6))
        } else {
            var indices = [session.currentIndex]
            if session.currentIndex < session.files.count - 1 {
                indices.append(session.currentIndex + 1)
            } else if session.currentIndex > 0 {
                indices.insert(session.currentIndex - 1, at: 0)
            }
            guard indices.count >= 2 else { return }
            surveyIndices = indices
        }

        compareMode = false
        compareIndices = []
        compareTextures = [:]
        compareActiveSlot = 0

        surveyTextureLoadTask?.cancel()
        surveyTextureLoadTask = nil
        surveyTextureGeneration &+= 1
        surveyActiveSlot = 0
        surveyTextures = [:]
        showGrid = false
        selectedIndices.removeAll()
        surveyMode = true
        resetZoom()
        session.currentIndex = surveyIndices[0]

        loadSurveyTextures()
    }

    func exitSurveyMode(returnToGrid: Bool = true) {
        surveyTextureLoadTask?.cancel()
        surveyTextureLoadTask = nil
        surveyTextureGeneration &+= 1
        surveyMode = false
        surveyIndices = []
        surveyTextures = [:]
        surveyActiveSlot = 0
        if returnToGrid {
            showGrid = true
        }
        loadCurrentImage()
    }

    // MARK: - Culling actions

    /// Return: Keep the active photo, Out/reject all others, return to grid.
    func decideSurveyWinner() {
        guard surveyMode, !surveyIndices.isEmpty else { return }
        guard surveyIndices.indices.contains(surveyActiveSlot) else { return }

        let winnerSlot = surveyActiveSlot
        let winnerIndex = surveyIndices[winnerSlot]
        guard session.files.indices.contains(winnerIndex) else {
            exitSurveyMode(returnToGrid: true)
            return
        }

        let otherIndices = surveyIndices.enumerated()
            .filter { $0.offset != winnerSlot }
            .compactMap { session.files.indices.contains($0.element) ? $0.element : nil }

        session.applySurveyDecision(
            winnerIndex: winnerIndex,
            otherIndices: otherIndices,
            triageMode: cullingProfileTriage,
            restore: .survey(
                indices: surveyIndices,
                activeSlot: surveyActiveSlot,
                currentIndex: session.currentIndex
            )
        )
        session.currentIndex = winnerIndex
        exitSurveyMode()
    }

    // MARK: - Grid layout & navigation

    func surveyColumnCount(for count: Int) -> Int {
        switch count {
        case 2: return 2
        case 3...4: return 2
        case 5...6: return 3
        default: return 2
        }
    }

    func surveyRowCount(for count: Int) -> Int {
        switch count {
        case 2: return 1
        case 3...6: return 2
        default: return 1
        }
    }

    func moveSurveySelection(keyCode: UInt16) {
        let count = surveyIndices.count
        guard count > 0 else { return }

        let cols = surveyColumnCount(for: count)
        let rows = surveyRowCount(for: count)
        let slot = surveyActiveSlot
        let row = slot / cols
        let col = slot % cols

        let newSlot: Int
        switch keyCode {
        case 123:
            guard slot > 0 else { return }
            newSlot = slot - 1
        case 124:
            guard slot + 1 < count else { return }
            newSlot = slot + 1
        case 126:
            let newRow = max(0, row - 1)
            let candidate = newRow * cols + col
            guard candidate < count else { return }
            newSlot = candidate
        case 125:
            let newRow = min(rows - 1, row + 1)
            let candidate = newRow * cols + col
            guard candidate < count else { return }
            newSlot = candidate
        default: return
        }

        let newIndex = surveyIndices[newSlot]
        guard session.files.indices.contains(newIndex) else { return }

        surveyActiveSlot = newSlot
        session.currentIndex = newIndex
    }

    // MARK: - Texture loading

    func loadSurveyTextures() {
        guard decoder != nil, surveyMode else { return }

        surveyTextureLoadTask?.cancel()
        let generation = surveyTextureGeneration
        let indices = surveyIndices.filter { surveyTextures[$0] == nil }
        guard !indices.isEmpty else { return }
        surveyTextureLoadTask = Task {
            for fileIndex in indices {
                guard !Task.isCancelled,
                      surveyMode,
                      surveyTextureGeneration == generation else { return }
                await loadSurveyTextureContent(for: fileIndex, generation: generation)
            }
        }
    }

    private func loadSurveyTextureContent(for fileIndex: Int, generation: UInt) async {
        guard surveyMode,
              surveyTextureGeneration == generation,
              session.files.indices.contains(fileIndex) else { return }

        let url = session.files[fileIndex]
        let displaySize = previewDisplaySize

        if focusPeakingEnabled {
            if let sendable = await loadFocusPeakingTexture(for: url, displaySize: displaySize) {
                guard !Task.isCancelled,
                      surveyMode,
                      surveyTextureGeneration == generation else { return }
                surveyTextures[fileIndex] = sendable.texture
            }
            return
        }

        guard let prefetchManager = prefetchManager else { return }
        let result = await prefetchManager.loadTexture(for: url, displaySize: displaySize) { partial in
            guard surveyMode, surveyTextureGeneration == generation else { return }
            surveyTextures[fileIndex] = partial.texture
        }
        guard !Task.isCancelled,
              surveyMode,
              surveyTextureGeneration == generation else { return }
        if let result = result {
            surveyTextures[fileIndex] = result.texture
        }
    }
}
