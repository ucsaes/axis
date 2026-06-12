import Common

/// Parses the `[strips]` table.
///
/// ```toml
/// [strips]
/// 1 = ['1', '2', '3', '4', '5']                     # Single strip shorthand
/// 2 = [['1', '2', '3', '4', '5'], ['6', '7', '8']]  # One strip per monitor
/// ```
///
/// The key is the number of connected monitors. The value must define exactly that many strips,
/// ordered along the monitor arrangement axis (top to bottom, or left to right).
func parseStrips(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ errors: inout [ConfigParseDiagnostic]) -> [Int: [[String]]] {
    guard let rawTable = raw.asDictOrNil else {
        errors += [expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace)]
        return [:]
    }
    var result: [Int: [[String]]] = [:]
    for (key, rawStrips) in rawTable {
        let backtrace = backtrace + .key(key)
        guard let monitorCount = Int(key), monitorCount >= 1 else {
            errors += [.init(backtrace, "The key must be a positive number of monitors. But got: '\(key)'")]
            continue
        }
        guard let strips = parseStripsForMonitorCount(rawStrips, backtrace, &errors) else { continue }
        // A single monitor hosts the whole strip stack. Multiple monitors pin strips 1:1
        if monitorCount > 1 && strips.count != monitorCount {
            errors += [.init(backtrace, "strips.\(key) must define exactly \(monitorCount) strip(s) (one per monitor). But it defines \(strips.count)")]
            continue
        }
        result[monitorCount] = strips
    }
    return result
}

private func parseStripsForMonitorCount(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ errors: inout [ConfigParseDiagnostic]) -> [[String]]? {
    guard let rawArray = raw.asArrayOrNil else {
        errors += [expectedActualTypeDiagnostic(expected: .array, actual: raw.tomlType, backtrace)]
        return nil
    }
    // Single strip shorthand: 1 = ['1', '2', '3']
    if rawArray.allSatisfy({ $0.asStringOrNil != nil || $0.asIntOrNil != nil }) && !rawArray.isEmpty {
        return parseSingleStrip(.array(rawArray), backtrace, &errors).map { [$0] }
    }
    var seenWorkspaces: Set<String> = []
    var strips: [[String]] = []
    for (index, rawStrip) in rawArray.enumerated() {
        let backtrace = backtrace + .index(index)
        guard let strip = parseSingleStrip(rawStrip, backtrace, &errors) else { return nil }
        for name in strip where !seenWorkspaces.insert(name).inserted {
            errors += [.init(backtrace, "Workspace '\(name)' appears in multiple strips")]
            return nil
        }
        strips.append(strip)
    }
    return strips
}

private func parseSingleStrip(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ errors: inout [ConfigParseDiagnostic]) -> [String]? {
    guard let rawArray = raw.asArrayOrNil else {
        errors += [expectedActualTypeDiagnostic(expected: .array, actual: raw.tomlType, backtrace)]
        return nil
    }
    if rawArray.isEmpty {
        errors += [.init(backtrace, "A strip must contain at least one workspace")]
        return nil
    }
    var strip: [String] = []
    for (index, rawName) in rawArray.enumerated() {
        let backtrace = backtrace + .index(index)
        let rawString: String
        if let string = rawName.asStringOrNil {
            rawString = string
        } else if let int = rawName.asIntOrNil { // Allow bare numbers: [1, 2, 3]
            rawString = String(int)
        } else {
            errors += [expectedActualTypeDiagnostic(expected: [.string, .int], actual: rawName.tomlType, backtrace)]
            return nil
        }
        guard let name = WorkspaceName.parse(rawString).toParsedConfig(backtrace).getOrNil(appendErrorTo: &errors) else { return nil }
        if strip.contains(name.raw) {
            errors += [.init(backtrace, "Workspace '\(name.raw)' appears in the strip more than once")]
            return nil
        }
        strip.append(name.raw)
    }
    return strip
}
