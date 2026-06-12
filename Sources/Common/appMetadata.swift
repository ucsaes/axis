public let stableAxisAppId: String = "ucsaes.axis"
#if DEBUG
    public let axisAppId: String = "ucsaes.axis.debug"
    public let axisAppName: String = "Axis-Debug"
#else
    public let axisAppId: String = stableAxisAppId
    public let axisAppName: String = "Axis"
#endif
