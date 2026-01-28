import AppKit
import Common

struct PrintTreeCommand: Command {
    let args: PrintTreeCmdArgs
    /*conforms*/ var shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        let focus = focus
        var workspaces: Set<Workspace> = []
        
        if args.filteringOptions.focused {
            workspaces = [focus.workspace]
        } else if !args.filteringOptions.workspaces.isEmpty {
            workspaces = args.filteringOptions.workspaces
                .flatMap { filter in
                    switch filter {
                        case .focused: [focus.workspace]
                        case .visible: Workspace.all.filter(\.isVisible)
                        case .name(let name): [Workspace.get(byName: name.raw)]
                    }
                }
                .toSet()
        } else if !args.filteringOptions.monitors.isEmpty {
            let monitors: Set<CGPoint> = args.filteringOptions.monitors.resolveMonitors(io)
            if monitors.isEmpty { return false }
            workspaces = Workspace.all.filter { monitors.contains($0.workspaceMonitor.rect.topLeftCorner) }.toSet()
        } else {
            // Default to all workspaces
            workspaces = Workspace.all.toSet()
        }
        
        if workspaces.isEmpty {
            return io.err("No workspaces found matching the criteria")
        }
        
        // Print tree for each workspace
        let sortedWorkspaces = workspaces.sorted(by: { $0.name < $1.name })
        for (index, workspace) in sortedWorkspaces.enumerated() {
            let treeOutput = await printTree(workspace: workspace, prefix: "")
            io.out("Workspace: \(workspace.name)")
            io.out(treeOutput)
            if index < sortedWorkspaces.count - 1 {
                io.out("") // Empty line between workspaces
            }
        }
        
        return true
    }
}

@MainActor
private func printTree(workspace: Workspace, prefix: String) async -> String {
    var output: [String] = []
    let hasFloatingWindows = !workspace.floatingWindows.isEmpty
    await printTreeNode(node: workspace.rootTilingContainer, prefix: prefix, isLast: !hasFloatingWindows, output: &output)
    
    // Print floating windows if any
    if hasFloatingWindows {
        output.append("\(prefix)└─ Floating Windows")
        for (index, window) in workspace.floatingWindows.enumerated() {
            let isLast = index == workspace.floatingWindows.count - 1
            let childPrefix = prefix + "   "
            let title = (try? await window.title) ?? "<unknown>"
            output.append("\(childPrefix)\(isLast ? "└" : "├")─ Window: \(title)")
        }
    }
    
    return output.joined(separator: "\n")
}

@MainActor
private func printTreeNode(node: TreeNode, prefix: String, isLast: Bool, output: inout [String]) async {
    let connector = isLast ? "└" : "├"
    let nodeLabel: String
    
    switch node.nodeCases {
    case .window(let window):
        let title = (try? await window.title) ?? "<unknown>"
        nodeLabel = "Window: \(title)"
    case .tilingContainer(let container):
        let orientation = container.orientation == .h ? "horizontal" : "vertical"
        let layout = container.layout == .tiles ? "tiles" : "accordion"
        nodeLabel = "Container (\(orientation) \(layout))"
    case .workspace:
        nodeLabel = "Workspace"
    case .macosMinimizedWindowsContainer:
        nodeLabel = "Minimized Windows Container"
    case .macosHiddenAppsWindowsContainer:
        nodeLabel = "Hidden Apps Container"
    case .macosFullscreenWindowsContainer:
        nodeLabel = "Fullscreen Windows Container"
    case .macosPopupWindowsContainer:
        nodeLabel = "Popup Windows Container"
    }
    
    output.append("\(prefix)\(connector)─ \(nodeLabel)")
    
    // Print children
    let children = node.children
    if !children.isEmpty {
        let childPrefix = prefix + (isLast ? "   " : "│  ")
        for (index, child) in children.enumerated() {
            let childIsLast = index == children.count - 1
            await printTreeNode(node: child, prefix: childPrefix, isLast: childIsLast, output: &output)
        }
    }
}

