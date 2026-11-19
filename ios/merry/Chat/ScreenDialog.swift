import Foundation

/// A dialog open in an agent's TUI, read off the live screen: a picker a
/// slash command opened (`/model`, `/resume`, …), a permission prompt, the
/// folder-trust check. These write nothing to the transcript until the
/// human answers (contract "Slash commands and scheduled runs"), so the
/// screen is the only place to see them.
///
/// UIKit-free on purpose: exercised by `ios/scripts/test-screen-dialog.swift`
/// against real Claude Code screens captured in `ios/scripts/fixtures/screens/`.
struct ScreenDialog: Equatable, Sendable {
    struct Option: Equatable, Sendable {
        /// The number typed to pick it; nil in an unnumbered list.
        let number: Int?
        let label: String
        let detail: String?
        /// The row the TUI's cursor is on (what Enter would pick).
        let selected: Bool
    }

    let title: String?
    /// Empty when the dialog couldn't be read as a list: the phone shows the
    /// live-screen peek instead.
    let options: [Option]
    /// The dialog's rows, from its top border (or a few rows above its
    /// options) down to the hint line.
    let rawRows: [String]
    /// The footer hint ("Enter to confirm · Esc to cancel").
    let hint: String?
    /// A short terminal shows only a window of a long list ("↑ 2 more",
    /// "↓ 3 more"): how many choices are out of view, not counting ones
    /// remembered from earlier frames (see `merging`).
    var hiddenAbove = 0
    var hiddenBelow = 0
    /// Arrow presses that scroll the TUI's window one row past its top or
    /// bottom edge from where its cursor is now.
    var scrollUpPresses = 1
    var scrollDownPresses = 1

    var isNumbered: Bool { options.first?.number != nil }
    var selectedIndex: Int? { options.firstIndex(where: \.selected) }

    /// The keys that pick `options[index]`: its number in a numbered list,
    /// otherwise arrows from the cursor row and Enter.
    func keys(toChoose index: Int) -> [String] {
        guard options.indices.contains(index) else { return [] }
        if let n = options[index].number { return [String(n)] }
        let from = selectedIndex ?? 0
        let step = index > from ? "Down" : "Up"
        return Array(repeating: step, count: abs(index - from)) + ["enter"]
    }

    /// This frame's dialog plus the numbered choices an earlier frame of the
    /// same dialog showed. A windowed list fills in as it scrolls, and a
    /// remembered choice is still picked by its number.
    func merging(_ previous: ScreenDialog?) -> ScreenDialog {
        guard let previous, previous.title == title, isNumbered, previous.isNumbered,
              let first = options.first?.number, let last = options.last?.number else { return self }
        let total = last + hiddenBelow
        var byNumber: [Int: Option] = [:]
        for o in previous.options {
            guard let n = o.number, n <= total else { continue }
            byNumber[n] = Option(number: n, label: o.label, detail: o.detail, selected: false)
        }
        for o in options { if let n = o.number { byNumber[n] = o } }
        // Keep only the run of known numbers that touches this frame's rows.
        var lo = first, hi = last
        while byNumber[lo - 1] != nil { lo -= 1 }
        while byNumber[hi + 1] != nil { hi += 1 }
        var out = self
        out = ScreenDialog(title: title, options: (lo...hi).compactMap { byNumber[$0] }, rawRows: rawRows, hint: hint)
        out.hiddenAbove = lo - 1
        out.hiddenBelow = max(0, total - hi)
        out.scrollUpPresses = scrollUpPresses
        out.scrollDownPresses = scrollDownPresses
        return out
    }
}

enum ScreenDialogDetector {
    static let cursorGlyphs: Set<Character> = ["❯", ">", "›", "▸"]
    static let ruleGlyphs: Set<Character> = ["─", "━", "▔", "═", "▁"]
    /// The most choices shown as a list; a longer one scrolls in the TUI and
    /// is better answered on the real screen.
    static let maxOptions = 9

    /// The dialog on a screen, or nil when the screen shows the normal
    /// prompt, a working spinner, or anything without a dialog's footer.
    static func detect(rows input: [String]) -> ScreenDialog? {
        var rows = input.map { stripTrailing($0) }
        while let last = rows.last, last.isEmpty { rows.removeLast() }
        guard !rows.isEmpty else { return nil }

        // 1. The footer: a key hint among the last three rows with text.
        let tail = rows.indices.reversed().filter { !rows[$0].isEmpty }.prefix(3)
        // The idle prompt and the working spinner have hint lines of their
        // own; while they are on screen there is no dialog.
        if tail.contains(where: { isPromptFooter(rows[$0]) }) { return nil }
        guard let hintIndex = tail.first(where: { isDialogHint(rows[$0]) }) else {
            return detectClipped(rows)
        }
        let hint = rows[hintIndex].trimmingCharacters(in: .whitespaces)

        // 2. The dialog's top: the nearest full-width rule above the hint.
        let floor = max(0, hintIndex - 32)
        let ruleIndex = stride(from: hintIndex - 1, through: floor, by: -1).first { isRule(rows[$0]) }
        let body = Array(rows[((ruleIndex ?? floor - 1) + 1)..<hintIndex])

        // 3. The choices.
        let numbered = parseNumbered(body)
        let options = numbered?.options ?? parseCursorList(body) ?? []

        // 4. A title: the first line under the rule, else the first line of
        // the block of text just above the choices.
        var title: String? = nil
        if ruleIndex != nil { title = body.first(where: { !$0.isEmpty && !isRule($0) && !isOptionRow($0) }) }
        if title == nil, let first = body.firstIndex(where: isOptionRow) {
            var i = first - 1
            while i >= 0 && body[i].isEmpty { i -= 1 }
            var block: [String] = []
            while i >= 0 && !body[i].isEmpty && !isRule(body[i]) { block.insert(body[i], at: 0); i -= 1 }
            // The block's first line that reads as a title (a stray notice
            // painted over the dialog's border is not one).
            title = block.lazy.compactMap(cleanTitle).first
        }
        title = title.flatMap(cleanTitle)

        var raw = ruleIndex != nil ? body : Array(body.suffix(14))
        while let f = raw.first, f.isEmpty { raw.removeFirst() }
        var dialog = ScreenDialog(title: title, options: options, rawRows: raw + [rows[hintIndex]], hint: hint)
        if let numbered { numbered.apply(to: &dialog) }
        return dialog
    }

    /// A terminal too short for the whole dialog: its footer is pushed off
    /// the screen. Still a dialog when a rule sits above a windowed numbered
    /// list ("↑ 1 more") that has the cursor.
    private static func detectClipped(_ rows: [String]) -> ScreenDialog? {
        let floor = max(0, rows.count - 32)
        guard let ruleIndex = stride(from: rows.count - 1, through: floor, by: -1).first(where: { isRule(rows[$0]) }) else { return nil }
        let body = Array(rows[(ruleIndex + 1)...])
        guard let numbered = parseNumbered(body), numbered.above + numbered.below > 0,
              numbered.options.contains(where: \.selected) else { return nil }
        let title = body.first(where: { !$0.isEmpty && !isOptionRow($0) }).flatMap(cleanTitle)
        var dialog = ScreenDialog(title: title, options: numbered.options, rawRows: body, hint: nil)
        numbered.apply(to: &dialog)
        return dialog
    }

    // MARK: - Footer

    /// "Enter to confirm", "Esc to cancel", "↑/↓ to navigate", "Tab to amend".
    /// Case matters: the working footer says "esc to interrupt".
    static func isDialogHint(_ row: String) -> Bool {
        let verbs = ["Enter to ", "Esc to ", "Tab to ", "Space to ", "to navigate", "to select", "to confirm"]
        guard verbs.contains(where: { row.contains($0) }) else { return false }
        return !row.contains("to interrupt")
    }

    /// The idle prompt's and the working spinner's footers.
    static func isPromptFooter(_ row: String) -> Bool {
        ["? for shortcuts", "shift+tab to cycle", "esc to interrupt", "for shortcuts"].contains { row.contains($0) }
    }

    static func isRule(_ row: String) -> Bool {
        let chars = row.filter { !$0.isWhitespace }
        guard chars.count >= 20 else { return false }
        return chars.allSatisfy { ruleGlyphs.contains($0) }
    }

    // MARK: - Choices

    /// `❯ 3.  Fable 5.2 ✔   For your toughest challenges` → (3, "Fable 5.2",
    /// "Current · For your toughest challenges", selected).
    private static func numberedRow(_ row: String) -> ScreenDialog.Option? {
        var s = Substring(row).drop(while: { $0 == " " })
        var selected = false
        if let c = s.first, cursorGlyphs.contains(c) {
            selected = true
            s = s.dropFirst().drop(while: { $0 == " " })
        }
        let digits = s.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 2, let n = Int(digits) else { return nil }
        s = s.dropFirst(digits.count)
        guard s.first == ".", s.dropFirst().first == " " else { return nil }
        let rest = s.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        let (label, detail) = splitLabel(rest)
        return .init(number: n, label: label, detail: detail, selected: selected)
    }

    struct Numbered {
        var options: [ScreenDialog.Option]
        var above = 0
        var below = 0
        /// Rows from the window's top to the cursor, and the cursor to its bottom.
        var cursorFromTop = 0
        var cursorFromBottom = 0

        func apply(to dialog: inout ScreenDialog) {
            dialog.hiddenAbove = above
            dialog.hiddenBelow = below
            dialog.scrollUpPresses = cursorFromTop + 1
            dialog.scrollDownPresses = cursorFromBottom + 1
        }
    }

    /// "    ↑ 2 more" / "    ↓ 3 more": the count and whether it is above.
    private static func moreMarker(_ row: String) -> (above: Bool, count: Int)? {
        let t = row.trimmingCharacters(in: .whitespaces)
        guard let arrow = t.first, arrow == "↑" || arrow == "↓" else { return nil }
        let parts = t.dropFirst().split(separator: " ")
        guard parts.count == 2, parts[1] == "more", let n = Int(parts[0]), n > 0 else { return nil }
        return (arrow == "↑", n)
    }

    /// Numbered rows in order with at most one cursor: 1, 2, 3… for a whole
    /// list (two or more), or any consecutive run when the terminal shows a
    /// window of it ("↑ 2 more"). A description wrapped onto the rows under
    /// its choice is joined back on.
    static func parseNumbered(_ body: [String]) -> Numbered? {
        var found: [ScreenDialog.Option] = []
        var above = 0, below = 0
        var cursorOnUnnumbered = false
        var seenList = false
        for row in body {
            if let m = moreMarker(row) {
                if m.above { above = m.count } else { below = m.count }
                continue
            }
            if let option = numberedRow(row) {
                found.append(option)
                seenList = true
                continue
            }
            guard seenList, !row.isEmpty else { if row.isEmpty && below > 0 { seenList = false }; continue }
            if cursorColumn(row) != nil { cursorOnUnnumbered = true; continue }
            // A wrapped description: deeply indented text under a choice that
            // has one, before the list ends.
            let indent = row.prefix(while: { $0 == " " }).count
            if below == 0, indent >= 12, let last = found.last, let detail = last.detail {
                let more = row.trimmingCharacters(in: .whitespaces)
                found[found.count - 1] = .init(number: last.number, label: last.label, detail: detail + " " + more, selected: last.selected)
            } else if indent < 12 {
                seenList = false
            }
        }
        let windowed = above + below > 0
        guard found.count >= (windowed ? 1 : 2), found.count <= maxOptions,
              let first = found.first?.number, windowed || first == 1,
              found.enumerated().allSatisfy({ $0.element.number == first + $0.offset }),
              found.filter(\.selected).count <= 1 else { return nil }
        if above > 0, first != above + 1 { return nil }
        var result = Numbered(options: found, above: above > 0 ? above : first - 1, below: below)
        if let at = found.firstIndex(where: \.selected) {
            result.cursorFromTop = at
            result.cursorFromBottom = found.count - 1 - at
        } else if cursorOnUnnumbered {
            result.cursorFromTop = found.count
        }
        return result
    }

    /// An unnumbered list: exactly one row with a cursor, and its neighbours
    /// that start in the same column as the cursor row's text. A list that
    /// scrolls ("↓ 21 more") or sits under a search box is not offered.
    static func parseCursorList(_ body: [String]) -> [ScreenDialog.Option]? {
        let cursorRows = body.indices.filter { cursorColumn(body[$0]) != nil }
        guard cursorRows.count == 1, let at = cursorRows.first, let col = cursorColumn(body[at]) else { return nil }
        if body.contains(where: { $0.contains("more") && ($0.contains("↓") || $0.contains("↑")) }) { return nil }
        if body.contains(where: { $0.contains("⌕") }) { return nil }
        func sibling(_ row: String) -> Bool {
            guard !row.isEmpty, cursorColumn(row) == nil else { return false }
            let chars = Array(row)
            guard chars.count > col, !chars[col].isWhitespace else { return false }
            return chars[..<col].allSatisfy { $0 == " " }
        }
        var start = at, end = at
        while start - 1 >= 0 && sibling(body[start - 1]) { start -= 1 }
        while end + 1 < body.count && sibling(body[end + 1]) { end += 1 }
        guard end > start, end - start + 1 <= maxOptions else { return nil }
        // A list in sections (more aligned rows after a blank line, as in
        // /mcp) is longer than what is in view here.
        var next = end + 1
        while next < body.count && body[next].isEmpty { next += 1 }
        if next > end + 1, next < body.count, sibling(body[next]) { return nil }
        var prev = start - 1
        while prev >= 0 && body[prev].isEmpty { prev -= 1 }
        if prev < start - 1, prev >= 0, sibling(body[prev]) { return nil }
        return (start...end).map { i in
            let text = String(Array(body[i])[col...]).trimmingCharacters(in: .whitespaces)
            let (label, detail) = splitLabel(text)
            return .init(number: nil, label: label, detail: detail, selected: i == at)
        }
    }

    /// The column where a cursor row's text starts (after "❯ "), or nil
    /// when the row has no leading cursor glyph.
    private static func cursorColumn(_ row: String) -> Int? {
        let chars = Array(row)
        var i = 0
        while i < chars.count && chars[i] == " " { i += 1 }
        guard i < chars.count, cursorGlyphs.contains(chars[i]) else { return nil }
        // "▸   More models" is a submenu row, not the cursor.
        guard chars[i] != "▸" else { return nil }
        i += 1
        guard i < chars.count, chars[i] == " " else { return nil }
        while i < chars.count && chars[i] == " " { i += 1 }
        return i < chars.count ? i : nil
    }

    private static func isOptionRow(_ row: String) -> Bool {
        numberedRow(row) != nil || cursorColumn(row) != nil
    }

    /// "Default (recommended)  Opus 5.5 · Best for…" splits at the first run
    /// of two or more spaces; a ✔ (the current choice) becomes "Current".
    static func splitLabel(_ text: String) -> (String, String?) {
        var label = text
        var detail: String? = nil
        if let r = text.range(of: "  ") {
            label = String(text[..<r.lowerBound])
            let d = text[r.upperBound...].trimmingCharacters(in: .whitespaces)
            detail = d.isEmpty ? nil : d
        }
        var current = false
        for mark in ["✔", "✓"] where label.contains(mark) {
            current = true
            label = label.replacingOccurrences(of: mark, with: "")
        }
        label = label.trimmingCharacters(in: .whitespaces)
        if current { detail = detail.map { "Current · " + $0 } ?? "Current" }
        return (label, detail)
    }

    /// A tab bar ("Settings  Status   Config") is not a title.
    private static func cleanTitle(_ row: String) -> String? {
        let t = row.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 80 else { return nil }
        if t.components(separatedBy: "  ").filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count >= 3 {
            return nil
        }
        return t.hasSuffix(":") ? String(t.dropLast()) : t
    }

    private static func stripTrailing(_ s: String) -> String {
        var s = s
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return s
    }
}
