import Foundation

/// A markdown pipe table in an agent's message:
///
///     | Theme | Accent |
///     |---|---|
///     | Merry | cream |
///
/// UIKit-free: exercised by `ios/scripts/test-chat-grouping.swift`.
struct MarkdownTable: Equatable, Sendable {
    let header: [String]
    let rows: [[String]]

    var columnCount: Int { header.count }

    /// `|---|:--:|` under the header: every cell dashes with optional colons.
    static func isDelimiter(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.contains(":") else { return false }
        let parts = cells(t)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard c.contains("-") else { return false }
            return c.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    /// The table that starts at `lines[start]` (header, delimiter, rows) and
    /// how many lines it takes; nil when those lines are not a table.
    static func parse(_ lines: [String], from start: Int) -> (table: MarkdownTable, count: Int)? {
        guard start + 1 < lines.count, lines[start].contains("|"), isDelimiter(lines[start + 1]) else { return nil }
        let header = cells(lines[start])
        guard header.count >= 2, cells(lines[start + 1]).count == header.count else { return nil }
        var rows: [[String]] = []
        var i = start + 2
        while i < lines.count {
            let line = lines[i]
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty, line.contains("|") else { break }
            var row = cells(line)
            // Short rows are padded and long ones folded into the last cell,
            // so every row has the header's columns.
            if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
            if row.count > header.count {
                row = Array(row[..<(header.count - 1)]) + [row[(header.count - 1)...].joined(separator: " | ")]
            }
            rows.append(row)
            i += 1
        }
        return (MarkdownTable(header: header, rows: rows), i - start)
    }

    /// A row's cells: split on pipes that are not escaped or inside
    /// backticks, without the outer pipes, trimmed.
    static func cells(_ line: String) -> [String] {
        var t = Substring(line.trimmingCharacters(in: .whitespaces))
        if t.hasPrefix("|") { t = t.dropFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t = t.dropLast() }
        var out: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for ch in t {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "`" { inCode.toggle(); current.append(ch); continue }
            if ch == "|" && !inCode {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(ch)
        }
        out.append(current.trimmingCharacters(in: .whitespaces))
        return out
    }
}
