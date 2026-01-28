import AppKit
import Common
import PrivateApi

// MARK: - SkyLight Private API Wrapper

/// Wrapper for SkyLight private APIs that provide faster window management
/// These APIs require SIP to be partially disabled
public enum SkyLight {
    /// Get the main connection ID for SkyLight operations
    public static var mainConnectionID: Int32 {
        SLSMainConnectionID()
    }

    /// Check if SkyLight APIs are available (SIP check)
    public static var isAvailable: Bool {
        // Try to get the main connection ID - if it returns 0, SkyLight is not available
        return SLSMainConnectionID() != 0
    }

    // MARK: - Fast Front Process Query

    /// Get the PID of the front process using SkyLight (faster than NSWorkspace)
    public static func getFrontProcessPID() -> pid_t? {
        var psn = ProcessSerialNumber()
        guard _SLPSGetFrontProcess(&psn) == noErr else {
            return nil
        }

        // Get connection ID for the PSN, then get PID from connection
        var connectionId: Int32 = 0
        guard SLSGetConnectionIDForPSN(mainConnectionID, &psn, &connectionId) == .success else {
            return nil
        }

        var pid: pid_t = 0
        guard SLSConnectionGetPID(connectionId, &pid) == .success else {
            return nil
        }

        return pid
    }

    // MARK: - Fast Focus
    
    /// Focus a window using private APIs - much faster than AX API
    /// Returns true if successful
    @MainActor
    public static func focusWindow(windowId: UInt32, processSerialNumber: ProcessSerialNumber) -> Bool {
        var psn = processSerialNumber
        let result = _SLPSSetFrontProcessWithOptions(&psn, windowId, UInt32(kCPSUserGenerated))
        return result == .success
    }
    
    /// Get the ProcessSerialNumber for a window
    public static func getWindowPSN(windowId: UInt32) -> ProcessSerialNumber? {
        var windowConnection: Int32 = 0
        guard SLSGetWindowOwner(mainConnectionID, windowId, &windowConnection) == .success else {
            return nil
        }
        
        var psn = ProcessSerialNumber()
        // Use the window's connection to get its PSN
        guard SLSGetConnectionPSN(windowConnection, &psn) == .success else {
            return nil
        }
        
        return psn
    }
    
    /// Focus window by ID only (will look up PSN automatically)
    @MainActor
    public static func focusWindow(windowId: UInt32) -> Bool {
        guard let psn = getWindowPSN(windowId: windowId) else {
            return false
        }
        return focusWindow(windowId: windowId, processSerialNumber: psn)
    }
    
    // MARK: - Window Ordering
    
    /// Order a window relative to another window
    /// mode: 1 = above, -1 = below, 0 = out (hide)
    public static func orderWindow(_ windowId: UInt32, mode: Int32, relativeTo: UInt32 = 0) -> Bool {
        return SLSOrderWindow(mainConnectionID, windowId, mode, relativeTo) == .success
    }
    
    // MARK: - Transactions (Batch Operations)
    
    /// Create a transaction for batching multiple window operations
    public static func createTransaction() -> CFTypeRef? {
        let result = SLSTransactionCreate(mainConnectionID)
        return result?.takeUnretainedValue()
    }
    
    /// Commit a transaction
    /// synchronous: 0 = async, 1 = sync
    public static func commitTransaction(_ transaction: CFTypeRef, synchronous: Bool = false) -> Bool {
        return SLSTransactionCommit(transaction, synchronous ? 1 : 0) == .success
    }
    
    /// Add window order operation to transaction
    public static func transactionOrderWindow(_ transaction: CFTypeRef, windowId: UInt32, mode: Int32, relativeTo: UInt32 = 0) -> Bool {
        return SLSTransactionOrderWindow(transaction, windowId, mode, relativeTo) == .success
    }
    
    /// Add window alpha operation to transaction
    public static func transactionSetAlpha(_ transaction: CFTypeRef, windowId: UInt32, alpha: Float) -> Bool {
        return SLSTransactionSetWindowAlpha(transaction, windowId, alpha) == .success
    }
    
    // MARK: - Display Update Control
    
    /// Disable display updates (reduces flickering during batch operations)
    public static func disableUpdate() -> Bool {
        return SLSDisableUpdate(mainConnectionID) == .success
    }
    
    /// Re-enable display updates
    public static func reenableUpdate() -> Bool {
        return SLSReenableUpdate(mainConnectionID) == .success
    }
    
    // MARK: - Window Movement (faster than AX)

    /// Move a window to a new position
    public static func moveWindow(_ windowId: UInt32, to point: CGPoint) -> Bool {
        var p = point
        return SLSMoveWindow(mainConnectionID, windowId, &p) == .success
    }

    /// Move a window with its group (for grouped windows)
    public static func moveWindowWithGroup(_ windowId: UInt32, to point: CGPoint) -> Bool {
        var p = point
        return SLSMoveWindowWithGroup(mainConnectionID, windowId, &p) == .success
    }

    // MARK: - Window Bounds Query (faster than AX)

    /// Get window bounds using SkyLight (faster than AX API)
    public static func getWindowBounds(_ windowId: UInt32) -> CGRect? {
        var frame = CGRect.zero
        guard SLSGetWindowBounds(mainConnectionID, windowId, &frame) == .success else {
            return nil
        }
        return frame
    }

    // MARK: - Display Update Scope

    /// Execute a block with display updates disabled (reduces flickering)
    @discardableResult
    public static func withDisplayUpdatesDisabled<T>(_ block: () throws -> T) rethrows -> T {
        _ = disableUpdate()
        defer { _ = reenableUpdate() }
        return try block()
    }

    /// Async version of withDisplayUpdatesDisabled
    @discardableResult
    public static func withDisplayUpdatesDisabledAsync<T>(_ block: () async throws -> T) async rethrows -> T {
        _ = disableUpdate()
        defer { _ = reenableUpdate() }
        return try await block()
    }
    
    // MARK: - Window Alpha
    
    /// Set window alpha/opacity
    public static func setWindowAlpha(_ windowId: UInt32, alpha: Float) -> Bool {
        return SLSSetWindowAlpha(mainConnectionID, windowId, alpha) == .success
    }
    
    /// Get window alpha/opacity
    public static func getWindowAlpha(_ windowId: UInt32) -> Float? {
        var alpha: Float = 0
        guard SLSGetWindowAlpha(mainConnectionID, windowId, &alpha) == .success else {
            return nil
        }
        return alpha
    }

    // MARK: - Focused Window Query (using CGWindowList - public API but fast)

    /// Get the focused window ID using CGWindowListCopyWindowInfo (faster than AX API)
    /// Returns the frontmost window of the front process
    public static func getFocusedWindowId() -> UInt32? {
        guard let frontPid = getFrontProcessPID() else { return nil }

        // Get all windows for the front process
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // Find the first window belonging to the front process
        for windowInfo in windowList {
            guard let ownerPid = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPid == frontPid,
                  let windowId = windowInfo[kCGWindowNumber as String] as? UInt32,
                  let layer = windowInfo[kCGWindowLayer as String] as? Int,
                  layer == 0  // Normal window layer
            else { continue }

            return windowId
        }

        return nil
    }

    /// Check if a window is on screen (visible)
    public static func isWindowOnScreen(_ windowId: UInt32) -> Bool {
        var isOnScreen: UInt8 = 0
        guard SLSWindowIsOrderedIn(mainConnectionID, windowId, &isOnScreen) == .success else {
            return false
        }
        return isOnScreen != 0
    }
}

// MARK: - Batch Window Operations

extension SkyLight {
    /// Perform multiple window operations in a single transaction
    /// This is much faster than doing them individually
    public static func batchOperations(_ operations: (CFTypeRef) -> Void) -> Bool {
        guard let transaction = createTransaction() else { return false }
        operations(transaction)
        return commitTransaction(transaction)
    }

    /// Focus and raise a window in a single optimized operation
    @MainActor
    public static func focusAndRaiseWindow(windowId: UInt32, psn: ProcessSerialNumber) -> Bool {
        var mutablePsn = psn

        // Use the fast path: set front process with the specific window
        let result = _SLPSSetFrontProcessWithOptions(&mutablePsn, windowId, UInt32(kCPSUserGenerated))

        if result == .success {
            // Also order the window to front for good measure
            _ = orderWindow(windowId, mode: 1, relativeTo: 0)
            return true
        }

        return false
    }
}

// MARK: - Batch Layout Operations

/// Collector for batch window move operations
public final class SkyLightBatchMover {
    private var operations: [(windowId: UInt32, point: CGPoint)] = []

    public init() {}

    /// Queue a window move operation
    public func queueMove(windowId: UInt32, to point: CGPoint) {
        operations.append((windowId, point))
    }

    /// Execute all queued operations with display updates disabled
    @discardableResult
    public func execute() -> Bool {
        guard !operations.isEmpty else { return true }
        guard SkyLight.isAvailable else { return false }

        return SkyLight.withDisplayUpdatesDisabled {
            for op in operations {
                _ = SkyLight.moveWindow(op.windowId, to: op.point)
            }
            return true
        }
    }

    /// Number of queued operations
    public var count: Int { operations.count }

    /// Clear all queued operations
    public func clear() {
        operations.removeAll()
    }
}
