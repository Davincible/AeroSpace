import CoreGraphics
import Foundation

@MainActor
private var windowLevelCache: [UInt32: MacOsWindowLevel] = [:]

// MARK: - Tab Detection Cache

@MainActor
private var onScreenWindowIds: Set<UInt32> = []

@MainActor
private var tabGroupsCache: [String: TabGroup] = [:]

private struct TabGroup {
    let pid: Int32
    let bounds: CGRect
    var activeWindowId: UInt32?
    var backgroundWindowIds: Set<UInt32>
}

// MARK: - Public Query Functions

@MainActor
func getWindowLevel(for windowId: UInt32) -> MacOsWindowLevel? {
    windowLevelCache[windowId]
}

@MainActor
func isWindowOnScreen(_ windowId: UInt32) -> Bool {
    onScreenWindowIds.contains(windowId)
}

@MainActor
private var backgroundTabIds: Set<UInt32> = []

@MainActor
private var windowToTabGroupKey: [UInt32: String] = [:]

@MainActor
func isBackgroundTab(_ windowId: UInt32) -> Bool {
    backgroundTabIds.contains(windowId)
}

@MainActor
func tabGroupKey(for windowId: UInt32) -> String? {
    windowToTabGroupKey[windowId]
}

// MARK: - Cache Refresh

/// Refreshes all window caches (levels, on-screen set, tab groups) from a single
/// CGWindowListCopyWindowInfo call. Called at the start of each refresh cycle.
///
/// Tab grouping algorithm: Windows with the SAME PID and IDENTICAL bounds at layer 0
/// (normal window level) are tab group candidates. If exactly one is on-screen and
/// one or more are not on-screen, they form a tab group. This detects native macOS
/// tabs (NSWindow.addTabbedWindow) where each tab is a separate NSWindow that shares
/// the same frame as the active tab.
@MainActor
func refreshWindowAndTabCaches() {
    // Use .optionAll (not .optionOnScreenOnly) so we can see background tabs.
    // Background tabs are off-screen NSWindows that share bounds with the active tab.
    let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionAll)
    guard let cfArray = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [CFDictionary] else { return }

    var newLevels: [UInt32: MacOsWindowLevel] = [:]
    var newOnScreen: Set<UInt32> = []

    // Intermediate structure for tab group detection: key -> (onScreen: [...], offScreen: [...])
    struct BoundsGroupEntry {
        var onScreenIds: [UInt32] = []
        var offScreenIds: [UInt32] = []
        let pid: Int32
        let bounds: CGRect
    }
    var boundsGroups: [String: BoundsGroupEntry] = [:]

    for elem in cfArray {
        let dict = elem as NSDictionary

        guard let _windowId = dict[kCGWindowNumber] else { continue }
        let windowId = ((_windowId as! CFNumber) as NSNumber).uint32Value

        guard let _windowLayer = dict[kCGWindowLayer] else { continue }
        let windowLayer = ((_windowLayer as! CFNumber) as NSNumber).intValue

        newLevels[windowId] = .new(windowLevel: windowLayer)

        let windowIsOnScreen: Bool
        if let _onScreen = dict[kCGWindowIsOnscreen] {
            windowIsOnScreen = CFBooleanGetValue((_onScreen as! CFBoolean))
        } else {
            windowIsOnScreen = false
        }

        if windowIsOnScreen {
            newOnScreen.insert(windowId)
        }

        // Tab group detection: only consider layer-0 (normal) windows
        guard windowLayer == 0 else { continue }

        guard let _pid = dict[kCGWindowOwnerPID] else { continue }
        let pid = ((_pid as! CFNumber) as NSNumber).int32Value

        guard let boundsDict = dict[kCGWindowBounds] as? [String: Any] else { continue }
        guard let x = (boundsDict["X"] as? NSNumber)?.doubleValue,
              let y = (boundsDict["Y"] as? NSNumber)?.doubleValue,
              let w = (boundsDict["Width"] as? NSNumber)?.doubleValue,
              let h = (boundsDict["Height"] as? NSNumber)?.doubleValue
        else { continue }

        // Composite key: PID + pixel-aligned bounds. Tabbed windows share identical frames.
        // Round to integers to avoid non-deterministic Double string representations.
        let groupKey = "\(pid)_\(Int(x.rounded()))_\(Int(y.rounded()))_\(Int(w.rounded()))_\(Int(h.rounded()))"

        var entry = boundsGroups[groupKey] ?? BoundsGroupEntry(pid: pid, bounds: CGRect(x: x, y: y, width: w, height: h))
        if windowIsOnScreen {
            entry.onScreenIds.append(windowId)
        } else {
            entry.offScreenIds.append(windowId)
        }
        boundsGroups[groupKey] = entry
    }

    // Build tab groups: exactly 1 on-screen + 1 or more off-screen = tab group.
    //
    // Known limitation (false positives): Two non-tabbed windows from the same app
    // at pixel-identical coordinates where one is off-screen would be misidentified
    // as a tab group. In practice this is extremely unlikely — AeroSpace tiles windows
    // to non-overlapping positions, and the "exactly 1 on-screen" guard prevents most
    // false matches. The worst case is a background tab that's actually just a hidden
    // window, which will be harmlessly demoted and re-promoted on the next cycle.
    var newTabGroups: [String: TabGroup] = [:]
    for (key, entry) in boundsGroups {
        guard entry.onScreenIds.count == 1, !entry.offScreenIds.isEmpty else { continue }

        newTabGroups[key] = TabGroup(
            pid: entry.pid,
            bounds: entry.bounds,
            activeWindowId: entry.onScreenIds[0],
            backgroundWindowIds: Set(entry.offScreenIds)
        )
    }

    // Build reverse lookups for O(1) tab queries
    var newBackgroundIds: Set<UInt32> = []
    var newWindowToGroup: [UInt32: String] = [:]
    for (key, group) in newTabGroups {
        newBackgroundIds.formUnion(group.backgroundWindowIds)
        if let active = group.activeWindowId { newWindowToGroup[active] = key }
        for bgId in group.backgroundWindowIds { newWindowToGroup[bgId] = key }
    }

    windowLevelCache = newLevels
    onScreenWindowIds = newOnScreen
    tabGroupsCache = newTabGroups
    backgroundTabIds = newBackgroundIds
    windowToTabGroupKey = newWindowToGroup
}

enum MacOsWindowLevel: Sendable, Equatable {
    case normalWindow
    case alwaysOnTopWindow
    case unknown(windowLevel: Int)

    static func new(windowLevel: Int) -> MacOsWindowLevel {
        switch windowLevel {
            case 0: .normalWindow
            case 3: .alwaysOnTopWindow
            default: .unknown(windowLevel: windowLevel)
        }
    }

    static func fromJson(_ json: Json) -> MacOsWindowLevel? {
        switch json {
            case .string(let str) where str == "normalWindow": .normalWindow
            case .string(let str) where str == "alwaysOnTopWindow": .alwaysOnTopWindow
            case .int(let int): .new(windowLevel: int)
            default: nil
        }
    }

    func toJson() -> Json {
        switch self {
            case .normalWindow: .string("normalWindow")
            case .alwaysOnTopWindow: .string("alwaysOnTopWindow")
            case .unknown(let layerNumber): .int(layerNumber)
        }
    }
}
