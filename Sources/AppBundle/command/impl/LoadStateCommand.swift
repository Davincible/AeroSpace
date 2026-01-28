import AppKit
import Common
import Foundation

struct LoadStateCommand: Command {
    let args: LoadStateCmdArgs
    /*conforms*/ var shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        let verbose = args.verbose
        // Get file path from args or config
        guard let filePath = args.filePath ?? config.stateFilePath else {
            return io.err("No file path provided and 'state-file' not configured in aerospace.toml")
        }

        let expandedPath = (filePath as NSString).expandingTildeInPath
        let fileUrl = URL(fileURLWithPath: expandedPath)

        // Read and parse the JSON file
        let jsonData: Data
        do {
            jsonData = try Data(contentsOf: fileUrl)
        } catch {
            return io.err("Failed to read state file: \(error.localizedDescription)")
        }

        let serializedWorld: SerializedWorld
        do {
            serializedWorld = try JSONDecoder().decode(SerializedWorld.self, from: jsonData)
        } catch {
            return io.err("Failed to parse state file: \(error.localizedDescription)")
        }

        // Collect all current windows
        var allCurrentWindows: [(MacWindow, String, String)] = [] // (window, appBundleId, title)
        for window in MacWindow.allWindows {
            let title = try await window.title
            let appBundleId = window.app.rawAppBundleId ?? ""
            allCurrentWindows.append((window, appBundleId, title))
        }
        
        // Build app name cache for efficient lookup
        var appNameCache: [String: String] = [:]
        for (_, macApp) in MacApp.allAppsMap {
            if let bundleId = macApp.rawAppBundleId, let name = macApp.name {
                appNameCache[bundleId] = name
            }
        }
        // Also cache from running applications (for apps not in MacApp.allAppsMap)
        for app in NSWorkspace.shared.runningApplications {
            if let bundleId = app.bundleIdentifier, let name = app.localizedName, appNameCache[bundleId] == nil {
                appNameCache[bundleId] = name
            }
        }

        // Build an index of windows from the state file
        var stateFileWindows: [WindowKey: WindowPlacement] = [:]
        var workspaceToContainers: [Workspace: [TilingContainer]] = [:]
        
        // First pass: build tree structures and index all windows from state file
        for serializedWorkspace in serializedWorld.workspaces {
            let workspace = Workspace.get(byName: serializedWorkspace.name)
            
            // Unbind old root container
            let prevRoot = workspace.rootTilingContainer
            let potentialOrphans = prevRoot.allLeafWindowsRecursive
            prevRoot.unbindFromParent()
            
            // Build tree structure and collect window placements
            var containerPath: [TilingContainer] = []
            buildTreeAndIndexWindows(
                serializedContainer: serializedWorkspace.rootTilingNode,
                parent: workspace,
                containerPath: &containerPath,
                workspace: workspace,
                stateFileWindows: &stateFileWindows
            )
            
            // Index floating windows
            for serializedWindow in serializedWorkspace.floatingWindows {
                let key = WindowKey(appBundleId: serializedWindow.appBundleId, title: serializedWindow.windowTitle)
                stateFileWindows[key] = WindowPlacement(
                    serializedWindow: serializedWindow,
                    workspace: workspace,
                    isFloating: true,
                    containerPath: nil,
                    weight: serializedWindow.weight
                )
            }
            
            workspaceToContainers[workspace] = containerPath
            
            // Handle orphaned windows
            for window in (potentialOrphans - workspace.rootTilingContainer.allLeafWindowsRecursive) {
                try await window.relayoutWindow(on: workspace, forceTile: true)
            }
        }

        var matchedCount = 0
        var unmatchedCount = 0
        
        // Track windows that need position restoration
        var windowsToRestore: [(MacWindow, SerializedWindow)] = []
        
        // Track which windows were matched (for verbose logging)
        var matchedWindows: Set<UInt32> = []
        
        // Second pass: loop through current windows and match them to state file
        for (window, appBundleId, title) in allCurrentWindows {
            // Try to find a match in the state file
            let key = WindowKey(appBundleId: appBundleId, title: title)
            var placement: WindowPlacement? = stateFileWindows[key]
            
            // If exact match failed, try fuzzy match
            if placement == nil {
                for (stateKey, statePlacement) in stateFileWindows {
                    if stateKey.appBundleId == appBundleId {
                        let stateTitle = stateKey.title
                        if title == stateTitle || title.contains(stateTitle) || stateTitle.contains(title) {
                            placement = statePlacement
                            // Remove from stateFileWindows so it's not matched twice
                            stateFileWindows.removeValue(forKey: stateKey)
                            break
                        }
                    }
                }
            } else {
                // Remove exact match so it's not matched twice
                stateFileWindows.removeValue(forKey: key)
            }
            
            if let placement = placement {
                // Match found - place window in the appropriate location
                if placement.isFloating {
                    window.bindAsFloatingWindow(to: placement.workspace)
                } else if let containerPath = placement.containerPath, let targetContainer = containerPath.last {
                    window.bind(to: targetContainer, adaptiveWeight: placement.weight, index: INDEX_BIND_LAST)
                }
                
                windowsToRestore.append((window, placement.serializedWindow))
                matchedCount += 1
                matchedWindows.insert(window.windowId)
            } else {
                unmatchedCount += 1
            }
        }

        // Set visible workspaces per monitor (safely check bounds)
        let currentMonitors = monitors
        for (index, workspaceName) in serializedWorld.visibleWorkspacePerMonitor.enumerated() {
            if index < currentMonitors.count {
                let workspace = Workspace.get(byName: workspaceName)
                _ = currentMonitors[index].setActiveWorkspace(workspace)
            }
        }

        // Trigger layout refresh before restoring positions
        refreshModel()

        // Restore window positions and sizes
        for (window, serializedWindow) in windowsToRestore {
            if let x = serializedWindow.x, let y = serializedWindow.y {
                let topLeft = CGPoint(x: x, y: y)
                let size: CGSize?
                if let w = serializedWindow.width, let h = serializedWindow.height {
                    size = CGSize(width: w, height: h)
                } else {
                    size = nil
                }
                window.setAxFrame(topLeft, size)
            }
        }

        io.out("State loaded from \(expandedPath)")
        io.out("Matched \(matchedCount) windows, \(unmatchedCount) windows not found")
        
        // Output verbose logs if requested - loop through current windows
        if verbose {
            for (window, appBundleId, title) in allCurrentWindows {
                let appName = window.app.name ?? appNameCache[appBundleId] ?? appBundleId
                if matchedWindows.contains(window.windowId) {
                    io.out("\(appName) | \(title) (matched by app/window name)")
                } else {
                    io.out("\(appName) | \(title) (unmatched)")
                }
            }
        }
        
        return true
    }
}

private struct WindowKey: Hashable {
    let appBundleId: String
    let title: String
}

private struct WindowPlacement {
    let serializedWindow: SerializedWindow
    let workspace: Workspace
    let isFloating: Bool
    let containerPath: [TilingContainer]? // nil for floating, array of containers for tiled (root to leaf)
    let weight: CGFloat
}


/// Build the tree structure and index windows from the state file
@MainActor
private func buildTreeAndIndexWindows(
    serializedContainer: SerializedContainer,
    parent: NonLeafTreeNodeObject,
    containerPath: inout [TilingContainer],
    workspace: Workspace,
    stateFileWindows: inout [WindowKey: WindowPlacement]
) {
    let orientation: Orientation = serializedContainer.orientation == "h" ? .h : .v
    let layout: Layout = serializedContainer.layout == "accordion" ? .accordion : .tiles

    let container = TilingContainer(
        parent: parent,
        adaptiveWeight: serializedContainer.weight,
        orientation,
        layout,
        index: INDEX_BIND_LAST
    )
    
    containerPath.append(container)

    // Process children
    for child in serializedContainer.children {
        switch child {
        case .window(let serializedWindow):
            let key = WindowKey(appBundleId: serializedWindow.appBundleId, title: serializedWindow.windowTitle)
            stateFileWindows[key] = WindowPlacement(
                serializedWindow: serializedWindow,
                workspace: workspace,
                isFloating: false,
                containerPath: Array(containerPath), // Copy of current path
                weight: serializedWindow.weight
            )
        case .container(let nestedContainer):
            buildTreeAndIndexWindows(
                serializedContainer: nestedContainer,
                parent: container,
                containerPath: &containerPath,
                workspace: workspace,
                stateFileWindows: &stateFileWindows
            )
        }
    }
    
    containerPath.removeLast()
}
