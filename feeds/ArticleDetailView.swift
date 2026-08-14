import SwiftData
import SwiftUI

#if os(iOS)
    import UIKit
#endif

struct ArticleDetailView: View {
    let article: Article
    let isFullScreen: Bool
    let onToggleFullScreen: (() -> Void)?

    @Environment(\.feedsModelContainer) private var modelContainer
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var systemColorScheme
    @Query private var feeds: [Feed]
    @AppStorage(AppPreferences.articleReadingFontFamily)
    private var fontFamily = ArticleFontFamily.system
    @AppStorage(AppPreferences.articleReadingTextSize)
    private var textSize = ArticleTextSize.standard
    @AppStorage(AppPreferences.articleReadingLineSpacing)
    private var lineSpacing = ArticleLineSpacing.standard
    @AppStorage(AppPreferences.articleReadingContentWidth)
    private var contentWidth = ArticleContentWidth.standard
    @AppStorage(AppPreferences.articleReadingTheme)
    private var readingTheme = ArticleReadingTheme.standard
    @AppStorage(AppPreferences.articleReadingPageMargins)
    private var pageMargins = ArticlePageMargins.standard
    @AppStorage(AppPreferences.appAppearanceMode)
    private var appAppearanceMode = AppAppearanceMode.system
    @State private var isExtractingContent = false
    @State private var extractionPresentation: ArticleExtractionPresentationState
    @State private var isShowingReadingAppearance = false
    @State private var extractionError: String?
    @State private var persistenceError: String?

    init(
        article: Article,
        isFullScreen: Bool = false,
        onToggleFullScreen: (() -> Void)? = nil
    ) {
        self.article = article
        self.isFullScreen = isFullScreen
        self.onToggleFullScreen = onToggleFullScreen
        _extractionPresentation = State(
            initialValue: ArticleExtractionPresentationState(
                cachedMarkdown: article.extractedMarkdown
            )
        )
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(article.title)
                        .font(readingAppearance.titleFont)
                        .contentTransition(.interpolate)

                    if let author = article.author, !author.isEmpty {
                        HStack {
                            Label(author, systemImage: "person")
                            Divider()
                            Label {
                                Text(
                                    article.publishedAt,
                                    format: .dateTime
                                )
                            } icon: {
                                Image(systemName: "clock")
                            }

                        }
                        .font(.subheadline)
                        .foregroundStyle(
                            readingAppearance.theme.secondaryTextColor(
                                for: systemColorScheme
                            )
                        )
                    }

                    if extractionPresentation.isShowingExtractedContent,
                        let markdown = extractionPresentation.displayedMarkdown
                            ?? article.extractedMarkdown
                    {
                        extractedContent(markdown)
                    } else if article.summaryText.isEmpty {
                        ContentUnavailableView(
                            "No Article Summary Available",
                            systemImage: "text.page"
                        )
                    } else {
                        Text(article.summaryText)
                            .font(readingAppearance.bodyFont)
                            .lineSpacing(lineSpacing.textSpacing)
                            .contentTransition(.interpolate)
                            .textSelection(.enabled)
                    }
                }
                .foregroundStyle(
                    readingAppearance.theme.primaryTextColor(
                        for: systemColorScheme
                    )
                )
                .padding(.vertical, 16)
                .padding(
                    .horizontal,
                    pageMargins.horizontalPadding(for: geometry.size.width)
                )
                .frame(maxWidth: contentWidth.maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .animation(
                    readingAppearanceAnimation,
                    value: readingAppearance
                )
            }
            .background(
                readingAppearance.theme.backgroundColor(
                    for: systemColorScheme
                )
            )
            .tint(
                readingAppearance.theme.accentColor(for: systemColorScheme)
            )
        }
        #if !os(macOS)
            .navigationTitle(Text(article.feedTitle))
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(macOS)
                ToolbarItemGroup(placement: .primaryAction) {
                    openInBrowserAction
                        .keyboardShortcut("o", modifiers: [.command, .shift])
                    readingAppearanceAction
                    extractContentAction
                    favoriteAction
                        .keyboardShortcut("d", modifiers: .command)
                }
            #else
                #if os(iOS)
                    if shouldShowFullScreenAction {
                        ToolbarItem(placement: .topBarLeading) {
                            fullScreenAction
                        }
                    }
                #endif

                ToolbarItem(placement: .topBarTrailing) {
                    openInBrowserAction
                }

                ToolbarItemGroup(placement: .bottomBar) {
                    readingAppearanceAction
                    extractContentAction
                    favoriteAction
                }
            #endif
        }
        .sheet(isPresented: $isShowingReadingAppearance) {
            ArticleReadingAppearanceSheet(
                appAppearanceMode: $appAppearanceMode,
                fontFamily: $fontFamily,
                textSize: $textSize,
                lineSpacing: $lineSpacing,
                contentWidth: $contentWidth,
                theme: $readingTheme,
                pageMargins: $pageMargins
            )
            .preferredColorScheme(appAppearanceMode.colorScheme)
            .presentationDetents([.large])
        }
        .alert(
            "Unable to Extract Content",
            isPresented: Binding(
                get: { extractionError != nil },
                set: { if !$0 { extractionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { extractionError = nil }
        } message: {
            Text(extractionError ?? "Unknown error")
        }
        .alert(
            "Unable to Save Changes",
            isPresented: Binding(
                get: { persistenceError != nil },
                set: { if !$0 { persistenceError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { persistenceError = nil }
        } message: {
            Text(persistenceError ?? "Unknown error")
        }
        .task(id: article.id) {
            extractionPresentation.reset(
                cachedMarkdown: article.extractedMarkdown
            )

            if !article.isRead {
                saveReadState(true)
            }
            await automaticallyExtractContentIfNeeded()
        }
    }

    @ViewBuilder
    private func extractedContent(_ markdown: String) -> some View {
        ArticleMarkdownView(
            markdown: markdown,
            baseURL: article.url,
            contentRevision: extractionPresentation.contentRevision,
            appearance: readingAppearance
        )
        .id(article.id)
    }

    private var readingAppearance: ArticleReadingAppearance {
        ArticleReadingAppearance(
            fontFamily: fontFamily,
            textSize: textSize,
            lineSpacing: lineSpacing,
            contentWidth: contentWidth,
            theme: readingTheme,
            pageMargins: pageMargins
        )
    }

    private var readingAppearanceAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.2)
    }

    private var readingAppearanceAction: some View {
        Button {
            isShowingReadingAppearance = true
        } label: {
            Label("Reading Appearance", systemImage: "textformat.size")
        }
        .help("Customize reading appearance")
        .accessibilityIdentifier("articleReadingAppearanceButton")
    }

    #if os(iOS)
        private var shouldShowFullScreenAction: Bool {
            UIDevice.current.userInterfaceIdiom == .pad
                && onToggleFullScreen != nil
                && (horizontalSizeClass == .regular || isFullScreen)
        }

        private var fullScreenAction: some View {
            Button {
                onToggleFullScreen?()
            } label: {
                Label(
                    isFullScreen ? "Exit Full Screen" : "Enter Full Screen",
                    systemImage: isFullScreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right"
                )
            }
            .help(isFullScreen ? "Exit Full Screen" : "Enter Full Screen")
            .accessibilityIdentifier("toggleArticleFullScreenButton")
            .accessibilityValue(isFullScreen ? "On" : "Off")
        }
    #endif

    @ViewBuilder
    private var openInBrowserAction: some View {
        if let url = article.url {
            Link(destination: url) {
                Label("Open in Browser", systemImage: "safari")
            }
            .help("Open in the default browser")
            .accessibilityIdentifier("openArticleInBrowserButton")
        }
    }

    private var extractContentAction: some View {
        Toggle(isOn: extractedContentToggle) {
            if isExtractingContent {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Extracting article content")
            } else {
                Label(
                    "Extract Content",
                    systemImage: extractionPresentation
                        .isShowingExtractedContent
                        ? "doc.text.fill" : "doc.text.magnifyingglass"
                )
            }
        }
        .toggleStyle(.button)
        .disabled(
            (article.url == nil
                && extractionPresentation.displayedMarkdown == nil
                && article.extractedMarkdown == nil)
                || isExtractingContent
        )
        .help(
            extractionPresentation.isShowingExtractedContent
                ? "Show RSS content" : "Show extracted content"
        )
        .accessibilityIdentifier("extractArticleContentButton")
        .accessibilityValue(
            extractionPresentation.isShowingExtractedContent ? "On" : "Off"
        )
    }

    private var extractedContentToggle: Binding<Bool> {
        Binding(
            get: { extractionPresentation.isShowingExtractedContent },
            set: { shouldShowExtractedContent in
                guard shouldShowExtractedContent else {
                    extractionPresentation.showRSSContent()
                    return
                }

                if extractionPresentation.displayedMarkdown != nil
                    || article.extractedMarkdown != nil
                {
                    extractionPresentation.showExtractedContentIfAvailable()
                    return
                }

                extractionPresentation.beginExtraction()
                Task { await extractContent() }
            }
        )
    }

    private var favoriteAction: some View {
        Toggle(isOn: favoriteToggle) {
            Label(
                "Favorite",
                systemImage: article.isStarred ? "star.fill" : "star"
            )
        }
        .toggleStyle(.button)
        .tint(article.isStarred ? .orange : .primary)
        .help(
            article.isStarred ? "Remove from Favorites" : "Add to Favorites"
        )
        .accessibilityIdentifier("toggleArticleFavoriteButton")
        .accessibilityValue(article.isStarred ? "On" : "Off")
    }

    private var favoriteToggle: Binding<Bool> {
        Binding(
            get: { article.isStarred },
            set: { saveStarredState($0) }
        )
    }

    @MainActor
    private func automaticallyExtractContentIfNeeded() async {
        guard extractionPresentation.displayedMarkdown == nil,
            article.extractedMarkdown == nil,
            article.url != nil,
            feeds.first(where: { $0.id == article.feedID })?
                .isActive == true,
            feeds.first(where: { $0.id == article.feedID })?
                .automaticallyExtractsArticleContent == true
        else {
            return
        }

        await extractContent()
    }

    private func saveReadState(_ isRead: Bool) {
        guard let modelContainer else {
            persistenceError = "The data store is unavailable."
            return
        }
        do {
            try FeedSyncService.updateReadState(
                articleID: article.id,
                isRead: isRead,
                modifiedAt: .now,
                modelContainer: modelContainer
            )
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    private func saveStarredState(_ isStarred: Bool) {
        guard let modelContainer else {
            persistenceError = "The data store is unavailable."
            return
        }
        do {
            try FeedSyncService.updateStarredState(
                articleID: article.id,
                isStarred: isStarred,
                modifiedAt: .now,
                modelContainer: modelContainer
            )
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    @MainActor
    private func extractContent() async {
        guard !isExtractingContent else { return }
        let extractingArticleID = article.id
        isExtractingContent = true
        defer { isExtractingContent = false }
        do {
            guard let modelContainer else {
                throw ArticlePersistenceError.dataStoreUnavailable
            }
            let markdown =
                try await ArticleContentExtractor
                .extractMarkdown(from: article.url)
            try FeedSyncService.saveExtractedMarkdown(
                markdown,
                articleID: article.id,
                modifiedAt: .now,
                modelContainer: modelContainer
            )
            try Task.checkCancellation()
            guard extractingArticleID == article.id else { return }
            extractionPresentation.extractionSucceeded(markdown: markdown)
        } catch is CancellationError {
            return
        } catch {
            guard extractingArticleID == article.id else { return }
            extractionPresentation.extractionFailed()
            extractionError = error.localizedDescription
        }
    }
}

struct ArticleExtractionPresentationState: Equatable {
    private(set) var displayedMarkdown: String?
    private(set) var isShowingExtractedContent: Bool
    private(set) var contentRevision = UUID()

    init(cachedMarkdown: String?) {
        displayedMarkdown = cachedMarkdown
        isShowingExtractedContent = cachedMarkdown != nil
    }

    mutating func reset(cachedMarkdown: String?) {
        if displayedMarkdown != cachedMarkdown {
            contentRevision = UUID()
        }
        displayedMarkdown = cachedMarkdown
        isShowingExtractedContent = cachedMarkdown != nil
    }

    mutating func showRSSContent() {
        isShowingExtractedContent = false
    }

    mutating func showExtractedContentIfAvailable() {
        isShowingExtractedContent = displayedMarkdown != nil
    }

    mutating func beginExtraction() {
        guard displayedMarkdown == nil else {
            isShowingExtractedContent = true
            return
        }
        isShowingExtractedContent = false
    }

    mutating func extractionSucceeded(markdown: String) {
        if displayedMarkdown != markdown {
            contentRevision = UUID()
        }
        displayedMarkdown = markdown
        isShowingExtractedContent = true
    }

    mutating func extractionFailed() {
        isShowingExtractedContent = false
    }
}

private enum ArticlePersistenceError: LocalizedError {
    case dataStoreUnavailable

    var errorDescription: String? {
        "The data store is unavailable."
    }
}

#Preview("Article Detail") {
    let container = PreviewSampleData.makeContainer()

    NavigationStack {
        ArticleDetailView(
            article: PreviewSampleData.featuredArticle(in: container)
        )
    }
    .environment(\.feedsModelContainer, container)
    .modelContainer(container)
}
