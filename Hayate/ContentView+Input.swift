import SwiftUI
import AppKit

/// Keyboard, scroll-wheel, and drag input handling for ContentView.
extension ContentView {

    // MARK: - Monitors

    func installKeyHandler() {
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

    func removeKeyHandler() {
        for monitor in [keyMonitor, scrollMonitor, dragMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitor = nil
        scrollMonitor = nil
        dragMonitor = nil
    }

    // MARK: - Keyboard

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        // ---- Fixed bindings that cannot be rebound ----

        // Escape — universal cancel / exit mode / reset zoom.
        if event.keyCode == 53 {
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
        }

        // Unmodified arrow keys in the grid — move within the filtered order;
        // ↑↓ jump by one (approximate) row, no-op at the edges. Modified
        // arrows fall through to the keybinding store.
        if showGrid, [123, 124, 125, 126].contains(event.keyCode),
           event.modifierFlags.intersection(Shortcut.relevantModifiers).isEmpty {
            switch event.keyCode {
            case 123: moveGridSelection(by: -1)
            case 124: moveGridSelection(by: 1)
            case 125: moveGridSelection(by: gridColumnCount, clamping: false)
            default:  moveGridSelection(by: -gridColumnCount, clamping: false)
            }
            return true
        }

        // Arrow keys — always navigate (alias for navigateBack / navigateForward).
        if event.keyCode == 123 || event.keyCode == 124 {
            return perform(event.keyCode == 123 ? .navigateBack : .navigateForward)
        }

        // Rating digits 0–5 (fixed — rating keys don't go through the store).
        if !event.modifierFlags.contains(.command),
           let chars = event.charactersIgnoringModifiers,
           chars.count == 1,
           let rating = Int(chars),
           (0...5).contains(rating) {
            let batch = showGrid && !selectedIndices.isEmpty
            let compareActive = compareMode && !compareIndices.isEmpty
            if compareActive {
                session.currentIndex = compareIndices[compareActiveSlot]
                session.setRating(rating)
            } else if batch {
                session.setRatingForIndices(selectedIndices, rating: rating)
            } else {
                session.setRating(rating)
                autoAdvanceIfEnabled()
            }
            return true
        }

        // ---- Dynamic bindings from KeybindingStore ----
        if let action = keybindings.action(for: event) {
            return perform(action)
        }

        return false
    }

    private func perform(_ action: ActionID) -> Bool {
        // Batch-aware operations: apply to selection if grid has multi-select.
        // In compare mode, operations apply to the active slot's photo.
        let batch = showGrid && !selectedIndices.isEmpty
        let compareActive = compareMode && !compareIndices.isEmpty

        switch action {
        case .navigateBack:
            if compareActive {
                compareActiveSlot = max(0, compareActiveSlot - 1)
                session.currentIndex = compareIndices[compareActiveSlot]
            } else {
                navigateBack()
            }
            return true

        case .navigateForward:
            if compareActive {
                compareActiveSlot = min(compareIndices.count - 1, compareActiveSlot + 1)
                session.currentIndex = compareIndices[compareActiveSlot]
            } else {
                navigateForward()
            }
            return true

        case .toggleFavorite:
            if compareActive {
                session.currentIndex = compareIndices[compareActiveSlot]
                session.toggleFavorite()
            } else if batch {
                session.toggleFavoriteForIndices(selectedIndices)
            } else {
                session.toggleFavorite()
                autoAdvanceIfEnabled()
            }
            return true

        case .toggleRejected:
            if compareActive {
                session.currentIndex = compareIndices[compareActiveSlot]
                session.toggleRejected()
            } else if batch {
                session.toggleRejectedForIndices(selectedIndices)
            } else {
                session.toggleRejected()
                autoAdvanceIfEnabled()
            }
            return true

        case .toggleGrid:
            if compareMode { exitCompareMode() }
            showGrid.toggle()
            if !showGrid { selectedIndices.removeAll() }
            return true

        case .toggleCompare:
            if compareMode {
                exitCompareMode()
            } else {
                enterCompareMode()
            }
            return true

        case .toggleFitZoom:
            if zoomScale > 1.01 {
                zoomScale = 1.0
                panOffset = .zero
            } else {
                zoomScale = 2.0
                panOffset = .zero
                loadFullResolutionIfNeeded()
            }
            return true

        case .toggleFocusPeaking:
            if compareMode { return false }
            focusPeakingEnabled.toggle()
            loadCurrentImage()
            return true

        case .toggleInfo:
            if compareMode || showGrid { return false }
            showInfo.toggle()
            if showInfo {
                loadEXIF()
            } else {
                currentEXIF = nil
            }
            return true

        case .toggleHistogram:
            if compareMode || showGrid { return false }
            showHistogram.toggle()
            if showHistogram {
                updateHistogram()
            } else {
                histogramData = nil
            }
            return true

        case .deletePhoto:
            if showGrid && !selectedIndices.isEmpty {
                pendingDeletionIndices = selectedIndices
            } else {
                pendingDeletionIndices = nil
            }
            showDeleteConfirmation = true
            return true

        case .undo:
            session.undo()
            loadCurrentImage()
            return true

        case .selectAllGrid:
            guard showGrid else { return false }
            if selectedIndices.count == filteredFiles.count {
                selectedIndices.removeAll()
            } else {
                selectedIndices = Set(filteredFiles.map(\.index))
            }
            return true

        case .openFolder:
            session.requestOpenFolder()
            return true

        case .pickCompare:
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

        case .skipNextBaseline:
            if compareActive {
                skipToNextBaseline()
                return true
            }
            return false
        }
    }

    /// Photo Mechanic-style auto-advance: jump to the next photo after a
    /// rating action in the single-photo view (opt-in via Settings).
    private func autoAdvanceIfEnabled() {
        guard autoAdvance, !showGrid, !compareMode else { return }
        navigateForward()
    }

    // MARK: - Scroll & drag (zoom / pan)

    private func handleScrollEvent(_ event: NSEvent) {
        if event.type == .magnify {
            // Trackpad pinch-to-zoom
            let delta = event.magnification
            zoomScale = max(1.0, min(zoomScale * (1.0 + delta), 10.0))
            if zoomScale <= 1.01 { panOffset = .zero }
            loadFullResolutionIfNeeded()
        } else if event.type == .scrollWheel {
            if event.modifierFlags.contains(.option) || zoomScale <= 1.01 {
                // Option+scroll or not zoomed: zoom in/out
                let delta = event.scrollingDeltaY * 0.01
                zoomScale = max(1.0, min(zoomScale * (1.0 + delta), 10.0))
                if zoomScale <= 1.01 { panOffset = .zero }
                loadFullResolutionIfNeeded()
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

    func resetZoom() {
        zoomScale = 1.0
        panOffset = .zero
    }
}
