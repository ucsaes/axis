import Common

/// Parses the `[border]` table.
///
/// ```toml
/// [border]
/// enabled = true
/// width = 12
/// corner-radius = 12
/// blacklist = ['com.raycast.macos', 'com.kakao.KakaoTalkMac']
///
/// [border.colors]
/// default = '#ececee'
/// 1 = ['#e86c64', '#ce4a42']   # top-left -> bottom-right gradient
/// 2 = '#eca644'                # solid color
/// ```
func parseBorder(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ errors: inout [ConfigParseDiagnostic]) -> BorderConfig {
    parseTable(raw, .default, borderParser, backtrace, &errors)
}

private let colorsKey = "colors"

private let borderParser: [String: any ParserProtocol<BorderConfig>] = [
    "enabled": Parser(\.enabled, parseBool),
    "width": Parser(\.width, parseInt),
    "corner-radius": Parser(\.cornerRadius, parseInt),
    "blacklist": Parser(\.blacklist, parseArrayOfStrings),
    colorsKey: Parser(\.colorsHolder, parseBorderColors),
]

/// `colors` populates two fields (defaultColor + workspaceColors), so it parses into a holder
/// that BorderConfig projects through a single key path
struct BorderColorsHolder: Equatable, Sendable {
    var defaultColor: BorderColor?
    var workspaceColors: [String: BorderColor] = [:]
}

extension BorderConfig {
    var colorsHolder: BorderColorsHolder {
        get { BorderColorsHolder(defaultColor: defaultColor, workspaceColors: workspaceColors) }
        set {
            defaultColor = newValue.defaultColor ?? defaultColor
            workspaceColors = newValue.workspaceColors
        }
    }
}

private func parseBorderColors(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ errors: inout [ConfigParseDiagnostic]) -> BorderColorsHolder {
    guard let table = raw.asDictOrNil else {
        errors += [expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace)]
        return BorderColorsHolder()
    }
    var holder = BorderColorsHolder()
    for (key, rawColor) in table {
        guard let color = parseBorderColor(rawColor, backtrace + .key(key), &errors) else { continue }
        if key == "default" {
            holder.defaultColor = color
        } else {
            holder.workspaceColors[key] = color
        }
    }
    return holder
}

private func parseBorderColor(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ errors: inout [ConfigParseDiagnostic]) -> BorderColor? {
    if let array = raw.asArrayOrNil {
        guard (1 ... 8).contains(array.count) else {
            errors += [.init(backtrace, "A gradient must have 1 to 8 colors (corners and edge midpoints around the ring)")]
            return nil
        }
        let stops = array.enumerated().compactMap { parseHexColor($1, backtrace + .index($0), &errors) }
        guard stops.count == array.count else { return nil }
        return BorderColor(stops: stops)
    }
    guard let solid = parseHexColor(raw, backtrace, &errors) else { return nil }
    return BorderColor(stops: [solid])
}

/// Parses `#rrggbb`, `#aarrggbb`, or `0x...` into 0xAARRGGBB (alpha defaults to fully opaque).
private func parseHexColor(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ errors: inout [ConfigParseDiagnostic]) -> UInt32? {
    guard let string = raw.asStringOrNil else {
        errors += [expectedActualTypeDiagnostic(expected: .string, actual: raw.tomlType, backtrace)]
        return nil
    }
    var hex = string.trim()
    if hex.hasPrefix("#") { hex.removeFirst() }
    else if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex.removeFirst(2) }

    guard let value = UInt32(hex, radix: 16) else {
        errors += [.init(backtrace, "Can't parse color '\(string)'. Expected #rrggbb, #aarrggbb, or 0xaarrggbb")]
        return nil
    }
    return switch hex.count {
        case 6: 0xFF00_0000 | value // rrggbb -> opaque
        case 8: value // aarrggbb
        default:
            { errors += [.init(backtrace, "Color '\(string)' must have 6 (rrggbb) or 8 (aarrggbb) hex digits")]; return nil }()
    }
}
