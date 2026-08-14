import Foundation
import SwiftData

enum FeedPersistenceQueries {
    private static let missingArticleID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!

    static func activeFeeds() -> FetchDescriptor<Feed> {
        FetchDescriptor(
            predicate: #Predicate<Feed> { feed in
                feed.deletedAt == nil && feed.mergedIntoFeedID == nil
            }
        )
    }

    static func feeds(id: UUID) -> FetchDescriptor<Feed> {
        let feedID = id
        return FetchDescriptor(
            predicate: #Predicate<Feed> { feed in
                feed.id == feedID
            }
        )
    }

    static func articles(feedID: UUID) -> FetchDescriptor<Article> {
        let targetFeedID = feedID
        return FetchDescriptor(
            predicate: #Predicate<Article> { article in
                article.feedID == targetFeedID
            }
        )
    }

    static func articles(
        feedID: UUID,
        articleKeys: [String]
    ) -> FetchDescriptor<Article> {
        let targetFeedID = feedID
        let targetArticleKeys = articleKeys
        return FetchDescriptor(
            predicate: #Predicate<Article> { article in
                article.feedID == targetFeedID
                    && targetArticleKeys.contains(article.articleKey)
            }
        )
    }

    static func articles(id: UUID) -> FetchDescriptor<Article> {
        let articleID = id
        var descriptor = FetchDescriptor(
            predicate: #Predicate<Article> { article in
                article.id == articleID
            }
        )
        // A legacy CloudKit import can temporarily produce duplicate IDs. Fetch
        // two so callers can reject an ambiguous write without scanning the
        // rest of the article store.
        descriptor.fetchLimit = 2
        return descriptor
    }

    static func articles(
        articleKey: String,
        feedIDs: [UUID]
    ) -> FetchDescriptor<Article> {
        let targetArticleKey = articleKey
        let allowedFeedIDs = feedIDs
        var descriptor = FetchDescriptor(
            predicate: #Predicate<Article> { article in
                allowedFeedIDs.contains(article.feedID)
                    && article.articleKey == targetArticleKey
            },
            sortBy: [SortDescriptor(\Article.id)]
        )
        descriptor.fetchLimit = 2
        return descriptor
    }

    static func restoredArticlePredicate(
        reference: StoredArticleReference?,
        candidateArticleKeys: [String]
    ) -> Predicate<Article> {
        let hasReference = reference != nil
        let articleID = reference?.id ?? missingArticleID
        let candidateKeys = candidateArticleKeys

        return #Predicate<Article> { article in
            hasReference
                && (article.id == articleID
                    || candidateKeys.contains(article.articleKey))
        }
    }

    static func articlePredicate(
        feedIDs: [UUID],
        hidesReadArticles: Bool,
        selectedArticleKey: String?,
        searchText: String
    ) -> Predicate<Article> {
        let allowedFeedIDs = feedIDs
        let selectedKey = selectedArticleKey ?? ""
        let hasSelectedArticle = selectedArticleKey != nil
        // Preserve the search field's exact value. `localizedStandardContains`
        // provides the same user-facing matching behavior as the former
        // in-memory filter, including for whitespace-only searches.
        let query = searchText

        return #Predicate<Article> { article in
            allowedFeedIDs.contains(article.feedID)
                && (!hidesReadArticles
                    || !article.isRead
                    || (hasSelectedArticle && article.articleKey == selectedKey))
                && (query.isEmpty
                    || article.title.localizedStandardContains(query)
                    || article.summaryText.localizedStandardContains(query))
        }
    }

    static func articlePage(
        feedIDs: [UUID],
        hidesReadArticles: Bool,
        selectedArticleKey: String?,
        searchText: String,
        fetchLimit: Int
    ) -> FetchDescriptor<Article> {
        var descriptor = FetchDescriptor<Article>(
            predicate: articlePredicate(
                feedIDs: feedIDs,
                hidesReadArticles: hidesReadArticles,
                selectedArticleKey: selectedArticleKey,
                searchText: searchText
            ),
            sortBy: [
                SortDescriptor(\Article.publishedAt, order: .reverse),
                SortDescriptor(\Article.id),
            ]
        )
        descriptor.fetchLimit = max(1, fetchLimit)
        return descriptor
    }
}
