import SwiftData
import SwiftUI

struct FeedArticlesView: View {
    let selection: SubscriptionSelection?
    @Binding var selectedArticleKey: String?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.feedsModelContainer) private var modelContainer
    @Query(sort: \Feed.dateAdded) private var allFeeds: [Feed]
    @AppStorage(AppPreferences.hidesReadArticles)
    private var hidesReadArticles = false
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var refreshError: String?
    @State private var persistenceError: String?

    private var feeds: [Feed] {
        allFeeds.filter(\.isActive)
    }

    private var activeFeedIDs: Set<UUID> {
        Set(feeds.map(\.id))
    }

    private var articleFeedIDs: [UUID] {
        guard let selection else { return [] }

        switch selection {
        case .all:
            return activeFeedIDs.sorted {
                $0.uuidString < $1.uuidString
            }
        case .feed(let feedID):
            return activeFeedIDs.contains(feedID) ? [feedID] : []
        }
    }

    private var selectedFeed: Feed? {
        guard case .feed(let feedID)? = selection else { return nil }
        return feeds.first { $0.id == feedID }
    }

    private var showsAllArticles: Bool {
        selection == .all
    }

    var body: some View {
        Group {
            if selection == nil {
                ContentUnavailableView(
                    "Select a Feed",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text(
                        "Articles from the selected feed appear here."
                    )
                )
            } else {
                ArticleQueryResultsView(
                    feedIDs: articleFeedIDs,
                    hidesReadArticles: hidesReadArticles,
                    selectedArticleKey: $selectedArticleKey,
                    searchText: debouncedSearchText,
                    emptyTitle: emptyTitle,
                    emptyDescription: emptyDescription,
                    onUpdateRead: { updateReadState(for: $0) },
                    onUpdateStarred: { updateStarredState(for: $0) }
                )
                .id(
                    ArticleQueryScope(
                        feedIDs: articleFeedIDs,
                        hidesReadArticles: hidesReadArticles,
                        searchText: debouncedSearchText
                    )
                )
            }
        }
        .navigationTitle(
            showsAllArticles ? "All" : selectedFeed?.title ?? "Articles"
        )
        .searchable(text: $searchText, prompt: "Search Articles")
        .task(id: searchText) {
            if searchText.isEmpty {
                debouncedSearchText = ""
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(200))
                try Task.checkCancellation()
                debouncedSearchText = searchText
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
        .refreshable { await refreshSelectedFeed() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle("Hide Read Articles", isOn: $hidesReadArticles)
                        .accessibilityIdentifier("hideReadArticlesToggle")
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .disabled(selection == nil)
                .accessibilityIdentifier("articlesMenu")
            }
        }
        .alert(
            "Refresh Failed",
            isPresented: Binding(
                get: { refreshError != nil },
                set: { if !$0 { refreshError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { refreshError = nil }
        } message: {
            Text(refreshError ?? "Unknown error")
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
    }

    private var emptyTitle: String {
        hidesReadArticles ? "No Unread Articles" : "No Articles Yet"
    }

    private var emptyDescription: String {
        if hidesReadArticles {
            showsAllArticles
                ? "You have read every article from all feeds."
                : "You have read every article from this feed."
        } else {
            showsAllArticles
                ? "Pull to refresh all feeds for the latest articles."
                : "Pull to refresh for the latest articles."
        }
    }

    private func updateReadState(for article: Article) {
        guard let modelContainer else {
            persistenceError = "The data store is unavailable."
            return
        }
        do {
            try FeedSyncService.updateReadState(
                articleID: article.id,
                isRead: !article.isRead,
                modifiedAt: .now,
                modelContainer: modelContainer
            )
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    private func updateStarredState(for article: Article) {
        guard let modelContainer else {
            persistenceError = "The data store is unavailable."
            return
        }
        do {
            try FeedSyncService.updateStarredState(
                articleID: article.id,
                isStarred: !article.isStarred,
                modifiedAt: .now,
                modelContainer: modelContainer
            )
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    @MainActor
    private func refreshSelectedFeed() async {
        if showsAllArticles {
            var failures: [String] = []
            for feed in feeds {
                do {
                    try await FeedSyncService.refresh(
                        feed,
                        modelContext: modelContext
                    )
                } catch {
                    failures.append(
                        "\(feed.title): \(error.localizedDescription)"
                    )
                }
            }
            if !failures.isEmpty {
                refreshError = failures.joined(separator: "\n")
            }
            return
        }

        guard let selectedFeed else { return }

        do {
            try await FeedSyncService.refresh(
                selectedFeed,
                modelContext: modelContext
            )
        } catch {
            refreshError = error.localizedDescription
        }
    }
}

private struct ArticleQueryResultsView: View {
    private static let pageSize = 100

    @Binding private var selectedArticleKey: String?
    @State private var pageLimit: Int

    let feedIDs: [UUID]
    let hidesReadArticles: Bool
    let searchText: String
    let emptyTitle: String
    let emptyDescription: String
    let onUpdateRead: (Article) -> Void
    let onUpdateStarred: (Article) -> Void

    init(
        feedIDs: [UUID],
        hidesReadArticles: Bool,
        selectedArticleKey: Binding<String?>,
        searchText: String,
        emptyTitle: String,
        emptyDescription: String,
        onUpdateRead: @escaping (Article) -> Void,
        onUpdateStarred: @escaping (Article) -> Void
    ) {
        _selectedArticleKey = selectedArticleKey
        _pageLimit = State(initialValue: Self.pageSize)
        self.feedIDs = feedIDs
        self.hidesReadArticles = hidesReadArticles
        self.searchText = searchText
        self.emptyTitle = emptyTitle
        self.emptyDescription = emptyDescription
        self.onUpdateRead = onUpdateRead
        self.onUpdateStarred = onUpdateStarred
    }

    var body: some View {
        ArticlePageResultsView(
            feedIDs: feedIDs,
            hidesReadArticles: hidesReadArticles,
            selectedArticleKey: $selectedArticleKey,
            searchText: searchText,
            fetchLimit: pageLimit,
            emptyTitle: emptyTitle,
            emptyDescription: emptyDescription,
            onUpdateRead: onUpdateRead,
            onUpdateStarred: onUpdateStarred,
            onLoadMore: {
                pageLimit += Self.pageSize
            }
        )
    }
}

private struct ArticleQueryScope: Hashable {
    let feedIDs: [UUID]
    let hidesReadArticles: Bool
    let searchText: String
}

private struct ArticlePageResultsView: View {
    @Binding private var selectedArticleKey: String?
    @Query private var articles: [Article]
    @Query private var selectedArticles: [Article]

    let fetchLimit: Int
    let searchText: String
    let emptyTitle: String
    let emptyDescription: String
    let onUpdateRead: (Article) -> Void
    let onUpdateStarred: (Article) -> Void
    let onLoadMore: () -> Void

    init(
        feedIDs: [UUID],
        hidesReadArticles: Bool,
        selectedArticleKey: Binding<String?>,
        searchText: String,
        fetchLimit: Int,
        emptyTitle: String,
        emptyDescription: String,
        onUpdateRead: @escaping (Article) -> Void,
        onUpdateStarred: @escaping (Article) -> Void,
        onLoadMore: @escaping () -> Void
    ) {
        _selectedArticleKey = selectedArticleKey
        _articles = Query(
            FeedPersistenceQueries.articlePage(
                feedIDs: feedIDs,
                hidesReadArticles: hidesReadArticles,
                // The selected article is pinned by the scoped query below.
                // Keeping it out of the page prevents a hidden read article
                // from displacing an unread result at the fetch boundary.
                selectedArticleKey: nil,
                searchText: searchText,
                fetchLimit: fetchLimit
            )
        )

        let selectedKey = selectedArticleKey.wrappedValue
        _selectedArticles = Query(
            FeedPersistenceQueries.articles(
                articleKey: selectedKey ?? "",
                feedIDs: selectedKey == nil ? [] : feedIDs
            )
        )
        self.fetchLimit = fetchLimit
        self.searchText = searchText
        self.emptyTitle = emptyTitle
        self.emptyDescription = emptyDescription
        self.onUpdateRead = onUpdateRead
        self.onUpdateStarred = onUpdateStarred
        self.onLoadMore = onLoadMore
    }

    private var selectedArticleOutsidePage: Article? {
        selectedArticles.first { selectedArticle in
            let matchesSearch =
                searchText.isEmpty
                || selectedArticle.title.localizedStandardContains(searchText)
                || selectedArticle.summaryText.localizedStandardContains(
                    searchText
                )
            return matchesSearch
                && !articles.contains {
                    $0.persistentModelID == selectedArticle.persistentModelID
                }
        }
    }

    var body: some View {
        if articles.isEmpty {
            if let selectedArticleOutsidePage {
                List(selection: $selectedArticleKey) {
                    articleLink(selectedArticleOutsidePage)
                }
                .articleListStyle()
            } else {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: "newspaper")
                } description: {
                    Text(emptyDescription)
                }
            }
        } else {
            List(selection: $selectedArticleKey) {
                if let selectedArticleOutsidePage {
                    Section("Selected") {
                        articleLink(selectedArticleOutsidePage)
                    }
                }

                ForEach(articles) { article in
                    articleLink(article)
                }

                if articles.count == fetchLimit {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                        .task {
                            onLoadMore()
                        }
                }
            }
            .articleListStyle()
        }
    }

    private func articleLink(_ article: Article) -> some View {
        NavigationLink(value: article.articleKey) {
            ArticleRow(article: article)
        }
        .accessibilityIdentifier(
            "articleRow.\(article.articleKey)"
        )
        .navigationLinkIndicatorVisibility(.hidden)
        .tag(article.articleKey)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                onUpdateRead(article)
            } label: {
                Label(
                    article.isRead ? "Mark as Unread" : "Mark as Read",
                    systemImage: article.isRead
                        ? "circle" : "checkmark.circle"
                )
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing) {
            Button {
                onUpdateStarred(article)
            } label: {
                Label(
                    article.isStarred ? "Remove Favorite" : "Favorite",
                    systemImage: article.isStarred
                        ? "star.slash" : "star"
                )
            }
            .tint(.orange)
        }
    }
}

extension View {
    @ViewBuilder
    fileprivate func articleListStyle() -> some View {
        #if os(iOS)
            listRowSpacing(12)
                .listStyle(.insetGrouped)
        #else
            listStyle(.inset)
        #endif
    }
}

private struct ArticleRow: View {
    let article: Article

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(article.title)
                .font(.headline)
                .fontWeight(article.isRead ? .regular : .semibold)
                .foregroundStyle(article.isRead ? .secondary : .primary)
                .lineLimit(3)

            if !article.summaryText.isEmpty {
                Text(article.summaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 5) {
                Text(
                    article.publishedAt,
                    format: .relative(presentation: .named)
                )
                if article.isStarred {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Favorited")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityValue(article.isRead ? "Read" : "Unread")
    }
}

#Preview("All Articles") {
    @Previewable @State var selectedArticleKey: String?
    let container = PreviewSampleData.makeContainer()

    NavigationStack {
        FeedArticlesView(
            selection: .all,
            selectedArticleKey: $selectedArticleKey
        )
    }
    .environment(\.feedsModelContainer, container)
    .modelContainer(container)
}

#Preview("Single Feed") {
    @Previewable @State var selectedArticleKey: String?
    let container = PreviewSampleData.makeContainer()

    NavigationStack {
        FeedArticlesView(
            selection: .feed(PreviewSampleData.primaryFeedID),
            selectedArticleKey: $selectedArticleKey
        )
    }
    .environment(\.feedsModelContainer, container)
    .modelContainer(container)
}
