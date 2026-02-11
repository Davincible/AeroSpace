import AppKit
import Common

/// Serializable tree node that can be either a container or a window
enum SerializedTreeNode: Codable, Sendable {
    case container(SerializedContainer)
    case window(SerializedWindow)

    enum CodingKeys: String, CodingKey {
        case type
        case layout
        case orientation
        case weight
        case children
        case appBundleId
        case windowTitle
        case x, y, width, height
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "container":
            let layout = try container.decode(String.self, forKey: .layout)
            let orientation = try container.decode(String.self, forKey: .orientation)
            let weight = try container.decode(CGFloat.self, forKey: .weight)
            let children = try container.decode([SerializedTreeNode].self, forKey: .children)
            self = .container(SerializedContainer(children: children, layout: layout, orientation: orientation, weight: weight))
        case "window":
            let appBundleId = try container.decode(String.self, forKey: .appBundleId)
            let windowTitle = try container.decode(String.self, forKey: .windowTitle)
            let weight = try container.decode(CGFloat.self, forKey: .weight)
            let x = try container.decodeIfPresent(CGFloat.self, forKey: .x)
            let y = try container.decodeIfPresent(CGFloat.self, forKey: .y)
            let width = try container.decodeIfPresent(CGFloat.self, forKey: .width)
            let height = try container.decodeIfPresent(CGFloat.self, forKey: .height)
            self = .window(SerializedWindow(appBundleId: appBundleId, windowTitle: windowTitle, weight: weight, x: x, y: y, width: width, height: height))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .container(let c):
            try container.encode("container", forKey: .type)
            try container.encode(c.layout, forKey: .layout)
            try container.encode(c.orientation, forKey: .orientation)
            try container.encode(c.weight, forKey: .weight)
            try container.encode(c.children, forKey: .children)
        case .window(let w):
            try container.encode("window", forKey: .type)
            try container.encode(w.appBundleId, forKey: .appBundleId)
            try container.encode(w.windowTitle, forKey: .windowTitle)
            try container.encode(w.weight, forKey: .weight)
            try container.encodeIfPresent(w.x, forKey: .x)
            try container.encodeIfPresent(w.y, forKey: .y)
            try container.encodeIfPresent(w.width, forKey: .width)
            try container.encodeIfPresent(w.height, forKey: .height)
        }
    }
}

/// Serializable container node
struct SerializedContainer: Codable, Sendable {
    let children: [SerializedTreeNode]
    let layout: String  // "tiles" | "accordion"
    let orientation: String // "h" | "v"
    let weight: CGFloat

    init(children: [SerializedTreeNode], layout: String, orientation: String, weight: CGFloat) {
        self.children = children
        self.layout = layout
        self.orientation = orientation
        self.weight = weight
    }

    @MainActor
    init(_ container: TilingContainer) {
        children = container.children.compactMap { child -> SerializedTreeNode? in
            switch child.nodeCases {
            case .window(let w):
                return .window(SerializedWindow(w))
            case .tilingContainer(let c):
                return .container(SerializedContainer(c))
            case .workspace,
                 .macosMinimizedWindowsContainer,
                 .macosHiddenAppsWindowsContainer,
                 .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer:
                return nil
            }
        }
        layout = container.layout.rawValue
        orientation = container.orientation == .h ? "h" : "v"
        weight = getWeightOrNil(container) ?? 1
    }
}

/// Serializable window identified by app bundle ID and window title
struct SerializedWindow: Codable, Sendable {
    let appBundleId: String
    let windowTitle: String
    let weight: CGFloat
    // Window position and size (optional for backwards compatibility)
    let x: CGFloat?
    let y: CGFloat?
    let width: CGFloat?
    let height: CGFloat?

    init(appBundleId: String, windowTitle: String, weight: CGFloat, x: CGFloat? = nil, y: CGFloat? = nil, width: CGFloat? = nil, height: CGFloat? = nil) {
        self.appBundleId = appBundleId
        self.windowTitle = windowTitle
        self.weight = weight
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    @MainActor
    init(_ window: Window) {
        appBundleId = window.app.rawAppBundleId ?? ""
        windowTitle = ""
        weight = getWeightOrNil(window) ?? 1
        x = nil
        y = nil
        width = nil
        height = nil
    }
}

/// Data collected for each window during save
struct WindowSaveData: Sendable {
    let title: String
    let rect: Rect?
}

/// Serializable workspace
struct SerializedWorkspace: Codable, Sendable {
    let name: String
    let rootTilingNode: SerializedContainer
    let floatingWindows: [SerializedWindow]

    @MainActor
    init(_ workspace: Workspace, windowData: [UInt32: WindowSaveData]) {
        name = workspace.name
        rootTilingNode = SerializedContainer.createWithData(workspace.rootTilingContainer, windowData: windowData)
        floatingWindows = workspace.floatingWindows.map { window in
            let data = windowData[window.windowId]
            return SerializedWindow(
                appBundleId: window.app.rawAppBundleId ?? "",
                windowTitle: data?.title ?? "",
                weight: getWeightOrNil(window) ?? 1,
                x: data?.rect?.topLeftX,
                y: data?.rect?.topLeftY,
                width: data?.rect?.width,
                height: data?.rect?.height
            )
        }
    }
    
    /// Private memberwise initializer for creating merged workspaces
    private init(name: String, rootTilingNode: SerializedContainer, floatingWindows: [SerializedWindow]) {
        self.name = name
        self.rootTilingNode = rootTilingNode
        self.floatingWindows = floatingWindows
    }
    
    /// Merge this workspace with an existing one, preserving windows from existing that aren't in current
    func mergedWith(existing: SerializedWorkspace) -> SerializedWorkspace {
        // Build set of current window keys (appBundleId + windowTitle)
        var currentWindowKeys: Set<WindowMergeKey> = []
        collectWindowKeys(from: rootTilingNode, into: &currentWindowKeys)
        for window in floatingWindows {
            currentWindowKeys.insert(WindowMergeKey(appBundleId: window.appBundleId, windowTitle: window.windowTitle))
        }
        
        // Collect windows from existing state that are not in current state
        var preservedTilingWindows: [SerializedWindow] = []
        collectMissingWindows(from: existing.rootTilingNode, currentKeys: currentWindowKeys, into: &preservedTilingWindows)
        
        var preservedFloatingWindows: [SerializedWindow] = []
        for window in existing.floatingWindows {
            let key = WindowMergeKey(appBundleId: window.appBundleId, windowTitle: window.windowTitle)
            if !currentWindowKeys.contains(key) {
                preservedFloatingWindows.append(window)
            }
        }
        
        // Merge: current root + preserved tiling windows added to root, current floating + preserved floating
        let mergedRoot = rootTilingNode.appendingWindows(preservedTilingWindows)
        let mergedFloating = floatingWindows + preservedFloatingWindows
        
        return SerializedWorkspace(name: name, rootTilingNode: mergedRoot, floatingWindows: mergedFloating)
    }
}

/// Key for identifying windows during merge (by app bundle ID and window title)
private struct WindowMergeKey: Hashable {
    let appBundleId: String
    let windowTitle: String
}

/// Collect all window keys from a container tree
private func collectWindowKeys(from container: SerializedContainer, into keys: inout Set<WindowMergeKey>) {
    for child in container.children {
        switch child {
        case .window(let w):
            keys.insert(WindowMergeKey(appBundleId: w.appBundleId, windowTitle: w.windowTitle))
        case .container(let c):
            collectWindowKeys(from: c, into: &keys)
        }
    }
}

/// Collect windows from container tree that are not in the current keys set
private func collectMissingWindows(from container: SerializedContainer, currentKeys: Set<WindowMergeKey>, into windows: inout [SerializedWindow]) {
    for child in container.children {
        switch child {
        case .window(let w):
            let key = WindowMergeKey(appBundleId: w.appBundleId, windowTitle: w.windowTitle)
            if !currentKeys.contains(key) {
                windows.append(w)
            }
        case .container(let c):
            collectMissingWindows(from: c, currentKeys: currentKeys, into: &windows)
        }
    }
}

extension SerializedContainer {
    /// Create a new container with additional windows appended to its children
    func appendingWindows(_ windows: [SerializedWindow]) -> SerializedContainer {
        guard !windows.isEmpty else { return self }
        let newChildren = children + windows.map { SerializedTreeNode.window($0) }
        return SerializedContainer(children: newChildren, layout: layout, orientation: orientation, weight: weight)
    }
}

/// The complete serialized world state
struct SerializedWorld: Codable, Sendable {
    let workspaces: [SerializedWorkspace]
    let visibleWorkspacePerMonitor: [String]

    @MainActor
    init(workspaces: [Workspace], monitors: [Monitor], windowData: [UInt32: WindowSaveData], existingWorld: SerializedWorld? = nil) {
        // Build current workspaces from live state
        var currentWorkspaces = workspaces
            .filter { !$0.isEffectivelyEmpty }
            .map { SerializedWorkspace($0, windowData: windowData) }
        
        // If there's existing state, merge windows from it
        if let existingWorld = existingWorld {
            // Build index of existing workspaces by name
            var existingWorkspacesByName: [String: SerializedWorkspace] = [:]
            for ws in existingWorld.workspaces {
                existingWorkspacesByName[ws.name] = ws
            }
            
            // Build set of current workspace names
            let currentWorkspaceNames = Set(currentWorkspaces.map { $0.name })
            
            // Merge windows into current workspaces
            currentWorkspaces = currentWorkspaces.map { currentWs in
                guard let existingWs = existingWorkspacesByName[currentWs.name] else {
                    return currentWs
                }
                return currentWs.mergedWith(existing: existingWs)
            }
            
            // Add workspaces that only exist in old state (not currently open)
            for existingWs in existingWorld.workspaces {
                if !currentWorkspaceNames.contains(existingWs.name) {
                    currentWorkspaces.append(existingWs)
                }
            }
        }
        
        self.workspaces = currentWorkspaces
        self.visibleWorkspacePerMonitor = monitors.map { $0.activeWorkspace.name }
    }
}

// MARK: - Helper Extensions

extension SerializedContainer {
    @MainActor
    static func createWithData(_ container: TilingContainer, windowData: [UInt32: WindowSaveData]) -> SerializedContainer {
        let children = container.children.compactMap { child -> SerializedTreeNode? in
            switch child.nodeCases {
            case .window(let w):
                let data = windowData[w.windowId]
                return .window(SerializedWindow(
                    appBundleId: w.app.rawAppBundleId ?? "",
                    windowTitle: data?.title ?? "",
                    weight: getWeightOrNil(w) ?? 1,
                    x: data?.rect?.topLeftX,
                    y: data?.rect?.topLeftY,
                    width: data?.rect?.width,
                    height: data?.rect?.height
                ))
            case .tilingContainer(let c):
                return .container(createWithData(c, windowData: windowData))
            case .workspace,
                 .macosMinimizedWindowsContainer,
                 .macosHiddenAppsWindowsContainer,
                 .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer:
                return nil
            }
        }
        return SerializedContainer(
            children: children,
            layout: container.layout.rawValue,
            orientation: container.orientation == .h ? "h" : "v",
            weight: getWeightOrNil(container) ?? 1
        )
    }
}

@MainActor
private func getWeightOrNil(_ node: TreeNode) -> CGFloat? {
    ((node.parent as? TilingContainer)?.orientation).map { node.getWeight($0) }
}
