// MARK: - Tab Demotion/Promotion State

/// Tracks the tiling slot a tab group's active window occupied before being demoted.
/// Keyed by tab group key (PID + bounds composite). When a different tab in the same
/// group becomes active, it can reclaim this slot instead of being placed at the end.
@MainActor
private var demotedTabSlots: [String: BindingData] = [:]

/// Tracks per-window suspended slots. When a window is individually demoted (e.g., it
/// was the active tab and got switched away), we save its binding data here so it can
/// be restored if it becomes active again.
///
/// Internal visibility required: accessed by MacWindow.garbageCollect() for cleanup.
@MainActor
var suspendedWindowSlots: [UInt32: BindingData] = [:]

// MARK: - normalizeLayoutReason

@MainActor
func normalizeLayoutReason() async throws {
    for workspace in Workspace.all {
        let windows: [Window] = workspace.allLeafWindowsRecursive
        try await _normalizeLayoutReason(workspace: workspace, windows: windows)
    }
    try await _normalizeLayoutReason(workspace: focus.workspace, windows: macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self))
    try await validateStillPopups()

    // Clear demoted tab slots at the end of the normalization cycle.
    // They are only valid within a single refresh pass — if a promoted tab didn't
    // claim the slot this cycle, the slot is stale.
    demotedTabSlots.removeAll()
}

@MainActor
private func validateStillPopups() async throws {
    // Snapshot children before iterating because promotion mutates the collection
    let children = Array(macosPopupWindowsContainer.children)
    for node in children {
        guard let popup = node as? MacWindow else { continue }

        // If this window is still a background tab, leave it in the popup container
        if isBackgroundTab(popup.windowId) { continue }

        // If this window isn't on screen, it can't be promoted yet
        if !isWindowOnScreen(popup.windowId) {
            // Still check the original heuristic — a non-tab popup that went off-screen
            // might legitimately need promotion (e.g., a real popup that became a window)
            let windowLevel = getWindowLevel(for: popup.windowId)
            if try await popup.isWindowHeuristic(windowLevel) {
                try await popup.relayoutWindow(on: focus.workspace)
                try await tryOnWindowDetected(popup)
            }
            continue
        }

        // This window is on-screen and not a background tab — promote it.
        // Try to restore to a saved slot if one exists.
        if let slot = tryRestoreTabSlot(for: popup) {
            // Clamp: siblings may have been removed since the slot was saved.
            let clampedIndex = min(slot.index, slot.parent.children.count)
            popup.bind(to: slot.parent, adaptiveWeight: slot.adaptiveWeight, index: clampedIndex)
            try await tryOnWindowDetected(popup)
        } else {
            // No saved slot — fall back to standard relayout
            let windowLevel = getWindowLevel(for: popup.windowId)
            if try await popup.isWindowHeuristic(windowLevel) {
                try await popup.relayoutWindow(on: focus.workspace)
                try await tryOnWindowDetected(popup)
            }
        }
    }
}

/// Attempts to find a saved tiling slot for a tab being promoted.
/// Checks per-window slots first (highest specificity), then tab-group slots.
/// Returns nil if no valid slot exists.
@MainActor
private func tryRestoreTabSlot(for window: MacWindow) -> BindingData? {
    // 1. Check per-window suspended slot
    if let slot = suspendedWindowSlots.removeValue(forKey: window.windowId) {
        // Also clean group-level slot to prevent stale references
        if let groupKey = tabGroupKey(for: window.windowId) {
            demotedTabSlots.removeValue(forKey: groupKey)
        }
        if isParentAlive(slot) {
            return slot
        }
    }

    // 2. Check tab-group slot
    if let groupKey = tabGroupKey(for: window.windowId),
       let slot = demotedTabSlots.removeValue(forKey: groupKey) {
        suspendedWindowSlots.removeValue(forKey: window.windowId) // clean up cross-reference
        if isParentAlive(slot) {
            return slot
        }
    }

    return nil
}

/// Validates that a saved BindingData's parent is still part of a live workspace tree.
/// Prevents restoring a window to a parent that has been garbage collected or detached.
@MainActor
private func isParentAlive(_ bindingData: BindingData) -> Bool {
    var node: (any NonLeafTreeNodeObject)? = bindingData.parent
    while let n = node {
        if n is Workspace { return true }
        node = n.parent
    }
    return false
}

@MainActor
private func _normalizeLayoutReason(workspace: Workspace, windows: [Window]) async throws {
    for window in windows {
        let isMacosFullscreen = try await window.isMacosFullscreen
        let isMacosMinimized = try await (!isMacosFullscreen).andAsync { @MainActor @Sendable in try await window.isMacosMinimized }
        let isMacosWindowOfHiddenApp = !isMacosFullscreen && !isMacosMinimized &&
            !config.automaticallyUnhideMacosHiddenApps && window.macAppUnsafe.nsApp.isHidden
        switch window.layoutReason {
            case .standard:
                guard let parent = window.parent else { continue }
                if isMacosFullscreen {
                    window.layoutReason = .macos(prevParentKind: parent.kind)
                    window.bind(to: workspace.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                } else if isMacosMinimized {
                    window.layoutReason = .macos(prevParentKind: parent.kind)
                    window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                } else if isMacosWindowOfHiddenApp {
                    window.layoutReason = .macos(prevParentKind: parent.kind)
                    window.bind(to: workspace.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                } else if isBackgroundTab(window.asMacWindow().windowId) {
                    // Demote: this tiled/floating window is now a background tab.
                    // Save its tiling slot so the tab group can reclaim it later.
                    //
                    // Note: layoutReason intentionally left as .standard (not changed to .macos).
                    // Background tab promotion is handled by validateStillPopups(), not by the
                    // .macos case in exitMacOsNativeUnconventionalState(). This avoids conflating
                    // tab state with macOS native fullscreen/minimize/hide state.
                    let bindingData = window.unbindFromParent()
                    if let groupKey = tabGroupKey(for: window.asMacWindow().windowId) {
                        demotedTabSlots[groupKey] = bindingData
                    }
                    suspendedWindowSlots[window.windowId] = bindingData
                    window.bind(to: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
                }
            case .macos(let prevParentKind):
                if !isMacosFullscreen && !isMacosMinimized && !isMacosWindowOfHiddenApp {
                    try await exitMacOsNativeUnconventionalState(window: window, prevParentKind: prevParentKind, workspace: workspace)
                }
        }
    }
}

@MainActor
func exitMacOsNativeUnconventionalState(window: Window, prevParentKind: NonLeafTreeNodeKind, workspace: Workspace) async throws {
    window.layoutReason = .standard
    switch prevParentKind {
        case .workspace:
            window.bindAsFloatingWindow(to: workspace)
        case .tilingContainer:
            try await window.relayoutWindow(on: workspace, forceTile: true)
        case .macosPopupWindowsContainer: // Since the window was minimized/fullscreened it was mistakenly detected as popup. Relayout the window
            try await window.relayoutWindow(on: workspace)
        case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer: // wtf case, should never be possible. But If encounter it, let's just re-layout window
            try await window.relayoutWindow(on: workspace)
    }
}
