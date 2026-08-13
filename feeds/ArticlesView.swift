import SwiftData
import SwiftUI

struct FeedArticlesView: View {
    let selection: SubscriptionSelection?
    @Binding var selectedArticleKey: String?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.feedsModelContainer) private var modelContainer
    @Query(sort: \Article.publishedAt, order: .reverse) private var articles: [Article]
    @Query(sort: \Feed.dateAdded) private var allFeeds: [Feed]
    @AppStorage(AppPreferences.hidesReadArticles)
    private var hidesReadArticles = false
    @State private var searchText = ""
    @State private var refreshError: String?
    @State private var persistenceError: String?

    private var feeds: [Feed] {
        allFeeds.filter(\.isActive)
    }

    private var activeFeedIDs: Set<UUID> {
        Set(feeds.map(\.id))
    }

    private var selectedFeed: Feed? {
        guard case .feed(let feedID)? = selection else { return nil }
        return feeds.first { $0.id == feedID }
    }

    private var showsAllArticles: Bool {
        selection == .all
    }

    private var visibleArticles: [Article] {
        guard selection != nil else { return [] }
        return articles.filter { article in
            guard activeFeedIDs.contains(article.feedID) else { return false }
            let matchesFeed = showsAllArticles || article.feedID == selectedFeed?.id
            let matchesFilter =
                !hidesReadArticles
                || !article.isRead
                || article.articleKey == selectedArticleKey
            let matchesSearch =
                searchText.isEmpty
                || article.title.localizedStandardContains(searchText)
                || article.summaryText.localizedStandardContains(searchText)
            return matchesFeed && matchesFilter && matchesSearch
        }
    }

    var body: some View {
        Group {
            if selection == nil {
                ContentUnavailableView(
                    "Select a Feed",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text("Articles from the selected feed appear here.")
                )
            } else if visibleArticles.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: "newspaper")
                } description: {
                    Text(emptyDescription)
                }
            } else {
                List(selection: $selectedArticleKey) {
                    ForEach(visibleArticles) { article in
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
                                updateReadState(for: article)
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
                                updateStarredState(for: article)
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
                #if os(iOS)
                    .listRowSpacing(12)
                    .listStyle(.insetGrouped)
                #else
                    .listStyle(.inset)
                #endif
            }
        }
        .navigationTitle(showsAllArticles ? "All" : selectedFeed?.title ?? "Articles")
        .searchable(text: $searchText, prompt: "Search Articles")
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
                    failures.append("\(feed.title): \(error.localizedDescription)")
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
