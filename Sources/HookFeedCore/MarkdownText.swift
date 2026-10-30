import Foundation

/// A display-only reading of agent Markdown. Stored messages keep their raw text.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    /// Raw inline Markdown with line breaks preserved.
    case paragraph(String)
    /// Verbatim lines: fenced code without its fences, or consecutive table rows.
    case code(String)
}

public enum MarkdownText {
    /// Removes `**`, `__`, backticks, and link targets. Single `*` and `_` are left alone.
    public static func plainInline(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        for marker in ["**", "__", "`"] { result = result.replacingOccurrences(of: marker, with: "") }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first nonempty line without heading, quote, or inline markers; never empty for a nonempty title.
    public static func plainTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for line in trimmed.split(whereSeparator: \.isNewline) {
            let plain = plainInline(String(line).replacingOccurrences(of: #"^\s*(#{1,6}\s+|>\s?)"#, with: "", options: .regularExpression))
            if !plain.isEmpty, !plain.allSatisfy({ "*_`#>~-| ".contains($0) }) { return plain }
        }
        return trimmed
    }

    /// Splits a body into blocks, dropping a leading block that only repeats `title`.
    public static func blocks(_ body: String, omittingTitle title: String? = nil) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var paragraph: [String] = []
        var table: [String] = []
        var fence: [String]?
        var fenceMarker: Character = "`"
        var fenceLength = 0

        func flushParagraph() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        func flushTable() {
            if !table.isEmpty { result.append(.code(table.joined(separator: "\n"))) }
            table = []
        }

        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if fence != nil {
                let markerCount = trimmed.prefix { $0 == fenceMarker }.count
                if markerCount >= fenceLength, trimmed.dropFirst(markerCount).allSatisfy(\.isWhitespace) {
                    result.append(.code(fence!.joined(separator: "\n")))
                    fence = nil
                } else {
                    fence!.append(line)
                }
                continue
            }
            let marker = trimmed.first ?? " "
            let markerCount = trimmed.prefix { $0 == marker }.count
            if (marker == "`" || marker == "~"), markerCount >= 3 {
                flushParagraph(); flushTable()
                fenceMarker = marker
                fenceLength = markerCount
                fence = []
            } else if !table.isEmpty, isTableSeparator(trimmed) {
                continue
            } else if trimmed != "|", trimmed.contains("|"),
                      trimmed.hasPrefix("|") || !table.isEmpty || (index + 1 < lines.count && isTableSeparator(lines[index + 1])) {
                flushParagraph()
                table.append(trimmed)            } else {
                flushTable()
                if trimmed.isEmpty {
                    flushParagraph()
                } else if let heading = heading(trimmed) {
                    flushParagraph()
                    result.append(heading)
                } else {
                    paragraph.append(line)
                }
            }
        }
        if let fence { result.append(.code(fence.joined(separator: "\n"))) }
        flushParagraph(); flushTable()

        if let title, let first = result.first, plainText(first) == plainTitle(title) { result.removeFirst() }
        return result
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).range(of: #"^\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?$"#, options: .regularExpression) != nil
    }

    /// Links in agent text may only open web pages, matching the Open source action.
    public static func allowsLink(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    /// `#` through `######` followed by whitespace and text.
    private static func heading(_ line: String) -> MarkdownBlock? {
        let level = line.prefix { $0 == "#" }.count
        let rest = line.dropFirst(level)
        guard (1...6).contains(level), rest.first?.isWhitespace == true else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : .heading(level: level, text: text)
    }

    private static func plainText(_ block: MarkdownBlock) -> String? {
        switch block {
        case .heading(_, let text), .paragraph(let text): return plainInline(text)
        case .code: return nil
        }
    }
}

public extension Message {
    /// Display blocks for the body. `run` bodies are shell-quoted text, so they stay verbatim.
    var bodyBlocks: [MarkdownBlock] {
        guard let body, !body.isEmpty else { return [] }
        return source == "run" ? [.code(body)] : MarkdownText.blocks(body, omittingTitle: title)
    }
}
