import SwiftUI
import MetalKit

/// Compare mode: side-by-side photos with a pick/skip culling workflow.
extension ContentView {

    var compareView: some View {
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
                                    panOffset: panOffset,
                                    reportedDrawableSize: slot == compareActiveSlot
                                        ? $metalDrawableSize
                                        : .constant(.zero)
                                )
                            }

                            // Top-left: slot number + active badge
                            VStack {
                                HStack(spacing: 6) {
                                    // Slot number (always visible)
                                    Text("\(slot + 1)")
                                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                                        .foregroundColor(HayateTheme.fg(1))
                                        .frame(width: 24, height: 24)
                                        .background(isActive ? Color.accentColor : HayateTheme.wash(0.3))
                                        .cornerRadius(12)
                                        .padding(8)

                                    Spacer()

                                    // Status badges (top right)
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

                                // Keep / Pick hint on active slot
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

                        // Per-photo file name bar
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
            }

            // Compare mode footer
            HStack {
                folderSwitcher

                Divider()
                    .frame(height: 14)

                Text("COMPARE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.accentColor)

                Text(L.compareFooterHints(triage: cullingProfileTriage))
                    .font(.system(size: 11))
                    .foregroundColor(.gray)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
        }
    }

    func enterCompareMode() {
        guard decoder != nil else { return }

        // Determine which photos to compare. Pick/Skip is a 2-photo tournament —
        // keep the UI matched to that (extra grid selection is ignored).
        if showGrid && selectedIndices.count >= 2 {
            compareIndices = Array(selectedIndices.sorted().prefix(2))
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

    /// Enter: mark the active photo Keep (or favorite), Out/reject the other,
    /// keep the winner on the left, and load the next challenger on the right.
    func pickActivePhoto() {
        guard compareIndices.count == 2 else { return }

        let pickedIndex = compareIndices[compareActiveSlot]
        let otherSlot = compareActiveSlot == 0 ? 1 : 0
        let rejectedIndex = compareIndices[otherSlot]

        let restore = ModeRestore.compare(
            indices: compareIndices,
            activeSlot: compareActiveSlot,
            currentIndex: session.currentIndex
        )
        session.applyComparePick(
            pickedIndex: pickedIndex,
            rejectedIndex: rejectedIndex,
            triageMode: cullingProfileTriage,
            restore: restore
        )

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
    func skipToNextBaseline() {
        guard compareIndices.count == 2 else { return }

        let restore = ModeRestore.compare(
            indices: compareIndices,
            activeSlot: compareActiveSlot,
            currentIndex: session.currentIndex
        )
        session.recordModeRestore(restore)

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

    func exitCompareMode() {
        compareMode = false
        compareIndices = []
        compareTextures = [:]
        compareActiveSlot = 0
        loadCurrentImage()
    }

    /// Restore compare or survey UI after undoing a pick/skip/decide action.
    func applyModeRestore(_ restore: ModeRestore?) {
        guard let restore else {
            if !compareMode && !surveyMode {
                loadCurrentImage()
            }
            return
        }

        switch restore {
        case .compare(let indices, let activeSlot, let currentIndex):
            guard indices.count >= 2,
                  indices.allSatisfy({ session.files.indices.contains($0) }),
                  indices.indices.contains(activeSlot) else {
                if !compareMode && !surveyMode {
                    loadCurrentImage()
                }
                return
            }

            let enteringCompare = !compareMode

            if surveyMode {
                surveyTextureLoadTask?.cancel()
                surveyTextureLoadTask = nil
                surveyTextureGeneration &+= 1
                surveyMode = false
                surveyIndices = []
                surveyTextures = [:]
                surveyActiveSlot = 0
            }

            compareMode = true
            showGrid = false
            selectedIndices.removeAll()
            compareIndices = indices
            compareActiveSlot = activeSlot
            session.currentIndex = currentIndex

            if enteringCompare {
                compareTextures = [:]
                resetZoom()
            } else {
                let indexSet = Set(indices)
                compareTextures = compareTextures.filter { indexSet.contains($0.key) }
            }
            loadCompareTextures()

        case .survey(let indices, let activeSlot, let currentIndex):
            guard indices.count >= 2,
                  indices.allSatisfy({ session.files.indices.contains($0) }),
                  indices.indices.contains(activeSlot) else {
                if !compareMode && !surveyMode {
                    loadCurrentImage()
                }
                return
            }

            let enteringSurvey = !surveyMode

            if compareMode {
                compareMode = false
                compareIndices = []
                compareTextures = [:]
                compareActiveSlot = 0
            }

            surveyTextureLoadTask?.cancel()
            surveyTextureLoadTask = nil
            surveyTextureGeneration &+= 1
            surveyMode = true
            showGrid = false
            selectedIndices.removeAll()
            surveyIndices = indices
            surveyActiveSlot = activeSlot
            session.currentIndex = currentIndex

            if enteringSurvey {
                surveyTextures = [:]
                resetZoom()
            } else {
                let indexSet = Set(indices)
                surveyTextures = surveyTextures.filter { indexSet.contains($0.key) }
            }
            loadSurveyTextures()
        }
    }

    // MARK: - Texture loading

    /// Load textures for every slot in `compareIndices`. A single Task drives the
    /// loads sequentially so the `compareTextures` @State dictionary is never
    /// written concurrently from multiple tasks.
    func loadCompareTextures() {
        guard decoder != nil else { return }
        let indices = compareIndices.filter { compareTextures[$0] == nil }
        guard !indices.isEmpty else { return }
        Task {
            for fileIndex in indices {
                await loadCompareTextureContent(for: fileIndex)
            }
        }
    }

    /// Load the texture for a single slot in its own Task.
    private func loadCompareTexture(for fileIndex: Int) {
        guard decoder != nil else { return }
        Task {
            await loadCompareTextureContent(for: fileIndex)
        }
    }

    /// Shared load path: the unified PrefetchManager pipeline (memory → disk →
    /// JPEG → RAW). Focus peaking reuses cached RAW or full-res decodes when
    /// available, otherwise runs the same pipeline then derives peaking.
    private func loadCompareTextureContent(for fileIndex: Int) async {
        guard compareMode,
              compareIndices.contains(fileIndex),
              session.files.indices.contains(fileIndex) else { return }

        let url = session.files[fileIndex]
        let displaySize = previewDisplaySize

        if focusPeakingEnabled {
            if let sendable = await loadFocusPeakingTexture(for: url, displaySize: displaySize) {
                guard compareMode,
                      compareIndices.contains(fileIndex),
                      session.files.indices.contains(fileIndex) else { return }
                compareTextures[fileIndex] = sendable.texture
            }
            return
        }

        guard let prefetchManager = prefetchManager else { return }
        let result = await prefetchManager.loadTexture(for: url, displaySize: displaySize) { partial in
            guard compareMode,
                  compareIndices.contains(fileIndex),
                  session.files.indices.contains(fileIndex) else { return }
            compareTextures[fileIndex] = partial.texture
        }
        guard compareMode,
              compareIndices.contains(fileIndex),
              session.files.indices.contains(fileIndex) else { return }
        if let result = result {
            compareTextures[fileIndex] = result.texture
        }
    }
}
