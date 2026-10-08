import Foundation

/// The block structure of a short Markdown text (a ticket preamble, docs/07 §7.2.3), so a view can
/// show it rendered: headings, list items, and paragraphs. Inline Markdown (code, bold, links)
/// stays in each block's text for the view's inline renderer. Anything richer reads as a paragraph.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    /// `marker` is `1.` for a numbered item, `•` for a bulleted one.
    case listItem(marker: String, text: String)
    case paragraph(String)

    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        func endParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                endParagraph()
            } else if let heading = heading(line) {
                endParagraph()
                blocks.append(heading)
            } else if let item = listItem(line) {
                endParagraph()
                blocks.append(item)
            } else if case let .listItem(marker, text)? = blocks.last, paragraph.isEmpty, raw.hasPrefix(" ") {
                // An indented line continues the list item above it.
                blocks[blocks.count - 1] = .listItem(marker: marker, text: text + " " + line)
            } else {
                paragraph.append(line)
            }
        }
        endParagraph()
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1 ... 6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> MarkdownBlock? {
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
            return .listItem(marker: "•", text: String(line.dropFirst(2)))
        }
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return .listItem(marker: digits + ".", text: String(rest.dropFirst(2)))
    }
}
