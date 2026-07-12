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

    func enterCompareMode() {
        guard decoder != nil else { return }

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
    func pickActivePhoto() {
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
    func skipToNextBaseline() {
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

    func exitCompareMode() {
        compareMode = false
        compareIndices = []
        compareTextures = [:]
        compareActiveSlot = 0
        loadCurrentImage()
    }

    // MARK: - Texture loading

    /// Load textures for every slot in `compareIndices`. A single Task drives the
    /// loads sequentially so the `compareTextures` @State dictionary is never
    /// written concurrently from multiple tasks.
    private func loadCompareTextures() {
        guard decoder != nil else { return }
        let indices = compareIndices
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
    /// JPEG → RAW). Focus peaking skips the cache fast paths and decodes the
    /// RAW directly.
    private func loadCompareTextureContent(for fileIndex: Int) async {
        guard let decoder = decoder else { return }
        let url = session.files[fileIndex]
        let displaySize = previewDisplaySize

        if focusPeakingEnabled {
            if let sendable = await decoder.decodeRAW(url: url, displaySize: displaySize, focusPeaking: true) {
                compareTextures[fileIndex] = sendable.texture
            }
            return
        }

        guard let prefetchManager = prefetchManager else { return }
        let result = await prefetchManager.loadTexture(for: url, displaySize: displaySize) { partial in
            compareTextures[fileIndex] = partial.texture
        }
        if let result = result {
            compareTextures[fileIndex] = result.texture
        }
    }
}
