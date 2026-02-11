import AppKit
import Common
import PrivateApi

@MainActor
var appForTests: (any AbstractApp)? = nil

// Cache for fast focus - when we set focus ourselves, we know the window ID
@MainActor
var lastFastFocusedWindowId: UInt32? = nil
@MainActor
var lastFastFocusedPid: pid_t? = nil
@MainActor
var lastFastFocusedTime: CFAbsoluteTime = 0

/// Invalidate the fast focus cache
@MainActor
func invalidateFastFocusCache() {
    lastFastFocusedWindowId = nil
    lastFastFocusedPid = nil
    lastFastFocusedTime = 0
}

/// Update the fast focus cache
@MainActor
func updateFastFocusCache(windowId: UInt32, pid: pid_t) {
    lastFastFocusedWindowId = windowId
    lastFastFocusedPid = pid
    lastFastFocusedTime = CFAbsoluteTimeGetCurrent()
}

/// Check if the fast focus cache is still valid (not stale)
@MainActor
private func isFastFocusCacheValid() -> Bool {
    // Cache expires after 500ms to handle edge cases
    let cacheAge = CFAbsoluteTimeGetCurrent() - lastFastFocusedTime
    return cacheAge < 0.5
}

@MainActor
private var focusedApp: (any AbstractApp)? {
    get async throws {
        if isUnitTest {
            return appForTests
        } else {
            check(appForTests == nil)

            // Fast path: use SkyLight to get front process PID
            if config.useFastFocus, let pid = SkyLight.getFrontProcessPID() {
                return MacApp.allAppsMap[pid]
            }

            // Fallback to NSWorkspace
            return try await NSWorkspace.shared.frontmostApplication.flatMapAsyncMainActor(MacApp.getOrRegister)
        }
    }
}

@MainActor
func getNativeFocusedWindow() async throws -> Window? {
    // Fast path 1: if we recently set focus ourselves and the front process matches,
    // return the cached window directly without any query
    if config.useFastFocus,
       isFastFocusCacheValid(),
       let cachedWindowId = lastFastFocusedWindowId,
       let cachedPid = lastFastFocusedPid,
       let frontPid = SkyLight.getFrontProcessPID(),
       cachedPid == frontPid,
       let window = MacWindow.allWindowsMap[cachedWindowId]
    {
        // Verify window is still valid and on visible workspace
        if window.visualWorkspace?.isVisible == true {
            PerfLog.info("QUERY", "getNativeFocusedWindow: cache-hit wid=\(cachedWindowId)")
            return window
        } else {
            // Window moved to invisible workspace, invalidate cache
            invalidateFastFocusCache()
        }
    }

    // Fast path 2: use SkyLight to get focused window directly (much faster than AX)
    if config.useFastFocus && SkyLight.isAvailable {
        if let focusedWindowId = SkyLight.getFocusedWindowId(),
           let window = MacWindow.allWindowsMap[focusedWindowId]
        {
            // Update cache for next time
            updateFastFocusCache(windowId: focusedWindowId, pid: window.macApp.pid)
            PerfLog.info("QUERY", "getNativeFocusedWindow: skylight-window wid=\(focusedWindowId)")
            return window
        }

        // Fast path 3: get front process and find its first on-screen window
        if let frontPid = SkyLight.getFrontProcessPID(),
           MacApp.allAppsMap[frontPid] != nil
        {
            // Find the first window of this app that's on screen
            for window in MacWindow.allWindows where window.macApp.pid == frontPid {
                if SkyLight.isWindowOnScreen(window.windowId) {
                    updateFastFocusCache(windowId: window.windowId, pid: frontPid)
                    PerfLog.info("QUERY", "getNativeFocusedWindow: skylight-process wid=\(window.windowId)")
                    return window
                }
            }
        }
    }

    // Fallback to AX-based query (slow but reliable)
    PerfLog.info("QUERY", "getNativeFocusedWindow: ax-fallback")
    return try await PerfLog.measureAsync("QUERY", "getFocusedWindow-ax") {
        try await focusedApp?.getFocusedWindow()
    }
}
