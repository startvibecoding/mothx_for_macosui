import SwiftUI

/// Block-level Markdown renderer for read-only document previews (skill
/// reference documents, bundled `*.md` files, etc.).
///
/// Unlike `MarkdownMessageText`, which is tuned for chat transcripts, this view
/// lays headings, lists, block quotes, rules, tables and fenced code blocks out
/// as distinct blocks so a `.md` file reads like a formatted document instead of
/// a wall of text.
///
/// Parsing runs once per value change and the parsed blocks are cached in
/// `@State`; the view body only walks the result. Very large inputs fall back to
/// plain monospaced text so a pathological file cannot stall the UI.
struct MarkdownDocumentView: View {
    let markdown: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var blocks: [MarkdownDocumentBlock]

    /// Above this many characters we skip block parsing entirely and show the
    /// raw text, keeping one huge document from blocking the main thread.
    private static let maxParseCharacters = 300_000

    init(markdown: String) {
        self.markdown = markdown
        _blocks = State(initialValue: Self.parseIfAvailable(markdown))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if blocks.isEmpty {
                Text(markdown)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .onChange(of: markdown) { _, _ in
            blocks = Self.parseIfAvailable(markdown)
        }
    }

    private static func parseIfAvailable(_ text: String) -> [MarkdownDocumentBlock] {
        guard text.count <= maxParseCharacters else { return [] }
        return MarkdownDocumentParser.parse(text)
    }

    private var codeBackground: Color {
        colorScheme == .light ? Color.black.opacity(0.06) : Color.white.opacity(0.09)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownDocumentBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownDocumentParser.inline(text))
                .font(Self.headingFont(level))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level <= 2 ? 8 : 4)

        case .paragraph(let text):
            Text(MarkdownDocumentParser.inline(text))
                .font(.body)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.orange.opacity(0.55))
                    .frame(width: 3)
                Text(MarkdownDocumentParser.inline(text))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .listItem(let indent, let marker, let text):
            HStack(alignment: .top, spacing: 8) {
                Text(marker)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
                Text(MarkdownDocumentParser.inline(text))
                    .font(.body)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(indent) * 16)

        case .code(let language, let content):
            VStack(alignment: .leading, spacing: 6) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(content.isEmpty ? " " : content)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(codeBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

        case .rule:
            Divider()

        case .table(let headers, let rows):
            MarkdownDocumentTable(headers: headers, rows: rows)
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 22, weight: .bold)
        case 2: return .system(size: 19, weight: .semibold)
        case 3: return .system(size: 17, weight: .semibold)
        case 4: return .system(size: 15, weight: .semibold)
        default: return .system(size: 13, weight: .semibold)
        }
    }
}

// MARK: - Blocks

private enum MarkdownDocumentBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case quote(String)
    case listItem(indent: Int, marker: String, text: String)
    case code(language: String?, content: String)
    case rule
    case table(headers: [String], rows: [[String]])
}

// MARK: - Parser

private enum MarkdownDocumentParser {
    static func parse(_ text: String) -> [MarkdownDocumentBlock] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [MarkdownDocumentBlock] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { i += 1; continue }

            // Fenced code block.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var content: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        i += 1
                        break
                    }
                    content.append(lines[i])
                    i += 1
                }
                blocks.append(.code(language: language.isEmpty ? nil : language,
                                    content: content.joined(separator: "\n")))
                continue
            }

            // ATX heading.
            if let heading = headingMatch(trimmed) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                i += 1
                continue
            }

            // Horizontal rule.
            if isRule(trimmed) {
                blocks.append(.rule)
                i += 1
                continue
            }

            // Pipe table (header row + separator row).
            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                let headers = splitTableRow(trimmed)
                i += 2
                var rows: [[String]] = []
                while i < lines.count {
                    let rowLine = lines[i].trimmingCharacters(in: .whitespaces)
                    if rowLine.isEmpty || !rowLine.contains("|") { break }
                    rows.append(splitTableRow(rowLine))
                    i += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            // Block quote (consecutive `>` lines).
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let q = lines[i].trimmingCharacters(in: .whitespaces)
                    guard q.hasPrefix(">") else { break }
                    quoteLines.append(String(q.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            // List item.
            if let item = listMatch(line) {
                blocks.append(item)
                i += 1
                continue
            }

            // Paragraph: gather consecutive plain lines.
            var paragraph: [String] = []
            while i < lines.count {
                let current = lines[i]
                let currentTrimmed = current.trimmingCharacters(in: .whitespaces)
                if currentTrimmed.isEmpty
                    || currentTrimmed.hasPrefix("```")
                    || currentTrimmed.hasPrefix("~~~")
                    || currentTrimmed.hasPrefix(">")
                    || headingMatch(currentTrimmed) != nil
                    || isRule(currentTrimmed)
                    || listMatch(current) != nil {
                    break
                }
                if currentTrimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                    break
                }
                paragraph.append(currentTrimmed)
                i += 1
            }
            if paragraph.isEmpty {
                i += 1
            } else {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            }
        }

        return blocks
    }

    /// Inline-only parse keeps `**bold**`, `code`, links, etc. while leaving the
    /// surrounding whitespace (and soft line breaks) untouched.
    static func inline(_ text: String) -> AttributedString {
        if let parsed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return parsed
        }
        return AttributedString(text)
    }

    // MARK: Helpers

    private static func headingMatch(_ trimmed: String) -> (level: Int, text: String)? {
        guard trimmed.hasPrefix("#") else { return nil }
        var level = 0
        var index = trimmed.startIndex
        while index < trimmed.endIndex, trimmed[index] == "#", level < 6 {
            level += 1
            index = trimmed.index(after: index)
        }
        guard level > 0, index < trimmed.endIndex, trimmed[index] == " " || trimmed[index] == "\t" else {
            return nil
        }
        let text = String(trimmed[index...]).trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3 else { return false }
        let chars = Set(compact)
        return chars == ["-"] || chars == ["*"] || chars == ["_"]
    }

    private static func listMatch(_ line: String) -> MarkdownDocumentBlock? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let indentSpaces = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let level = min(indentSpaces / 2, 6)
        let rest = line.dropFirst(leading.count)
        guard let first = rest.first else { return nil }

        // Bullet list (`-`, `*`, `+`).
        if "-*+".contains(first) {
            let after = rest.dropFirst()
            if after.isEmpty || after.first == " " {
                let text = String(after).trimmingCharacters(in: .whitespaces)
                return .listItem(indent: level, marker: taskMarkerOrBullet(text).marker,
                                 text: taskMarkerOrBullet(text).text)
            }
        }

        // Ordered list (`1.` / `1)`).
        var digits = ""
        var index = rest.startIndex
        while index < rest.endIndex, rest[index].isNumber, digits.count < 3 {
            digits.append(rest[index])
            index = rest.index(after: index)
        }
        if !digits.isEmpty, index < rest.endIndex, rest[index] == "." || rest[index] == ")" {
            let afterDot = rest.index(after: index)
            if afterDot >= rest.endIndex || rest[afterDot] == " " {
                let text = String(rest[afterDot...]).trimmingCharacters(in: .whitespaces)
                return .listItem(indent: level, marker: digits + ".", text: text)
            }
        }

        return nil
    }

    /// Renders GFM task items (`- [ ]` / `- [x]`) with a checkbox glyph instead
    /// of the raw bracket syntax.
    private static func taskMarkerOrBullet(_ text: String) -> (marker: String, text: String) {
        let lower = text.lowercased()
        if lower.hasPrefix("[ ] ") || lower.hasPrefix("[ ]\t") {
            return ("☐", String(text.dropFirst(4)).trimmingCharacters(in: .whitespaces))
        }
        if lower.hasPrefix("[x] ") || lower.hasPrefix("[x]\t") {
            return ("☑", String(text.dropFirst(4)).trimmingCharacters(in: .whitespaces))
        }
        return ("•", text)
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return false }
        let cells = splitTableRow(trimmed)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let stripped = cell.replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces)
            return !stripped.isEmpty && stripped.allSatisfy { $0 == "-" }
        }
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - Table

private struct MarkdownDocumentTable: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    ForEach(headers.indices, id: \.self) { column in
                        Text(MarkdownDocumentParser.inline(headers[column]))
                            .font(.callout.weight(.semibold))
                    }
                }
                Divider()
                    .gridCellUnsizedAxes(.horizontal)
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(headers.indices, id: \.self) { column in
                            Text(MarkdownDocumentParser.inline(column < rows[row].count ? rows[row][column] : ""))
                                .font(.callout)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
        }
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.1)))
    }
}
