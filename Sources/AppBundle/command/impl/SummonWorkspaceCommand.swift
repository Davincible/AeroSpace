import AppKit
import Common

struct SummonWorkspaceCommand: Command {
    let args: SummonWorkspaceCmdArgs
    /*conforms*/ var shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        let workspace = Workspace.get(byName: args.target.val.raw)
        let monitor = focus.workspace.workspaceMonitor

        if monitor.activeWorkspace == workspace {
            if !args.failIfNoop {
                io.err("Workspace '\(workspace.name)' is already visible on the focused monitor. Tip: use --fail-if-noop to exit with non-zero code")
            }
            return !args.failIfNoop
        }

        if !workspace.isVisible {
            // then we just need to summon the workspace to the focused monitor
            if monitor.setActiveWorkspace(workspace) {
                return workspace.focusWorkspace(source: .keyboardShortcut)
            } else {
                return io.err("Can't move workspace '\(workspace.name)' to monitor '\(monitor.name)'. workspace-to-monitor-force-assignment doesn't allow it")
            }
        } else {
            let otherMonitor = workspace.workspaceMonitor
            let currentWorkspace = monitor.activeWorkspace

            switch args.whenVisible {
                case .swap:
                    if otherMonitor.setActiveWorkspace(currentWorkspace) && monitor.setActiveWorkspace(workspace) {
                        return workspace.focusWorkspace(source: .keyboardShortcut)
                    } else {
                        return io.err("Can't swap workspaces due to monitor force assignment restrictions")
                    }
                case .focus:
                    return workspace.focusWorkspace(source: .keyboardShortcut)
            }
        }
    }
}
