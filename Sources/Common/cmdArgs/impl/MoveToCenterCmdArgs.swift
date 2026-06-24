public struct MoveToCenterCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .moveToCenter,
        allowInConfig: true,
        help: move_to_center_help_generated,
        flags: [
            "--window-id": windowIdSubArgParser(),
        ],
        posArgs: [],
    )
}
