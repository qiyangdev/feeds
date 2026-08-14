import SwiftUI
import Textual

nonisolated private struct PreparedArticleContent: Sendable {
    let sourceRevision: UUID
    let baseURL: URL?
    let renderRevision: UUID
    let markdown: String
    let attributedString: AttributedString?
    let audio: [ArticleAudioDescriptor]
}

nonisolated private struct ArticleContentPreparationRequest: Hashable,
    Sendable
{
    let contentRevision: UUID
    let baseURL: URL?
}

nonisolated private enum ArticleContentPreparation {
    @concurrent
    static func prepare(
        markdown: String,
        baseURL: URL?,
        contentRevision: UUID
    ) async -> PreparedArticleContent {
        let document = await ArticleAudioContentParser.parse(
            from: markdown,
            baseURL: baseURL
        )
        guard !Task.isCancelled else {
            return PreparedArticleContent(
                sourceRevision: contentRevision,
                baseURL: baseURL,
                renderRevision: UUID(),
                markdown: markdown,
                attributedString: nil,
                audio: []
            )
        }
        let attributedString = try? AttributedString(
            markdown: document.markdown,
            including: \.textual,
            options: .init(),
            baseURL: baseURL
        )
        return PreparedArticleContent(
            sourceRevision: contentRevision,
            baseURL: baseURL,
            renderRevision: UUID(),
            markdown: document.markdown,
            attributedString: attributedString,
            audio: document.audio
        )
    }
}

private struct PreparedArticleMarkupParser: MarkupParser {
    let attributedString: AttributedString

    func attributedString(for input: String) throws -> AttributedString {
        attributedString
    }
}

struct ArticleMarkdownView: View {
    let markdown: String
    let baseURL: URL?
    let contentRevision: UUID
    let appearance: ArticleReadingAppearance

    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var playbackController =
        ArticleAudioPlaybackController()
    @State private var preparedContent: PreparedArticleContent?

    init(
        markdown: String,
        baseURL: URL? = nil,
        contentRevision: UUID,
        appearance: ArticleReadingAppearance = .default
    ) {
        self.markdown = markdown
        self.baseURL = baseURL
        self.contentRevision = contentRevision
        self.appearance = appearance
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let preparedContent,
                preparedContent.sourceRevision == contentRevision,
                preparedContent.baseURL == baseURL
            {
                if !preparedContent.audio.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(preparedContent.audio, id: \.id) { audio in
                            ArticleAudioPlayerView(
                                audio: audio,
                                controller: playbackController,
                                appearance: appearance
                            )
                        }
                    }
                }

                if !preparedContent.markdown.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty {
                    markdownContent(preparedContent)
                }
            } else {
                ProgressView("Preparing article…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityIdentifier("articleContentPreparation")
            }
        }
        .task(
            id: ArticleContentPreparationRequest(
                contentRevision: contentRevision,
                baseURL: baseURL
            )
        ) {
            playbackController.stop()
            preparedContent = nil
            let prepared = await ArticleContentPreparation.prepare(
                markdown: markdown,
                baseURL: baseURL,
                contentRevision: contentRevision
            )
            guard !Task.isCancelled else { return }
            preparedContent = prepared
        }
        .onChange(of: scenePhase) {
            if scenePhase != .active {
                playbackController.pause()
            }
        }
        .onDisappear {
            playbackController.shutdown()
        }
        .foregroundStyle(
            appearance.theme.primaryTextColor(for: systemColorScheme)
        )
        .tint(appearance.theme.accentColor(for: systemColorScheme))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func markdownContent(
        _ preparedContent: PreparedArticleContent
    ) -> some View {
        if let attributedString = preparedContent.attributedString {
            StructuredText(
                preparedContent.renderRevision.uuidString,
                parser: PreparedArticleMarkupParser(
                    attributedString: attributedString
                )
            )
            .modifier(articleTextStyle)
        } else {
            StructuredText(
                markdown: preparedContent.markdown,
                baseURL: baseURL
            )
            .modifier(articleTextStyle)
        }
    }

    private var articleTextStyle: some ViewModifier {
        ArticleTextStyle(
            font: appearance.bodyFont,
            lineSpacing: appearance.lineSpacing
        )
    }
}

private struct ArticleTextStyle: ViewModifier {
    let font: Font
    let lineSpacing: ArticleLineSpacing

    func body(content: Content) -> some View {
        content
            .font(font)
            .textual.structuredTextStyle(.default)
            .textual.paragraphStyle(
                ArticleParagraphStyle(lineSpacing: lineSpacing)
            )
            .textual.textSelection(.enabled)
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
            contentRevision: UUID(),
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
