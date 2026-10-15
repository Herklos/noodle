import Foundation
import NoodleCore
import HubLink

// Shared by chat messages and the isolated native Markdown fixture.
final class MessageMarkdownCache: @unchecked Sendable {
    static let shared = MessageMarkdownCache()

    private final class Box {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    /// A message's parts in order: prose with its rendered text, and tables.
    enum Segment {
        case text(AttributedString, source: String)
        case table(MessageTable)
    }

    private final class SegmentsBox {
        let body: String
        let layout: MessageTextLayout
        let value: [Segment]
        init(body: String, layout: MessageTextLayout, value: [Segment]) {
            self.body = body; self.layout = layout; self.value = value
        }
    }

    private let values = NSCache<NSUUID, Box>()
    private let segmentValues = NSCache<NSUUID, SegmentsBox>()

    private init() {
        values.countLimit = 1_000
        segmentValues.countLimit = 1_000
    }

    func render(_ message: ChatMessage) -> AttributedString {
        let key = message.id as NSUUID
        if let cached = values.object(forKey: key) { return cached.value }
        let rendered = Self.render(message.body)
        values.setObject(Box(rendered), forKey: key)
        return rendered
    }

    func segments(_ message: ChatMessage, layout: MessageTextLayout = .defaultValue) -> [Segment] {
        let key = message.id as NSUUID
        if let cached = segmentValues.object(forKey: key), cached.body == message.body, cached.layout == layout {
            return cached.value
        }
        let parts = MessageSegment.split(message.body)
        let segments: [Segment] = layout != .together || parts.contains(where: { if case .table = $0 { true } else { false } })
            ? parts.flatMap { part -> [Segment] in
                switch part {
                case .text(let text): layout.parts(text).map { .text(Self.render($0), source: $0) }
                case .table(let table): [.table(table)]
                }
            }
            : [.text(render(message), source: message.body)]
        segmentValues.setObject(SegmentsBox(body: message.body, layout: layout, value: segments), forKey: key)
        return segments
    }

    static func render(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        var rendered = (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
        let allowedSchemes = Set(["http", "https", "mailto"])
        let unsafeLinkRanges = rendered.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let link = run.link,
                  !allowedSchemes.contains(link.scheme?.lowercased() ?? "") else { return nil }
            return run.range
        }
        for range in unsafeLinkRanges { rendered[range].link = nil }
        return rendered
    }
}
