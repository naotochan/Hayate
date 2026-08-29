import SwiftUI
import AppKit
import MetalKit

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

        // Escape — dismiss onboarding / shortcuts help, then universal cancel.
        if event.keyCode == 53 {
            if showOnboarding {
                showOnboarding = false
                hasCompletedOnboarding = true
                return true
            }
            if showShortcutsHelp {
                showShortcutsHelp = false
                return true
            }
            if compareMode {
                exitCompareMode()
                return true
            }
            if surveyMode {
                exitSurveyMode()
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

        // Help overlay — layout-independent.
        // 1) Character "?" (US Shift+/, JIS "?")  2) bare "/"  3) ANSI slash key
        // Kept fixed (like Escape): keyCodes for "?" differ across keyboards.
        if event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            let isQuestion = event.characters == "?"
            let isBareSlash = event.modifierFlags.intersection(Shortcut.relevantModifiers).isEmpty
                && (event.charactersIgnoringModifiers == "/" || event.keyCode == 44)
            let isShiftSlash = event.keyCode == 44
                && event.modifierFlags.contains(.shift)
            if isQuestion || isBareSlash || isShiftSlash {
                if showOnboarding { return true }
                showShortcutsHelp.toggle()
                return true
            }
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

        // Arrow keys in survey — move the active pane within the grid layout.
        if surveyMode, [123, 124, 125, 126].contains(event.keyCode),
           event.modifierFlags.intersection(Shortcut.relevantModifiers).isEmpty {
            moveSurveySelection(keyCode: event.keyCode)
            return true
        }

        // Arrow keys — always navigate (alias for navigateBack / navigateForward).
        if event.keyCode == 123 || event.keyCode == 124 {
            return perform(event.keyCode == 123 ? .navigateBack : .navigateForward)
        }

        // Rating digits 0–5 (fixed — rating keys don't go through the store).
        // Ignored in triage profile (use P / M / X instead).
        if !cullingProfileTriage,
           !event.modifierFlags.contains(.command),
           let chars = event.charactersIgnoringModifiers,
           chars.count == 1,
           let rating = Int(chars),
           (0...5).contains(rating) {
            let batch = showGrid && !selectedIndices.isEmpty
            let compareActive = compareMode && !compareIndices.isEmpty
            let surveyActive = surveyMode && !surveyIndices.isEmpty
            if compareActive {
                session.currentIndex = compareIndices[compareActiveSlot]
                session.setRating(rating)
            } else if surveyActive {
                session.currentIndex = surveyIndices[surveyActiveSlot]
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
        let surveyActive = surveyMode && !surveyIndices.isEmpty

        switch action {
        case .navigateBack:
            if surveyActive {
                moveSurveySelection(keyCode: 123)
            } else if compareActive {
                compareActiveSlot = max(0, compareActiveSlot - 1)
                session.currentIndex = compareIndices[compareActiveSlot]
            } else if showGrid {
                moveGridSelection(by: -1)
            } else {
                navigateBack()
            }
            return true

        case .navigateForward:
            if surveyActive {
                moveSurveySelection(keyCode: 124)
            } else if compareActive {
                compareActiveSlot = min(compareIndices.count - 1, compareActiveSlot + 1)
                session.currentIndex = compareIndices[compareActiveSlot]
            } else if showGrid {
                moveGridSelection(by: 1)
            } else {
                navigateForward()
            }
            return true

        case .toggleFavorite:
            if cullingProfileTriage {
                applyTriage(.keep, batch: batch, compareActive: compareActive, surveyActive: surveyActive)
            } else if compareActive {
                session.currentIndex = compareIndices[compareActiveSlot]
                session.toggleFavorite()
            } else if surveyActive {
                session.currentIndex = surveyIndices[surveyActiveSlot]
                session.toggleFavorite()
            } else if batch {
                session.toggleFavoriteForIndices(selectedIndices)
            } else {
                session.toggleFavorite()
                autoAdvanceIfEnabled()
            }
            return true

        case .toggleRejected:
            if cullingProfileTriage {
                applyTriage(.out, batch: batch, compareActive: compareActive, surveyActive: surveyActive)
            } else if compareActive {
                session.currentIndex = compareIndices[compareActiveSlot]
                session.toggleRejected()
            } else if surveyActive {
                session.currentIndex = surveyIndices[surveyActiveSlot]
                session.toggleRejected()
            } else if batch {
                session.toggleRejectedForIndices(selectedIndices)
            } else {
                session.toggleRejected()
                autoAdvanceIfEnabled()
            }
            return true

        case .setTriageMaybe:
            guard cullingProfileTriage else { return false }
            applyTriage(.maybe, batch: batch, compareActive: compareActive, surveyActive: surveyActive)
            return true

        case .toggleGrid:
            if surveyMode {
                exitSurveyMode(returnToGrid: true)
                return true
            }
            if compareMode { exitCompareMode() }
            showGrid.toggle()
            if !showGrid { selectedIndices.removeAll() }
            return true

        case .toggleCompare:
            if surveyMode { exitSurveyMode(returnToGrid: false) }
            if compareMode {
                exitCompareMode()
            } else {
                enterCompareMode()
            }
            return true

        case .toggleSurvey:
            if compareMode { exitCompareMode() }
            if surveyMode {
                exitSurveyMode(returnToGrid: true)
            } else {
                enterSurveyMode()
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
            isOneToOneZoomTarget = false
            updatePanCursor(dragging: false)
            return true

        case .toggleOneToOneZoom:
            toggleOneToOneZoom()
            return true

        case .toggleFocusPeaking:
            if compareMode || surveyMode { return false }
            focusPeakingEnabled.toggle()
            loadCurrentImage()
            return true

        case .toggleInfo:
            if compareMode || surveyMode || showGrid { return false }
            showInfo.toggle()
            if showInfo {
                loadEXIF()
            } else {
                currentEXIF = nil
            }
            return true

        case .toggleHistogram:
            if compareMode || surveyMode || showGrid { return false }
            showHistogram.toggle()
            if showHistogram {
                updateHistogram()
            } else {
                histogramData = nil
            }
            return true

        case .toggleShortcutsHelp:
            showShortcutsHelp.toggle()
            return true

        case .toggleSidebar:
            sidebarVisible.toggle()
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
            let visibleCount = gridDisplayItems.count
            if selectedIndices.count == visibleCount,
               Set(gridDisplayItems.map(\.fileIndex)) == selectedIndices {
                selectedIndices.removeAll()
            } else {
                selectAllVisibleGridItems()
            }
            return true

        case .openFolder:
            session.requestOpenFolder()
            return true

        case .pickCompare:
            if surveyMode {
                decideSurveyWinner()
                return true
            }
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
            if surveyMode { return true }
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
        guard autoAdvance, !showGrid, !compareMode, !surveyMode else { return }
        navigateForward()
    }

    private func applyTriage(
        _ state: CullingSession.TriageState,
        batch: Bool,
        compareActive: Bool,
        surveyActive: Bool = false
    ) {
        if compareActive {
            session.currentIndex = compareIndices[compareActiveSlot]
            session.setTriage(state)
        } else if surveyActive {
            session.currentIndex = surveyIndices[surveyActiveSlot]
            session.setTriage(state)
        } else if batch {
            session.setTriageForIndices(selectedIndices, state)
        } else {
            session.setTriage(state)
            autoAdvanceIfEnabled()
        }
    }

    // MARK: - Scroll & drag (zoom / pan)

    private func handleScrollEvent(_ event: NSEvent) {
        if event.type == .magnify {
            // Trackpad pinch-to-zoom
            let delta = event.magnification
            zoomScale = max(1.0, min(zoomScale * (1.0 + delta), 10.0))
            if zoomScale <= 1.01 { panOffset = .zero }
            isOneToOneZoomTarget = false
            updatePanCursor(dragging: false)
            loadFullResolutionIfNeeded()
        } else if event.type == .scrollWheel {
            if event.modifierFlags.contains(.option) || zoomScale <= 1.01 {
                // Option+scroll or not zoomed: zoom in/out
                let delta = event.scrollingDeltaY * 0.01
                zoomScale = max(1.0, min(zoomScale * (1.0 + delta), 10.0))
                if zoomScale <= 1.01 { panOffset = .zero }
                isOneToOneZoomTarget = false
                updatePanCursor(dragging: false)
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
        guard zoomScale > 1.01, !showGrid else {
            lastDragPoint = nil
            if event.type == .leftMouseUp || event.type == .leftMouseDown {
                updatePanCursor(dragging: false)
            }
            return
        }

        switch event.type {
        case .leftMouseDown:
            lastDragPoint = event.locationInWindow
            updatePanCursor(dragging: true)
        case .leftMouseDragged:
            updatePanCursor(dragging: true)
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
            updatePanCursor(dragging: false)
        default:
            break
        }
    }

    /// Open hand while zoomed (pannable); closed hand while dragging; arrow otherwise.
    func updatePanCursor(dragging: Bool) {
        if zoomScale > 1.01, !showGrid {
            (dragging ? NSCursor.closedHand : NSCursor.openHand).set()
        } else {
            NSCursor.arrow.set()
        }
    }

    func resetZoom() {
        zoomScale = 1.0
        panOffset = .zero
        isOneToOneZoomTarget = false
        updatePanCursor(dragging: false)
    }

    // MARK: - 1:1 zoom

    func toggleOneToOneZoom() {
        if isOneToOneZoomTarget {
            zoomScale = 1.0
            panOffset = .zero
            isOneToOneZoomTarget = false
            updatePanCursor(dragging: false)
            return
        }

        guard let oneToOne = currentOneToOneZoomScale() else { return }

        applyOneToOneZoom(oneToOneScale: oneToOne, preservePan: zoomScale > 1.01)
        isOneToOneZoomTarget = true
        loadFullResolutionIfNeeded()
        updatePanCursor(dragging: false)
    }

    /// Re-apply 1:1 after full-res texture swap (metadata vs decoded size may differ slightly).
    func syncOneToOneZoomAfterFullResLoad() {
        guard isOneToOneZoomTarget else { return }
        guard let oneToOne = currentOneToOneZoomScale(preferTexture: true) else { return }
        applyOneToOneZoom(oneToOneScale: oneToOne, preservePan: true)
    }

    private func applyOneToOneZoom(oneToOneScale: CGFloat, preservePan: Bool) {
        let previousScale = max(zoomScale, 1.0)
        let targetScale = min(max(oneToOneScale, 1.0), 10.0)
        zoomScale = targetScale
        if targetScale <= 1.001 {
            panOffset = .zero
        } else if preservePan, previousScale > 1.01 {
            let ratio = targetScale / previousScale
            panOffset = CGPoint(x: panOffset.x * ratio, y: panOffset.y * ratio)
        } else {
            panOffset = .zero
        }
    }

    private func currentOneToOneZoomScale(preferTexture: Bool = false) -> CGFloat? {
        let imageSize: CGSize?
        if preferTexture, let texture = currentZoomTexture() {
            imageSize = CGSize(width: texture.width, height: texture.height)
        } else if let url = currentZoomFileURL() {
            imageSize = ImageDecoder.orientedPixelSize(url: url)
        } else {
            imageSize = nil
        }
        guard let imageSize, imageSize.width > 0, imageSize.height > 0 else { return nil }

        let drawableSize = effectiveDrawableSizeForZoom()
        guard drawableSize.width > 0, drawableSize.height > 0 else { return nil }
        return MetalImageView.oneToOneZoomScale(textureSize: imageSize, drawableSize: drawableSize)
    }

    private func currentZoomFileURL() -> URL? {
        if surveyMode, !surveyIndices.isEmpty {
            let index = surveyIndices[surveyActiveSlot]
            guard session.files.indices.contains(index) else { return nil }
            return session.files[index]
        }
        if compareMode, !compareIndices.isEmpty {
            let index = compareIndices[compareActiveSlot]
            guard session.files.indices.contains(index) else { return nil }
            return session.files[index]
        }
        return session.currentFile
    }

    private func currentZoomTexture() -> MTLTexture? {
        if surveyMode, !surveyIndices.isEmpty {
            return surveyTextures[surveyIndices[surveyActiveSlot]]
        }
        if compareMode, !compareIndices.isEmpty {
            return compareTextures[compareIndices[compareActiveSlot]]
        }
        return currentTexture
    }

    private func effectiveDrawableSizeForZoom() -> CGSize {
        if metalDrawableSize.width > 0, metalDrawableSize.height > 0 {
            return metalDrawableSize
        }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let contentView = window.contentView else {
            return .zero
        }
        let scale = window.backingScaleFactor
        var size = contentView.bounds.size
        if surveyMode, !surveyIndices.isEmpty {
            let cols = surveyColumnCount(for: surveyIndices.count)
            let rows = surveyRowCount(for: surveyIndices.count)
            size.width /= CGFloat(cols)
            size.height /= CGFloat(rows)
        } else if compareMode, compareIndices.count > 1 {
            size.width /= CGFloat(compareIndices.count)
        }
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}
