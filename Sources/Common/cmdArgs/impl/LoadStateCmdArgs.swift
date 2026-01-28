public struct LoadStateCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = cmdParser(
        kind: .loadState,
        allowInConfig: true,
        help: load_state_help_generated,
        flags: [
            "--verbose": trueBoolFlag(\.verbose),
        ],
        posArgs: [ArgParser(\.filePath, parseOptionalLoadFilePath)],
    )

    public var filePath: String? = nil
    public var verbose: Bool = false
}

private func parseOptionalLoadFilePath(i: ArgParserInput) -> ParsedCliArgs<String?> {
    .succ(i.arg, advanceBy: 1)
}

public let load_state_help_generated: String = """
    USAGE: load-state [<file-path>] [--verbose]

    OPTIONS:
      -h, --help   Print help
      --verbose    Log each window with its match status (matched/unmatched)

    ARGUMENTS:
      <file-path>  Path to the file from which state will be loaded (JSON format).
                   If not provided, uses 'state-file' from config.
    """
