import Foundation
import PDFKit

struct ResumeParser {
    static let noResumeMarker = "[NO RESUME]"

    // MARK: - File reading (PDF / DOCX / TXT → plain text)

    /// Extracts readable text from a resume file based on its type.
    /// .docx is a ZIP (text lives in word/document.xml), PDF needs PDFKit — reading
    /// either as a raw String gives binary garbage, which is the bug this fixes.
    static func readResumeFile(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf":  return readPDF(url)
        case "docx": return readDOCX(url)
        default:
            if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
            if let s = try? String(contentsOf: url, encoding: .isoLatin1) { return s }
            return ""
        }
    }

    private static func readPDF(_ url: URL) -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        return (doc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func readDOCX(_ url: URL) -> String {
        // Stream word/document.xml out of the .docx ZIP via `unzip -p`, then strip XML.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-p", url.path, "word/document.xml"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let xml = String(data: data, encoding: .utf8) else { return "" }
        return stripWordXML(xml)
    }

    private static func stripWordXML(_ xml: String) -> String {
        var s = xml
        // Preserve structure: paragraph ends, line breaks, tabs → real whitespace
        s = s.replacingOccurrences(of: "</w:p>", with: "\n")
        s = s.replacingOccurrences(of: "<w:br/>", with: "\n")
        s = s.replacingOccurrences(of: "<w:br />", with: "\n")
        s = s.replacingOccurrences(of: "<w:tab/>", with: "  ")
        // Drop all remaining tags, keeping the text between them
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // Decode XML entities. ORDER MATTERS: &amp; must be decoded LAST, otherwise text
        // like "&amp;lt;" wrongly collapses to "<" instead of the literal "&lt;". A
        // Dictionary's iteration order is random (this was nondeterministic) — use an
        // ordered list with &amp; at the end.
        let entities: [(String, String)] = [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")
        ]
        for (e, c) in entities { s = s.replacingOccurrences(of: e, with: c) }
        // Collapse runaway blank lines
        while s.contains("\n\n\n") { s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractFacts(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return noResumeMarker }
        return trimmed
    }

    static func extractName(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines.prefix(5) {
            let words = line.split(separator: " ")
            if words.count >= 2 && words.count <= 5 {
                let allCapOrTitle = words.allSatisfy { w in
                    let s = String(w)
                    return s.first?.isUppercase == true &&
                           !s.contains("@") && !s.contains(".") && s.count > 1
                }
                if allCapOrTitle { return line }
            }
        }
        return lines.first ?? "Candidate"
    }
}
