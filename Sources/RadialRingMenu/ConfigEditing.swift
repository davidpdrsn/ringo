import Foundation

/// A change to one setting in the config file.
struct ConfigEdit: Equatable {
    /// The table the setting is in, like `outer_ring.highlight`, or `nil` for one
    /// outside any table.
    var table: String?
    var key: String
    /// The TOML to write as its value, or `nil` to remove it.
    var value: String?
}

extension ConfigEdit {
    /// Applies `edits` to the config `text`: changes settings where they are,
    /// adds missing ones (and their tables), and keeps everything else, comments
    /// included.
    static func apply(_ edits: [ConfigEdit], to text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        for edit in edits {
            apply(edit, to: &lines)
        }
        return lines.joined(separator: "\n")
    }

    private static func apply(_ edit: ConfigEdit, to lines: inout [String]) {
        let tables = tableOfEachLine(lines)
        if let index = lines.indices.first(where: { tables[$0] == edit.table && settingKey(lines[$0]) == edit.key }) {
            if let value = edit.value {
                lines[index] = replacingValue(in: lines[index], with: value)
            } else {
                lines.remove(at: index)
            }
            return
        }
        guard let value = edit.value else { return }
        let setting = "\(edit.key) = \(value)"

        let section: Range<Int>?
        if let table = edit.table {
            section = lines.indices.first { headerName(lines[$0]) == table }.map { header in
                header + 1 ..< (lines[(header + 1)...].firstIndex { headerName($0) != nil } ?? lines.count)
            }
        } else {
            section = 0 ..< (lines.firstIndex { headerName($0) != nil } ?? lines.count)
        }
        if let section {
            // After the last setting in the table, or at its start.
            let index = section.last { settingKey(lines[$0]) != nil }.map { $0 + 1 } ?? section.lowerBound
            lines.insert(setting, at: index)
            return
        }

        // A new table goes before the apps and the comments right above them.
        var index = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[[") } ?? lines.count
        while index > 0 && lines[index - 1].trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            index -= 1
        }
        var block = ["[\(edit.table!)]", setting, ""]
        if index > 0 && !lines[index - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            block.insert("", at: 0)
        }
        lines.insert(contentsOf: block, at: index)
    }

    /// The table each line is in, `nil` outside any table.
    private static func tableOfEachLine(_ lines: [String]) -> [String?] {
        var table: String?
        return lines.map { line in
            if let name = headerName(line) {
                table = name
            }
            return table
        }
    }

    /// The name in a `[table]` line, `[[name]]` for an array of tables, or `nil`
    /// for any other line.
    private static func headerName(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let end = trimmed.firstIndex(of: "]") else { return nil }
        if trimmed.hasPrefix("[[") {
            return String(trimmed[...end]) + "]"
        }
        return trimmed[trimmed.index(after: trimmed.startIndex)..<end].trimmingCharacters(in: .whitespaces)
    }

    /// The key a `key = value` line sets, or `nil` for any other line.
    private static func settingKey(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix("["), let equals = trimmed.firstIndex(of: "=") else {
            return nil
        }
        let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }

    /// `line` with its value replaced, keeping the key, spacing and any comment
    /// after it.
    private static func replacingValue(in line: String, with value: String) -> String {
        guard let equals = line.firstIndex(of: "=") else { return line }
        var start = line.index(after: equals)
        while start < line.endIndex, line[start].isWhitespace {
            start = line.index(after: start)
        }
        var end: String.Index
        if start < line.endIndex, line[start] == "\"" {
            // A string, which can contain `#`, like a color.
            let afterQuote = line.index(after: start)
            end = line[afterQuote...].firstIndex(of: "\"").map { line.index(after: $0) } ?? line.endIndex
        } else {
            end = line[start...].firstIndex(of: "#") ?? line.endIndex
            while end > start, line[line.index(before: end)].isWhitespace {
                end = line.index(before: end)
            }
        }
        return line.replacingCharacters(in: start..<end, with: value)
    }
}

extension Config {
    /// Every style setting, as the edit that would write it. Optional ones that
    /// aren't set have no value.
    var styleSettings: [ConfigEdit] {
        func number(_ value: Double) -> String { String(format: "%g", value) }
        func color(_ value: RGBAColor?) -> String? { value.map { "\"\($0.hex)\"" } }
        func highlight(_ style: RingHighlight, in table: String) -> [ConfigEdit] {
            [
                ConfigEdit(table: table, key: "shape", value: "\"\(style.shape.rawValue)\""),
                ConfigEdit(table: table, key: "width", value: style.width.map(number)),
                ConfigEdit(table: table, key: "fade", value: style.fade.map(number)),
                ConfigEdit(table: table, key: "overhang", value: number(style.overhang)),
                ConfigEdit(table: table, key: "color", value: color(style.color)),
                ConfigEdit(table: table, key: "glow_spread", value: number(style.glowSpread)),
                ConfigEdit(table: table, key: "glow_blur", value: number(style.glowBlur)),
                ConfigEdit(table: table, key: "glow_opacity", value: number(style.glowOpacity)),
            ]
        }
        return [
            ConfigEdit(table: nil, key: "open_animation_ms", value: number(openAnimationDuration * 1000)),
            ConfigEdit(table: "icons", key: "radius", value: number(radius)),
            ConfigEdit(table: "icons", key: "size", value: number(iconSize)),
            ConfigEdit(table: "icons", key: "selected_scale", value: number(selectedIconScale)),
            ConfigEdit(table: "icons", key: "unselected_opacity", value: number(unselectedIconOpacity)),
            ConfigEdit(table: "outer_ring", key: "inner_radius", value: number(outerRing.innerRadius)),
            ConfigEdit(table: "outer_ring", key: "outer_radius", value: number(outerRing.outerRadius)),
            ConfigEdit(table: "outer_ring", key: "color", value: color(outerRing.color)),
        ]
            + highlight(outerRing.highlight, in: "outer_ring.highlight")
            + [ConfigEdit(table: "inner_ring", key: "color", value: color(innerRing.color))]
            + highlight(innerRing.highlight, in: "inner_ring.highlight")
    }

    /// The config `text` with its style settings changed to those of `edited`.
    /// Only the settings that differ are touched.
    static func applyingStyle(of edited: Config, to text: String) throws(ConfigError) -> String {
        let wanted = edited.styleSettings
        var result = ConfigEdit.apply(changes(from: try parse(text).styleSettings, to: wanted), to: text)
        // Settings left out of the file can follow others, like the outer ring's
        // edges follow the icons, so write those out too if they moved.
        result = ConfigEdit.apply(changes(from: try parse(result).styleSettings, to: wanted), to: result)
        _ = try parse(result)
        return result
    }

    private static func changes(from current: [ConfigEdit], to wanted: [ConfigEdit]) -> [ConfigEdit] {
        zip(current, wanted).filter { $0 != $1 }.map(\.1)
    }
}
