public struct NavCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .nav,
        allowInConfig: true,
        help: nav_help_generated,
        flags: [
            "--window-id": windowIdSubArgParser(),
            "--carry": trueBoolFlag(\.carry),
        ],
        posArgs: [newMandatoryPosArgParser(\.direction, parseCardinalDirectionArg, placeholder: CardinalDirection.unionLiteral)],
    )

    public var direction: Lateinit<CardinalDirection> = .uninitialized
    public var carry: Bool = false

    public init(rawArgs: [String], _ direction: CardinalDirection) {
        self.commonState = .init(rawArgs.slice)
        self.direction = .initialized(direction)
    }
}
