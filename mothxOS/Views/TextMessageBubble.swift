import Foundation
import SwiftUI

struct TextMessageBubble: View {
    @Environment(\.colorScheme) private var colorScheme
    let message: MothxMessage
    let isCurrentRunning: Bool
    /// When non-nil, shows the "fork session" action on hover. The callback
    /// carries the completed assistant reply used as the API boundary.
    var onFork: (() -> Void)? = nil
    var isForking = false
    var onPreviewImage: ((MothxImagePreview) -> Void)? = nil
    var onPreviewDocument: ((MothxDocumentPreview) -> Void)? = nil

    private var isUser: Bool { message.isUser }

    /// Absolute number of characters of the running reply revealed so far.
    /// Monotonic for the lifetime of a message and persisted in
    /// `TypewriterProgressStore` keyed by message id, so a re-appearance (lazy
    /// stack recycling, turn re-ready, session switch) resumes instead of
    /// wiping the text and typing it again from the first character.
    @State private var revealedCount = 0
    /// The bubble only ever holds a bounded window of the reply so a very long
    /// result is not re-materialized on every tick. `windowText` is the source
    /// slice starting at absolute offset `windowBase`; `foldedCount` is the
    /// absolute end offset already folded into the window.
    @State private var windowBase = 0
    @State private var windowText = ""
    @State private var foldedCount = 0
    @State private var typewriterTimer: Timer?
    @State private var blinkOpacity: Double = 1.0
    @State private var didStartBlink = false
    // Tracks the latest known text while running; the Timer closure reads
    // this @State (stable storage) instead of `message` (a frozen value-type
    // snapshot from whenever the closure was created), so newly polled
    // content keeps getting typed out instead of appearing in one jump.
    @State private var typingTarget: String = ""
    @State private var isHovered = false
    @State private var didCopy = false

    /// While running, at most this many characters are retained/typed. Older
    /// text is trimmed from the front rather than the whole result being
    /// cleared and re-typed from zero.
    private static let maxLiveCharacters = 8_000

    private var windowEnd: Int { windowBase + windowText.count }

    private var displayText: String {
        guard isCurrentRunning else { return message.displayText }
        let revealed = max(0, min(revealedCount - windowBase, windowText.count))
        let text = String(windowText.prefix(revealed))
        return windowBase > 0 ? "…\n" + text : text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 70) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 0) {
                        if !isUser && !isCurrentRunning && !displayText.isEmpty {
                            MarkdownMessageText(markdown: displayText)
                        } else {
                            Text(displayText.isEmpty ? (isUser ? "…" : "Thinking…") : displayText)
                                .textSelection(.enabled)
                                .lineSpacing(4)
                                .frame(maxWidth: 560, alignment: .leading)
                        }
                        if !message.imagePreviews.isEmpty {
                            ImagePreviewStrip(images: message.imagePreviews, onSelect: onPreviewImage ?? { _ in })
                        }
                        if !message.documentPreviews.isEmpty {
                            DocumentPreviewStrip(documents: message.documentPreviews, onSelect: onPreviewDocument ?? { _ in })
                        }
                        if isTyping {
                            Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 8, height: 16)
                                .opacity(blinkOpacity).padding(.leading, 2).padding(.top, -16)
                        }
                    }
                }
                .padding(14)
                .background(isUser ? userBackground : assistantBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                if isUser || onFork != nil {
                    messageMetadata
                        .frame(height: 22, alignment: isUser ? .topTrailing : .topLeading)
                }
            }
            if !isUser { Spacer(minLength: 70) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .onHover { isHovered = $0 }
        .onAppear { syncTypewriterOnAppear() }
        .onChange(of: message.displayText) { _, newText in
            typingTarget = newText
            foldContent(newText)
            if isCurrentRunning {
                // New content arrived from polling — extend the typing target
                // and keep (or restart) the timer so it keeps catching up
                // smoothly instead of stalling. Progress is never rewound.
                if revealedCount < windowEnd, typewriterTimer == nil {
                    startTypewriter()
                }
            } else {
                // Completed message: show the full text and remember it so a
                // later re-appearance cannot rewind the bubble.
                stopTypewriter()
                revealedCount = windowEnd
                TypewriterProgressStore.shared.set(newText.count, for: message.id)
            }
        }
        .onChange(of: isCurrentRunning) { _, running in
            typingTarget = message.displayText
            foldContent(typingTarget)
            if running {
                // The run (re)attached. Resume from the remembered progress;
                // never clear the already-typed text and start over.
                let stored = TypewriterProgressStore.shared.count(for: message.id) ?? revealedCount
                revealedCount = min(max(revealedCount, stored), windowEnd)
                if revealedCount < windowEnd { startTypewriter() } else { stopTypewriter() }
            } else {
                // Run finished (or its grace period ended) — stop and show
                // whatever text remains in full rather than freezing mid-type.
                stopTypewriter()
                revealedCount = windowEnd
                TypewriterProgressStore.shared.set(typingTarget.count, for: message.id)
            }
        }
        .onDisappear { stopTypewriter() }
    }

    private var isTyping: Bool { isCurrentRunning && revealedCount < windowEnd }

    /// Resolves what to show the first time this bubble appears in the current
    /// view tree. A running message resumes from the persisted progress (or
    /// starts from zero on a genuine first appearance); a finished message is
    /// shown in full immediately.
    private func syncTypewriterOnAppear() {
        typingTarget = message.displayText
        if isCurrentRunning {
            let stored = TypewriterProgressStore.shared.count(for: message.id) ?? 0
            rebuildWindow(from: typingTarget, revealed: stored)
            if revealedCount < windowEnd {
                startTypewriter()
            } else {
                stopTypewriter()
                TypewriterProgressStore.shared.set(revealedCount, for: message.id)
            }
        } else {
            rebuildWindow(from: typingTarget, revealed: typingTarget.count)
            stopTypewriter()
            TypewriterProgressStore.shared.set(typingTarget.count, for: message.id)
        }
    }

    /// Folds newly streamed characters into the bounded window. The reply only
    /// ever grows while running, so the common path appends just the new tail;
    /// the window is then trimmed from the front to stay within the cap.
    private func foldContent(_ target: String) {
        let count = target.count
        if count <= foldedCount {
            // The source did not grow (it shrank, or was replaced by a final
            // projection of the same length) — rebuild around the reveal
            // cursor so the window can never hold stale characters.
            rebuildWindow(from: target, revealed: min(revealedCount, count))
            return
        }
        windowText += target.suffix(count - foldedCount)
        foldedCount = count
        trimWindow()
    }

    /// Rebuilds the bounded window as the newest `maxLiveCharacters` of the
    /// target and clamps the reveal cursor into it, so an already-visible
    /// prefix is never re-typed from zero and the newest text stays available.
    private func rebuildWindow(from target: String, revealed: Int) {
        let count = target.count
        let base = max(0, count - Self.maxLiveCharacters)
        let startIndex = target.index(target.startIndex, offsetBy: base)
        windowBase = base
        windowText = String(target[startIndex..<target.endIndex])
        foldedCount = count
        revealedCount = max(base, min(revealed, count))
    }

    /// Drops the oldest characters once the window outgrows the cap, keeping
    /// the newest content (the front is truncated, never the whole result).
    private func trimWindow() {
        guard windowText.count > Self.maxLiveCharacters else { return }
        let drop = windowText.count - Self.maxLiveCharacters
        windowText.removeFirst(drop)
        windowBase += drop
        if revealedCount < windowBase { revealedCount = windowBase }
        if foldedCount < windowBase { foldedCount = windowBase }
    }

    private func startTypewriter() {
        typewriterTimer?.invalidate()
        // ~8ms per tick with an adaptive step below: a steady stream is typed
        // at roughly 120 chars/s and a burst is caught up within a few ticks.
        typewriterTimer = Timer.scheduledTimer(withTimeInterval: 0.008, repeats: true) { _ in
            advanceTypewriter()
        }
        guard !didStartBlink else { return }
        didStartBlink = true
        withAnimation(.easeInOut(duration: 0.6).repeatForever()) { blinkOpacity = 0.0 }
    }

    private func stopTypewriter() {
        typewriterTimer?.invalidate()
        typewriterTimer = nil
    }

    private func advanceTypewriter() {
        let end = windowEnd
        guard revealedCount < end else {
            TypewriterProgressStore.shared.set(revealedCount, for: message.id)
            return
        }
        let backlog = end - revealedCount
        // Adaptive catch-up: reveal proportionally more per tick when far
        // behind, so a large streamed result is not typed one character at a
        // time forever.
        let step = max(1, backlog / 8)
        revealedCount = min(end, revealedCount + step)
        TypewriterProgressStore.shared.set(revealedCount, for: message.id)
    }

    private var messageMetadata: some View {
        HStack(spacing: 10) {
            if isHovered {
                if isUser {
                    Button {
                        copyQuestion()
                    } label: {
                        HStack(spacing: 4) {
                            Text(didCopy ? "已复制" : "复制主题")
                            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(didCopy ? "已复制 / Copied" : "复制主题 / Copy topic")
                }

                if let onFork {
                    Button {
                        onFork()
                    } label: {
                        HStack(spacing: 4) {
                            Text("会话分叉")
                            Image(systemName: "arrow.triangle.branch")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isForking)
                    .help("从这里开始创建新的会话 / Start a new session from here")
                }
            }
        }
        .opacity(isHovered ? 1 : 0)
    }

    private func copyQuestion() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.displayText, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            didCopy = false
        }
    }

    private var assistantBackground: Color { colorScheme == .light ? .white : .codexCard }
    private var userBackground: Color { colorScheme == .light ? Color(red: 0.94, green: 0.94, blue: 0.95) : Color.orange.opacity(0.18) }
}
/// Remembers how much of a running reply has already been revealed, keyed by
/// message id. SwiftUI discards `@State` whenever a bubble is recycled by the
/// lazy conversation stack or its turn body is re-prepared; without this store
/// the typewriter would restart from the first character and visibly re-type
/// (re-load) the whole — potentially very long — result. Progress is kept
/// monotonic so a bubble never rewinds.
final class TypewriterProgressStore {
    static let shared = TypewriterProgressStore()

    private var counts: [String: Int] = [:]
    /// Insertion order, used to evict the oldest entries so a long-lived app
    /// session with thousands of messages cannot grow this without bound.
    private var order: [String] = []
    private let maxEntries = 400

    private init() {}

    func count(for id: String) -> Int? {
        counts[id]
    }

    func set(_ value: Int, for id: String) {
        guard !id.isEmpty else { return }
        if counts[id] == nil { order.append(id) }
        counts[id] = value
        if order.count > maxEntries {
            let evicted = order.removeFirst()
            counts.removeValue(forKey: evicted)
        }
    }

    func remove(_ id: String) {
        counts.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }
}


/// Renders a completed assistant response as Markdown while keeping a plain-text
/// fallback for malformed or unsupported Markdown input. Shared by the session
/// conversation and the team task final answer.
struct MarkdownMessageText: View {
    let markdown: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var renderedSegments: [MarkdownSegment] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(renderedSegments.isEmpty ? [MarkdownSegment(content: markdown, isCodeBlock: false)] : renderedSegments) { segment in
                if segment.isCodeBlock {
                    Group {
                        if let attributedString = segment.attributedString {
                            Text(attributedString)
                        } else {
                            Text(segment.rawContent)
                        }
                    }
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(codeBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                } else if !segment.content.isEmpty {
                    if let attributedString = segment.attributedString {
                        Text(attributedString).lineSpacing(4)
                    } else {
                        Text(segment.rawContent).lineSpacing(4)
                    }
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: 560, alignment: .leading)
        .onAppear { updateRenderedSegments() }
        .onChange(of: markdown) { _, _ in updateRenderedSegments() }
    }

    private var codeBackground: Color {
        colorScheme == .light ? Color.black.opacity(0.06) : Color.white.opacity(0.09)
    }

    private var segments: [MarkdownSegment] {
        let pattern = "```[\\s\\S]*?```"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [MarkdownSegment(content: markdown, isCodeBlock: false)]
        }

        let matches = regex.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown))
        var result: [MarkdownSegment] = []
        var cursor = markdown.startIndex
        for match in matches {
            guard let range = Range(match.range, in: markdown) else { continue }
            if cursor < range.lowerBound {
                result.append(MarkdownSegment(content: String(markdown[cursor..<range.lowerBound]), isCodeBlock: false))
            }
            result.append(MarkdownSegment(
                content: codeContent(from: String(markdown[range])),
                isCodeBlock: true,
                rawContent: String(markdown[range])
            ))
            cursor = range.upperBound
        }
        if cursor < markdown.endIndex {
            result.append(MarkdownSegment(content: String(markdown[cursor...]), isCodeBlock: false))
        }
        return result.isEmpty ? [MarkdownSegment(content: markdown, isCodeBlock: false)] : result
    }

    private func updateRenderedSegments() {
        guard MarkdownSafety.isSafeToParse(markdown) else {
            renderedSegments = [MarkdownSegment(content: markdown, isCodeBlock: false)]
            return
        }
        renderedSegments = segments.map { segment in
            MarkdownSegment(
                content: segment.content,
                isCodeBlock: segment.isCodeBlock,
                attributedString: attributedString(for: segment.content),
                rawContent: segment.rawContent
            )
        }
    }

    private func codeContent(from fencedBlock: String) -> String {
        var lines = fencedBlock.components(separatedBy: "\n")
        if !lines.isEmpty { lines.removeFirst() }
        if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// AttributedString.MarkdownParsingOptions(interpretedSyntax: .full) collapses
    /// every newline in the source — soft breaks become spaces and paragraph breaks
    /// are dropped entirely — so a multi-line response would render as one unbroken
    /// run of text. Parse line-by-line instead (inline formatting such as **bold**,
    /// `code`, and links is preserved) and re-insert the breaks the author typed.
    private func attributedString(for markdown: String) -> AttributedString? {
        guard MarkdownSafety.isSafeToParse(markdown) else { return nil }
        let normalized = normalizedMarkdown(for: markdown)
        let lines = normalized.components(separatedBy: "\n")
        var result = AttributedString()
        var needParagraphBreak = false
        for rawLine in lines {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                needParagraphBreak = true
                continue
            }
            if !result.characters.isEmpty {
                result += AttributedString(needParagraphBreak ? "\n\n" : "\n")
            }
            needParagraphBreak = false
            guard let parsedLine = parsedInlineLine(trimmed) else { return nil }
            result += parsedLine
        }
        guard !markdown.isEmpty || !result.characters.isEmpty else { return nil }
        return result.characters.isEmpty && !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : result
    }

    /// Parse one line with full inline syntax. Block markers such as `- `, `* `,
    /// or `1. ` are stripped by the parser when the block is a single line, so
    /// restore them to keep lists readable.
    private func parsedInlineLine(_ line: String) -> AttributedString? {
        let marker = listMarkerPrefix(of: line)
        let content = marker.map { String(line.dropFirst($0.count)) } ?? line
        if let parsed = try? AttributedString(
            markdown: content,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        ) {
            if let marker {
                var result = AttributedString(marker)
                result += parsed
                return result
            }
            return parsed
        }
        // A malformed fragment falls back to the original segment. Do not
        // keep partially parsed output because losing one line is worse than
        // showing the source Markdown.
        return nil
    }

    private func listMarkerPrefix(of line: String) -> String? {
        let patterns = [#"^([-*+])\s+"#, #"^(\d+[.)])\s+"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line) else { continue }
            return String(line[range]) + " "
        }
        return nil
    }

    /// Some model responses put whitespace inside emphasis delimiters, for
    /// example `** text **`. Normalize those delimiters before parsing while
    /// leaving code spans and fenced code blocks byte-for-byte unchanged.
    private func normalizedMarkdown(for markdown: String) -> String {
        let protectedCodePattern = "```[\\s\\S]*?```|`[^`\\n]*`"
        guard let protectedCodeRegex = try? NSRegularExpression(pattern: protectedCodePattern) else {
            return normalizeEmphasis(in: markdown)
        }

        let matches = protectedCodeRegex.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown))
        var output = ""
        var cursor = markdown.startIndex
        for match in matches {
            guard let range = Range(match.range, in: markdown) else { continue }
            output += normalizeEmphasis(in: String(markdown[cursor..<range.lowerBound]))
            output += String(markdown[range])
            cursor = range.upperBound
        }
        output += normalizeEmphasis(in: String(markdown[cursor...]))
        return output
    }

    private func normalizeEmphasis(in text: String) -> String {
        let patternsAndTemplates = [
            (#"\*\*[\t\p{Zs}]+([^*\n]*?[^\s\p{Zs}])[\t\p{Zs}]+\*\*"#, "**$1**"),
            (#"__[\t\p{Zs}]+([^_\n]*?[^\s\p{Zs}])[\t\p{Zs}]+__"#, "__$1__"),
            (#"(?<!\*)\*[\t\p{Zs}]+([^*\n]*?[^\s\p{Zs}])[\t\p{Zs}]+\*(?!\*)"#, "*$1*"),
            (#"(?<![_A-Za-z0-9])_[\t\p{Zs}]+([^_\n]*?[^\s\p{Zs}])[\t\p{Zs}]+_(?![_A-Za-z0-9])"#, "_$1_")
        ]

        var normalized = text
        for (pattern, template) in patternsAndTemplates {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(normalized.startIndex..., in: normalized)
            normalized = regex.stringByReplacingMatches(
                in: normalized,
                range: range,
                withTemplate: template
            )
        }
        return normalized
    }
}

private struct MarkdownSegment: Identifiable {
    let id = UUID()
    let content: String
    let isCodeBlock: Bool
    let attributedString: AttributedString?
    let rawContent: String

    init(content: String, isCodeBlock: Bool, attributedString: AttributedString? = nil, rawContent: String? = nil) {
        self.content = content
        self.isCodeBlock = isCodeBlock
        self.attributedString = attributedString
        self.rawContent = rawContent ?? content
    }
}

private enum MarkdownSafety {
    // Keep pathological transcripts out of Foundation's Markdown parser. The
    // original source is still rendered as plain selectable text below.
    static let maxDocumentCharacters = 20_000
    static let maxLineCharacters = 4_000
    static let maxLineCount = 800
    static let maxFenceCount = 80

    static func isSafeToParse(_ text: String) -> Bool {
        guard text.count <= maxDocumentCharacters else { return false }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count <= maxLineCount else { return false }
        guard lines.allSatisfy({ $0.count <= maxLineCharacters }) else { return false }
        let fenceCount = text.components(separatedBy: "```").count - 1
        return fenceCount <= maxFenceCount
    }
}
