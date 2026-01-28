public struct SaveStateCmdArgs: CmdArgs {
    public let rawArgsForStrRepr: EquatableNoop<StrArrSlice>
    public init(rawArgs: StrArrSlice) { self.rawArgsForStrRepr = .init(rawArgs) }
    public static let parser: CmdParser<Self> = cmdParser(
        kind: .saveState,
        allowInConfig: true,
        help: save_state_help_generated,
        flags: [:],
        posArgs: [ArgParser(\.filePath, parseOptionalFilePath)],
    )

    public var filePath: String? = nil
    /*conforms*/ public var windowId: UInt32?
    /*conforms*/ public var workspaceName: WorkspaceName?
}

private func parseOptionalFilePath(i: ArgParserInput) -> ParsedCliArgs<String?> {
    .succ(i.arg, advanceBy: 1)
}

public let save_state_help_generated: String = """
    USAGE: save-state [<file-path>]

    OPTIONS:
      -h, --help   Print help

    ARGUMENTS:
      <file-path>  Path to the file where state will be saved (JSON format).
                   If not provided, uses 'state-file' from config.
    """
