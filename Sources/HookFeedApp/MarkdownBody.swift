import HookFeedCore
import SwiftUI

/// Renders agent Markdown: inline styles, headings, and code or tables in monospace.
struct MarkdownBody: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(Self.inline(text)).font(level <= 2 ? .headline : .subheadline.bold())
                case .paragraph(let text):
                    Text(Self.inline(text))
                case .code(let text):
                    ScrollView(.horizontal) {
                        Text(text).font(.system(.caption, design: .monospaced)).padding(8)
                    }
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .textSelection(.enabled)
        // Agent text can carry any link; only web pages may open.
        .environment(\.openURL, OpenURLAction { MarkdownText.allowsLink($0) ? .systemAction : .discarded })
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
