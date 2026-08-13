import SwiftUI
import Textual

struct ArticleMarkdownView: View {
    let markdown: String
    let appearance: ArticleReadingAppearance

    @Environment(\.colorScheme) private var systemColorScheme

    init(
        markdown: String,
        appearance: ArticleReadingAppearance = .default
    ) {
        self.markdown = markdown
        self.appearance = appearance
    }

    var body: some View {
        StructuredText(markdown: markdown)
            .font(appearance.bodyFont)
            .textual.structuredTextStyle(.default)
            .textual.paragraphStyle(
                ArticleParagraphStyle(lineSpacing: appearance.lineSpacing)
            )
            .textual.textSelection(.enabled)
            .foregroundStyle(
                appearance.theme.primaryTextColor(for: systemColorScheme)
            )
            .tint(appearance.theme.accentColor(for: systemColorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ArticleParagraphStyle: StructuredText.ParagraphStyle {
    let lineSpacing: ArticleLineSpacing

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textual.lineSpacing(
                .fontScaled(lineSpacing.markdownLineSpacing)
            )
            .textual.blockSpacing(
                .fontScaled(top: lineSpacing.markdownBlockSpacing)
            )
    }
}

#Preview("Markdown Content") {
    ScrollView {
        ArticleMarkdownView(
            markdown: """
                # Textual Preview

                This sample contains **bold text**, `inline code`, and a [link](https://example.com).

                - Supports lists
                - Supports blockquotes and code blocks

                > The RSS reader uses Textual to render extracted Markdown article content.

                ```swift
                NavigationSplitView {
                    SidebarView()
                } detail: {
                    ArticleDetailView()
                }
                ```
                """,
            appearance: ArticleReadingAppearance(
                fontFamily: .serif,
                textSize: .large,
                lineSpacing: .relaxed,
                contentWidth: .standard,
                theme: .sepia,
                pageMargins: .comfortable
            )
        )
        .padding()
    }
    .frame(minWidth: 520, minHeight: 560)
}
