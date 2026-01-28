import OrderedCollections

private let workspace = "<workspace>"
private let workspaces = "\(workspace)..."

public struct PrintTreeCmdArgs: CmdArgs {
    public let rawArgsForStrRepr: EquatableNoop<StrArrSlice>
    public static let parser: CmdParser<Self> = cmdParser(
        kind: .printTree,
        allowInConfig: false,
        help: """
            Print the tree structure of workspaces using ASCII art.
            
            The tree shows:
            - Container nodes with their orientation (H for horizontal, V for vertical) and layout
            - Window nodes with their titles
            
            Options:
            --focused          Print tree of the focused workspace
            --workspace        Print tree of specific workspace(s)
            --monitor         Print tree of workspace(s) on specific monitor(s)
            
            Examples:
            aerospace print-tree --focused
            aerospace print-tree --workspace 1
            aerospace print-tree --monitor focused
            """,
        flags: [
            "--focused": trueBoolFlag(\.filteringOptions.focused),
            "--monitor": SubArgParser(\.filteringOptions.monitors, parseMonitorIdsForPrintTree),
            "--workspace": SubArgParser(\.filteringOptions.workspaces, parseWorkspacesForPrintTree),
        ],
        posArgs: [],
        conflictingOptions: [
            ["--focused", "--workspace"],
            ["--focused", "--monitor"],
        ],
    )

    public var filteringOptions = FilteringOptions()

    /*conforms*/ public var windowId: UInt32?
    /*conforms*/ public var workspaceName: WorkspaceName?

    public struct FilteringOptions: ConvenienceCopyable, Equatable, Sendable {
        public var monitors: [MonitorId] = []
        public var focused: Bool = false
        public var workspaces: [WorkspaceFilter] = []
    }
}

public func parsePrintTreeCmdArgs(_ args: StrArrSlice) -> ParsedCmd<PrintTreeCmdArgs> {
    parseSpecificCmdArgs(PrintTreeCmdArgs(rawArgsForStrRepr: .init(args)), args)
        .filter("--focused conflicts with other filtering options") { raw in
            raw.filteringOptions.focused.implies(
                raw.filteringOptions.workspaces.isEmpty && raw.filteringOptions.monitors.isEmpty
            )
        }
}

private func parseMonitorIdsForPrintTree(input: SubArgParserInput) -> ParsedCliArgs<[MonitorId]> {
    let args = input.nonFlagArgs()
    let possibleValues = "<monitor> possible values: (<monitor-id>|focused|mouse|all)"
    if args.isEmpty {
        return .fail("<monitor>... is mandatory. \(possibleValues)", advanceBy: args.count)
    }
    var monitors: [MonitorId] = []
    var i = 0
    for monitor in args {
        switch Int.init(monitor) {
            case .some(let unwrapped):
                monitors.append(.index(unwrapped - 1))
            case _ where monitor == "mouse":
                monitors.append(.mouse)
            case _ where monitor == "all":
                monitors.append(.all)
            case _ where monitor == "focused":
                monitors.append(.focused)
            default:
                return .fail("Can't parse monitor ID '\(monitor)'. \(possibleValues)", advanceBy: i + 1)
        }
        i += 1
    }
    return .succ(monitors, advanceBy: monitors.count)
}

private func parseWorkspacesForPrintTree(input: SubArgParserInput) -> ParsedCliArgs<[WorkspaceFilter]> {
    let args = input.nonFlagArgs()
    let possibleValues = "\(workspace) possible values: (<workspace-name>|focused|visible)"
    if args.isEmpty {
        return .fail("\(workspaces) is mandatory. \(possibleValues)", advanceBy: args.count)
    }
    var workspaces: [WorkspaceFilter] = []
    var i = 0
    for workspaceRaw in args {
        switch workspaceRaw {
            case "visible": workspaces.append(.visible)
            case "focused": workspaces.append(.focused)
            default:
                switch WorkspaceName.parse(workspaceRaw) {
                    case .success(let unwrapped): workspaces.append(.name(unwrapped))
                    case .failure(let msg): return .fail(msg, advanceBy: i + 1)
                }
        }
        i += 1
    }
    return .succ(workspaces, advanceBy: workspaces.count)
}

