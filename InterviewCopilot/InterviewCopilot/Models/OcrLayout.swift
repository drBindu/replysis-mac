import Foundation

/// One word the text reader found on the screen: its text and where it sits, in pixels from the top left.
nonisolated struct OcrWord {
    let text: String
    let x: Double
    let y: Double
    let w: Double
    let h: Double
}

/// Turns the words a text reader found on a screen into text a person (or a model) can read: rows top
/// to bottom, side by side panels one after the other instead of mixed along each row, and indentation
/// kept. Ported from the Windows ScreenOcrLayout.
///
/// A problem on the left and an editor on the right share every row, so read straight across they
/// interleave: half a sentence of the statement, then half a line of code, then the rest of the sentence.
/// Here the page is cut at its empty vertical gutters first, and each panel is read down on its own.
nonisolated enum OcrLayout {
    static func toText(_ words: [OcrWord]) -> String {
        let ws = words.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty && $0.w > 0 && $0.h > 0 }
        guard !ws.isEmpty else { return "" }

        let charW = median(ws.filter { $0.text.count >= 3 }.map { $0.w / Double($0.text.count) }, fallback: 8)
        let lineH = median(ws.map { $0.h }, fallback: 8)

        var parts: [String] = []
        for pane in splitIntoPanes(ws, charW: charW, lineH: lineH) {
            let text = paneText(pane, charW: charW, lineH: lineH)
            if !text.isEmpty { parts.append(text) }
        }
        return parts.joined(separator: "\n\n")
    }

    /// Columns of the page with an empty vertical gutter between them, left to right.
    private static func splitIntoPanes(_ ws: [OcrWord], charW: Double, lineH: Double) -> [[OcrWord]] {
        let minX = ws.map { $0.x }.min() ?? 0
        let maxX = ws.map { $0.x + $0.w }.max() ?? 0
        let bin = 4.0
        let bins = Int(((maxX - minX) / bin).rounded(.up)) + 1
        let rows = clusterRows(ws, lineH: lineH)
        if rows.count < 6 { return [ws] }

        // How many rows have a word over each 4 px column of the page.
        var cover = [Int](repeating: 0, count: bins)
        for row in rows {
            var hit = [Bool](repeating: false, count: bins)
            for w in row {
                let a = Int((w.x - minX) / bin), b = Int((w.x + w.w - minX) / bin)
                if a <= b { for i in max(0, a)...min(bins - 1, b) { hit[i] = true } }
            }
            for i in 0..<bins where hit[i] { cover[i] += 1 }
        }

        // A gutter is a run of columns that almost no row touches (a title bar's words may cross it),
        // wide enough to be a gap between panels rather than the space between two words, and with text
        // on both sides of it.
        let emptyMax = max(1, Int(Double(rows.count) * 0.04))
        let gutterMin = max(28.0, 3 * charW)
        var cuts: [Double] = []
        var runStart = -1
        for i in 0...bins {
            let empty = i < bins && cover[i] <= emptyMax
            if empty && runStart < 0 { runStart = i }
            if !empty && runStart >= 0 {
                let runEnd = i - 1
                let inside = runStart > 0 && runEnd < bins - 1
                if inside && Double(runEnd - runStart + 1) * bin >= gutterMin {
                    cuts.append(minX + Double(runStart + runEnd + 1) / 2.0 * bin)
                }
                runStart = -1
            }
        }
        if cuts.isEmpty { return [ws] }

        var panes = [[OcrWord]](repeating: [], count: cuts.count + 1)
        for w in ws {
            let cx = w.x + w.w / 2
            var idx = 0
            while idx < cuts.count && cx > cuts[idx] { idx += 1 }
            panes[idx].append(w)
        }
        return panes.filter { !$0.isEmpty }
    }

    private static func clusterRows(_ ws: [OcrWord], lineH: Double) -> [[OcrWord]] {
        let sorted = ws.sorted { ($0.y + $0.h / 2) < ($1.y + $1.h / 2) }
        var rows: [[OcrWord]] = []
        var rowCenter = Double.nan
        for w in sorted {
            let c = w.y + w.h / 2
            if rows.isEmpty || abs(c - rowCenter) > lineH * 0.55 {
                rows.append([])
                rowCenter = c
            }
            rows[rows.count - 1].append(w)
            let last = rows[rows.count - 1]
            rowCenter = last.map { $0.y + $0.h / 2 }.reduce(0, +) / Double(last.count)
        }
        return rows
    }

    private static func paneText(_ pane: [OcrWord], charW: Double, lineH: Double) -> String {
        let rows = clusterRows(pane, lineH: lineH)

        // The panel's left edge is where most of its rows start, not its leftmost word: a heading that
        // begins further left would otherwise push every other line of the panel to the right.
        let starts = rows.map { r in r.map { $0.x }.min() ?? 0 }
        let common = max(2.0, Double(rows.count) * 0.15)
        var groups: [Int: [Double]] = [:]
        for s in starts { groups[Int((s / charW).rounded()), default: []].append(s) }
        let frequent = groups.values.filter { Double($0.count) >= common }.map { $0.reduce(0, +) / Double($0.count) }
        let left = frequent.min() ?? (starts.min() ?? 0)

        var out = ""
        for row in rows {
            let line = row.sorted { $0.x < $1.x }
            let indent = Int(((line[0].x - left) / charW).rounded())
            out += String(repeating: " ", count: min(max(indent, 0), 40))
            var prevEnd = line[0].x
            for (i, word) in line.enumerated() {
                if i > 0 {
                    let gap = Int(((word.x - prevEnd) / charW).rounded())
                    out += String(repeating: " ", count: min(max(gap, 1), 12))
                }
                out += word.text
                prevEnd = word.x + word.w
            }
            out += "\n"
        }
        // Trailing whitespace only: the first line's indentation is part of the layout.
        while let last = out.last, last.isWhitespace { out.removeLast() }
        return out
    }

    private static func median(_ values: [Double], fallback: Double) -> Double {
        let a = values.sorted()
        guard !a.isEmpty else { return fallback }
        return a.count % 2 == 1 ? a[a.count / 2] : (a[a.count / 2 - 1] + a[a.count / 2]) / 2
    }

    /// What the server accepts in one text. Longer is cut at a line.
    static let maxChars = 24_000
    /// Fewer letters than this is a picture or a blank page, not something to answer from.
    static let minUsefulChars = 40

    /// Cut at a line end, so a very long page never ends in half a word.
    static func fit(_ text: String) -> String {
        guard text.count > maxChars else { return text }
        let head = String(text.prefix(maxChars))
        if let cut = head.lastIndex(of: "\n"), head.distance(from: head.startIndex, to: cut) > maxChars / 2 {
            return String(head[..<cut])
        }
        return head
    }
}
