import SwiftUI
import Textual

/// Render block Markdown as a document, not as one flattened SwiftUI Text.
struct AgentMarkdownView: View {
    let markdown: String

    var body: some View {
        StructuredText(markdown, parser: AgentMarkdownParser())
            .font(.callout)
            .textual.headingStyle(ContextMarkdownHeadingStyle())
            .textual.textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Preserve Markdown structure while keeping navigation in validated source rows.
/// Generated images remain alternative text; rendering never fetches their URLs.
struct AgentMarkdownParser: MarkupParser {
    func attributedString(for input: String) throws -> AttributedString {
        guard var result = try? AttributedString(markdown: input) else {
            return AttributedString(input)
        }
        let ranges = result.runs.compactMap { run in
            run.link != nil || run.imageURL != nil ? run.range : nil
        }
        for range in ranges {
            result[range].link = nil
            result[range].imageURL = nil
        }
        return result
    }
}

private struct ContextMarkdownHeadingStyle: StructuredText.HeadingStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textual.fontScale(configuration.headingLevel == 1 ? 1.35 : configuration.headingLevel == 2 ? 1.15 : 1)
            .fontWeight(.semibold)
            .textual.blockSpacing(.fontScaled(top: 1.2, bottom: 0.5))
    }
}
