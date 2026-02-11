public struct SaveStateCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = cmdParser(
        kind: .saveState,
        allowInConfig: true,
        help: save_state_help_generated,
        flags: [:],
        posArgs: [ArgParser(\.filePath, parseOptionalFilePath)],
    )

    public var filePath: String? = nil
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
