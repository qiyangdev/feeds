import Foundation
import CoreData
import SwiftData
import Testing
@testable import feeds

@Suite(.serialized)
@MainActor
struct FeedSyncPersistenceTests {
    @Test func extractionPresentationTurnsOnOnlyAfterSuccess() {
        var state = ArticleExtractionPresentationState(cachedMarkdown: nil)

        #expect(!state.isShowingExtractedContent)
        state.beginExtraction()
        #expect(!state.isShowingExtractedContent)

        state.extractionSucceeded(markdown: "# Extracted")
        #expect(state.isShowingExtractedContent)
        #expect(state.displayedMarkdown == "# Extracted")
    }

    @Test func extractionPresentationStaysOffAfterFailure() {
        var state = ArticleExtractionPresentationState(cachedMarkdown: nil)

        state.beginExtraction()
        state.extractionFailed()

        #expect(!state.isShowingExtractedContent)
        #expect(state.displayedMarkdown == nil)
    }

    @Test func cachedExtractionStartsOnWithoutLoading() {
        let state = ArticleExtractionPresentationState(
            cachedMarkdown: "# Cached"
        )

        #expect(state.isShowingExtractedContent)
        #expect(state.displayedMarkdown == "# Cached")
    }

    @Test func schemaIsCompatibleWithCloudKit() throws {
        let model = try #require(
            NSManagedObjectModel.makeManagedObjectModel(
                for: [Feed.self, Article.self]
            )
        )

        for entity in model.entities {
            #expect(entity.uniquenessConstraints.isEmpty)

            for property in entity.attributesByName.values
            where !property.isOptional {
                #expect(
                    property.defaultValue != nil,
                    "\(entity.name ?? "Model").\(property.name) needs a default value for CloudKit."
                )
            }
        }
    }

    @Test func feedScopedArticleQueryFetchesOnlyTheTargetFeed() throws {
        let fixture = try TestStore()
        let targetFeedID = UUID()
        let otherFeedID = UUID()
        let targetArticles = [
            Article(
                articleKey: "\(targetFeedID.uuidString)|first",
                feedID: targetFeedID,
                feedTitle: "Target",
                title: "First target article"
            ),
            Article(
                articleKey: "\(targetFeedID.uuidString)|second",
                feedID: targetFeedID,
                feedTitle: "Target",
                title: "Second target article"
            ),
        ]
        let otherArticles = [
            Article(
                articleKey: "\(otherFeedID.uuidString)|first",
                feedID: otherFeedID,
                feedTitle: "Other",
                title: "First other article"
            ),
            Article(
                articleKey: "\(otherFeedID.uuidString)|second",
                feedID: otherFeedID,
                feedTitle: "Other",
                title: "Second other article"
            ),
        ]
        for article in targetArticles + otherArticles {
            fixture.context.insert(article)
        }
        try fixture.context.save()

        let fetched = try fixture.context.fetch(
            FeedPersistenceQueries.articles(feedID: targetFeedID)
        )

        #expect(Set(fetched.map(\.id)) == Set(targetArticles.map(\.id)))
        #expect(fetched.allSatisfy { $0.feedID == targetFeedID })
    }

    @Test func payloadScopedArticleQueryFetchesOnlyIncomingKeys() throws {
        let fixture = try TestStore()
        let targetFeedID = UUID()
        let otherFeedID = UUID()
        let incomingKey = "\(targetFeedID.uuidString)|incoming"
        let incoming = Article(
            articleKey: incomingKey,
            feedID: targetFeedID,
            feedTitle: "Target",
            title: "Incoming"
        )
        let historical = Article(
            articleKey: "\(targetFeedID.uuidString)|historical",
            feedID: targetFeedID,
            feedTitle: "Target",
            title: "Historical"
        )
        let otherFeed = Article(
            articleKey: incomingKey,
            feedID: otherFeedID,
            feedTitle: "Other",
            title: "Other feed"
        )
        for article in [incoming, historical, otherFeed] {
            fixture.context.insert(article)
        }
        try fixture.context.save()

        let matches = try fixture.context.fetch(
            FeedPersistenceQueries.articles(
                feedID: targetFeedID,
                articleKeys: [incomingKey]
            )
        )
        let emptyMatches = try fixture.context.fetch(
            FeedPersistenceQueries.articles(
                feedID: targetFeedID,
                articleKeys: []
            )
        )

        #expect(matches.map(\.id) == [incoming.id])
        #expect(emptyMatches.isEmpty)
    }

    @Test func articleIDQueryFetchesTwoRowsToDetectLegacyDuplicates() throws {
        let fixture = try TestStore()
        let feedID = UUID()
        let duplicateID = UUID()
        for index in 0..<3 {
            fixture.context.insert(
                Article(
                    id: duplicateID,
                    articleKey: "\(feedID.uuidString)|duplicate-\(index)",
                    feedID: feedID,
                    feedTitle: "Example",
                    title: "Duplicate \(index)"
                )
            )
        }
        fixture.context.insert(
            Article(
                articleKey: "\(feedID.uuidString)|unrelated",
                feedID: feedID,
                feedTitle: "Example",
                title: "Unrelated"
            )
        )
        try fixture.context.save()

        let descriptor = FeedPersistenceQueries.articles(id: duplicateID)
        let fetched = try fixture.context.fetch(descriptor)

        #expect(descriptor.fetchLimit == 2)
        #expect(fetched.count == 2)
        #expect(fetched.allSatisfy { $0.id == duplicateID })
    }

    @Test func repeatedRefreshDeduplicatesAndPreservesUserState() async throws {
        let fixture = try TestStore()
        let feed = Feed(
            id: UUID(),
            feedURLString: "https://unit.test/example.xml",
            title: "Example"
        )
        fixture.context.insert(feed)
        try fixture.context.save()

        try await FeedSyncService.refresh(feed, modelContext: fixture.context)
        let firstFetch = try fixture.context.fetch(FetchDescriptor<Article>())
        let article = try #require(firstFetch.first)
        let stableArticleKey = article.articleKey
        #expect(firstFetch.count == 1)

        article.isRead = true
        article.isStarred = true
        article.extractedMarkdown = "# Cached article"
        try fixture.context.save()

        try await FeedSyncService.refresh(feed, modelContext: fixture.context)

        let secondFetch = try fixture.context.fetch(FetchDescriptor<Article>())
        let refreshedArticle = try #require(secondFetch.first)
        #expect(secondFetch.count == 1)
        #expect(refreshedArticle.articleKey == stableArticleKey)
        #expect(refreshedArticle.isRead)
        #expect(refreshedArticle.isStarred)
        #expect(refreshedArticle.extractedMarkdown == "# Cached article")
    }

    @Test func refreshUpdatesServerFieldsAndPreservesUserState() async throws {
        let fixture = try TestStore()
        let feed = Feed(
            id: UUID(),
            feedURLString: "https://unit.test/server-fields.xml",
            title: "Example"
        )
        let articleKey = "\(feed.id.uuidString)|shared-entry-id"
        let readModifiedAt = Date(timeIntervalSince1970: 100)
        let starredModifiedAt = Date(timeIntervalSince1970: 200)
        let extractedModifiedAt = Date(timeIntervalSince1970: 300)
        let article = Article(
            articleKey: articleKey,
            feedID: feed.id,
            feedTitle: feed.title,
            title: "Old title",
            urlString: "https://example.com/old",
            summaryText: "Old summary",
            author: "Old Author",
            publishedAt: Date(timeIntervalSince1970: 1),
            isRead: true,
            isStarred: true,
            extractedMarkdown: "# Cached article",
            readModifiedAt: readModifiedAt,
            starredModifiedAt: starredModifiedAt,
            extractedModifiedAt: extractedModifiedAt
        )
        fixture.context.insert(feed)
        fixture.context.insert(article)
        try fixture.context.save()

        try await FeedSyncService.refresh(feed, modelContext: fixture.context)

        let articles = try fixture.context.fetch(FetchDescriptor<Article>())
        let refreshedArticle = try #require(articles.first)
        let expectedPublishedAt = try #require(
            ISO8601DateFormatter().date(from: "2026-08-13T09:45:00Z")
        )
        #expect(articles.count == 1)
        #expect(refreshedArticle.articleKey == articleKey)
        #expect(refreshedArticle.title == "Updated Article")
        #expect(refreshedArticle.urlString == "https://example.com/article-v2")
        #expect(refreshedArticle.summaryText == "Updated summary")
        #expect(refreshedArticle.author == "Updated Author")
        #expect(refreshedArticle.publishedAt == expectedPublishedAt)
        #expect(refreshedArticle.isRead)
        #expect(refreshedArticle.isStarred)
        #expect(refreshedArticle.extractedMarkdown == "# Cached article")
        #expect(refreshedArticle.readModifiedAt == readModifiedAt)
        #expect(refreshedArticle.starredModifiedAt == starredModifiedAt)
        #expect(refreshedArticle.extractedModifiedAt == extractedModifiedAt)
    }

    @Test func refreshMergesPreexistingDuplicateArticleKeysWithoutCrashing() async throws {
        let fixture = try TestStore()
        let feed = Feed(
            id: UUID(),
            feedURLString: "https://unit.test/example.xml",
            title: "Example"
        )
        let articleKey = "\(feed.id.uuidString)|shared-entry-id"
        let firstArticle = Article(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            articleKey: articleKey,
            feedID: feed.id,
            feedTitle: feed.title,
            title: "First copy",
            isRead: true,
            readModifiedAt: Date(timeIntervalSince1970: 100)
        )
        let secondArticle = Article(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            articleKey: articleKey,
            feedID: feed.id,
            feedTitle: feed.title,
            title: "Second copy",
            isStarred: true,
            extractedMarkdown: "# Cached article",
            starredModifiedAt: Date(timeIntervalSince1970: 200),
            extractedModifiedAt: Date(timeIntervalSince1970: 300)
        )
        fixture.context.insert(feed)
        fixture.context.insert(firstArticle)
        fixture.context.insert(secondArticle)
        try fixture.context.save()

        try await FeedSyncService.refresh(feed, modelContext: fixture.context)

        let articles = try fixture.context.fetch(FetchDescriptor<Article>())
        let mergedArticle = try #require(articles.first)
        #expect(articles.count == 1)
        #expect(mergedArticle.articleKey == articleKey)
        #expect(mergedArticle.title == "Article")
        #expect(mergedArticle.isRead)
        #expect(mergedArticle.isStarred)
        #expect(mergedArticle.extractedMarkdown == "# Cached article")
    }

    @Test func refreshOnlyMutatesTargetFeedArticles() async throws {
        let fixture = try TestStore()
        let targetFeed = Feed(
            id: UUID(),
            feedURLString: "https://unit.test/example.xml",
            title: "Target"
        )
        let otherFeed = Feed(
            id: UUID(),
            feedURLString: "https://unit.test/other.xml",
            title: "Other"
        )
        let targetArticle = Article(
            articleKey: "\(targetFeed.id.uuidString)|shared-entry-id",
            feedID: targetFeed.id,
            feedTitle: targetFeed.title,
            title: "Stale target article"
        )
        let otherArticleKey =
            "\(otherFeed.id.uuidString)|shared-entry-id"
        let firstOtherArticle = Article(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000011"
            )!,
            articleKey: otherArticleKey,
            feedID: otherFeed.id,
            feedTitle: otherFeed.title,
            title: "First other copy",
            isRead: true,
            readModifiedAt: Date(timeIntervalSince1970: 100)
        )
        let secondOtherArticle = Article(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000012"
            )!,
            articleKey: otherArticleKey,
            feedID: otherFeed.id,
            feedTitle: otherFeed.title,
            title: "Second other copy",
            isStarred: true,
            extractedMarkdown: "# Other cached article",
            starredModifiedAt: Date(timeIntervalSince1970: 200),
            extractedModifiedAt: Date(timeIntervalSince1970: 300)
        )
        fixture.context.insert(targetFeed)
        fixture.context.insert(otherFeed)
        fixture.context.insert(targetArticle)
        fixture.context.insert(firstOtherArticle)
        fixture.context.insert(secondOtherArticle)
        try fixture.context.save()

        try await FeedSyncService.refresh(
            targetFeed,
            modelContext: fixture.context
        )

        let articles = try fixture.context.fetch(FetchDescriptor<Article>())
        let refreshedTargetArticles = articles.filter {
            $0.feedID == targetFeed.id
        }
        let untouchedOtherArticles = articles.filter {
            $0.feedID == otherFeed.id
        }
        let persistedFirstOther = try #require(
            untouchedOtherArticles.first { $0.id == firstOtherArticle.id }
        )
        let persistedSecondOther = try #require(
            untouchedOtherArticles.first { $0.id == secondOtherArticle.id }
        )

        #expect(refreshedTargetArticles.count == 1)
        #expect(refreshedTargetArticles.first?.title == "Article")
        #expect(untouchedOtherArticles.count == 2)
        #expect(persistedFirstOther.title == "First other copy")
        #expect(persistedFirstOther.isRead)
        #expect(
            persistedFirstOther.readModifiedAt
                == Date(timeIntervalSince1970: 100)
        )
        #expect(persistedSecondOther.title == "Second other copy")
        #expect(persistedSecondOther.isStarred)
        #expect(persistedSecondOther.extractedMarkdown == "# Other cached article")
        #expect(
            persistedSecondOther.starredModifiedAt
                == Date(timeIntervalSince1970: 200)
        )
        #expect(
            persistedSecondOther.extractedModifiedAt
                == Date(timeIntervalSince1970: 300)
        )
    }

    @Test func sameEntryIdentityIsIsolatedBetweenFeeds() async throws {
        let fixture = try TestStore()
        let firstFeed = Feed(
            id: UUID(),
            feedURLString: "https://unit.test/first.xml",
            title: "First"
        )
        let secondFeed = Feed(
            id: UUID(),
            feedURLString: "https://unit.test/second.xml",
            title: "Second"
        )
        fixture.context.insert(firstFeed)
        fixture.context.insert(secondFeed)
        try fixture.context.save()

        try await FeedSyncService.refresh(firstFeed, modelContext: fixture.context)
        try await FeedSyncService.refresh(secondFeed, modelContext: fixture.context)

        let articles = try fixture.context.fetch(FetchDescriptor<Article>())
        #expect(articles.count == 2)
        #expect(Set(articles.map(\.feedID)) == [firstFeed.id, secondFeed.id])
        #expect(Set(articles.map(\.articleKey)).count == 2)
    }

    @Test func reconciliationMergesDuplicateFeedsAndArticleUserState() async throws {
        let fixture = try TestStore()
        let canonicalFeed = Feed(
            id: UUID(),
            feedURLString: "https://unit.test/duplicate.xml",
            title: "Canonical",
            dateAdded: Date(timeIntervalSince1970: 1)
        )
        let duplicateFeed = Feed(
            id: UUID(),
            feedURLString: "https://unit.test/duplicate.xml",
            title: "Duplicate",
            dateAdded: Date(timeIntervalSince1970: 2)
        )
        fixture.context.insert(canonicalFeed)
        fixture.context.insert(duplicateFeed)
        try fixture.context.save()

        try await FeedSyncService.refresh(
            canonicalFeed,
            modelContext: fixture.context
        )
        try await FeedSyncService.refresh(
            duplicateFeed,
            modelContext: fixture.context
        )

        let articlesBeforeReconciliation = try fixture.context.fetch(
            FetchDescriptor<Article>()
        )
        let canonicalArticle = try #require(
            articlesBeforeReconciliation.first {
                $0.feedID == canonicalFeed.id
            }
        )
        let duplicateArticle = try #require(
            articlesBeforeReconciliation.first {
                $0.feedID == duplicateFeed.id
            }
        )
        canonicalArticle.isRead = true
        canonicalArticle.readModifiedAt = Date(timeIntervalSince1970: 100)
        duplicateArticle.isStarred = true
        duplicateArticle.starredModifiedAt = Date(timeIntervalSince1970: 200)
        duplicateArticle.extractedMarkdown = "# Cached article"
        duplicateArticle.extractedModifiedAt = Date(timeIntervalSince1970: 300)
        try fixture.context.save()

        try CloudDataReconciler.reconcile(in: fixture.context)

        let feeds = try fixture.context.fetch(FetchDescriptor<Feed>())
        let activeFeeds = feeds.filter(\.isActive)
        let articles = try fixture.context.fetch(FetchDescriptor<Article>())
        let mergedFeed = try #require(activeFeeds.first)
        let redirectFeed = try #require(
            feeds.first { $0.id == duplicateFeed.id }
        )
        let mergedArticle = try #require(articles.first)
        #expect(feeds.count == 2)
        #expect(activeFeeds.count == 1)
        #expect(mergedFeed.id == canonicalFeed.id)
        #expect(redirectFeed.deletedAt == nil)
        #expect(redirectFeed.mergedIntoFeedID == canonicalFeed.id)
        #expect(articles.count == 1)
        #expect(mergedArticle.feedID == canonicalFeed.id)
        #expect(mergedArticle.feedTitle == canonicalFeed.title)
        #expect(mergedArticle.isRead)
        #expect(mergedArticle.isStarred)
        #expect(mergedArticle.extractedMarkdown == "# Cached article")
    }

    @Test func reconciliationPreservesArticleWhileItsFeedIsImporting() throws {
        let fixture = try TestStore()
        let pendingFeedID = UUID()
        let article = Article(
            articleKey: "\(pendingFeedID.uuidString)|pending-entry",
            feedID: pendingFeedID,
            feedTitle: "Pending Feed",
            title: "Pending Article"
        )
        fixture.context.insert(article)
        try fixture.context.save()

        try CloudDataReconciler.reconcile(in: fixture.context)

        let articles = try fixture.context.fetch(FetchDescriptor<Article>())
        #expect(articles.count == 1)
        #expect(articles.first?.articleKey == article.articleKey)
    }

    @Test func reconciliationUsesFeedIDAsDeterministicTieBreaker() throws {
        let fixture = try TestStore()
        let dateAdded = Date(timeIntervalSince1970: 1)
        let higherID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let lowerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        fixture.context.insert(
            Feed(
                id: higherID,
                feedURLString: "https://unit.test/tie.xml",
                title: "Higher",
                dateAdded: dateAdded
            )
        )
        fixture.context.insert(
            Feed(
                id: lowerID,
                feedURLString: "https://unit.test/tie.xml",
                title: "Lower",
                dateAdded: dateAdded
            )
        )
        try fixture.context.save()

        try CloudDataReconciler.reconcile(in: fixture.context)

        let feeds = try fixture.context.fetch(FetchDescriptor<Feed>())
        let activeFeeds = feeds.filter(\.isActive)
        let redirectFeed = feeds.first { $0.id == higherID }
        #expect(feeds.count == 2)
        #expect(activeFeeds.count == 1)
        #expect(activeFeeds.first?.id == lowerID)
        #expect(redirectFeed?.deletedAt == nil)
        #expect(redirectFeed?.mergedIntoFeedID == lowerID)
    }

    @Test func persistenceServiceRollsBackWhenChangesThrow() throws {
        let fixture = try TestStore()
        let feed = Feed(
            feedURLString: "https://unit.test/rollback.xml",
            title: "Original"
        )
        fixture.context.insert(feed)
        try fixture.context.save()

        do {
            try PersistenceService.save(in: fixture.context) {
                feed.title = "Changed"
                fixture.context.insert(
                    Article(
                        articleKey: "\(feed.id.uuidString)|rolled-back-entry",
                        feedID: feed.id,
                        feedTitle: feed.title,
                        title: "Should Not Persist"
                    )
                )
                throw PersistenceTestError.intentional
            }
            Issue.record("Expected PersistenceService.save to throw")
        } catch PersistenceTestError.intentional {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let feeds = try fixture.context.fetch(FetchDescriptor<Feed>())
        let articles = try fixture.context.fetch(FetchDescriptor<Article>())
        #expect(!fixture.context.hasChanges)
        #expect(feeds.count == 1)
        #expect(feeds.first?.title == "Original")
        #expect(articles.isEmpty)
    }

    @Test func articleStateWritesUseAnIsolatedContext() throws {
        let fixture = try TestStore()
        let feed = Feed(
            feedURLString: "https://unit.test/state.xml",
            title: "State"
        )
        let article = Article(
            articleKey: "\(feed.id.uuidString)|state-entry",
            feedID: feed.id,
            feedTitle: feed.title,
            title: "State Article"
        )
        fixture.context.insert(feed)
        fixture.context.insert(article)
        try fixture.context.save()

        let changedAt = Date(timeIntervalSince1970: 500)
        try FeedSyncService.updateReadState(
            articleID: article.id,
            isRead: true,
            modifiedAt: changedAt,
            modelContainer: fixture.container
        )
        try FeedSyncService.updateStarredState(
            articleID: article.id,
            isStarred: true,
            modifiedAt: changedAt,
            modelContainer: fixture.container
        )
        try FeedSyncService.saveExtractedMarkdown(
            "# Extracted",
            articleID: article.id,
            modifiedAt: changedAt,
            modelContainer: fixture.container
        )

        fixture.context.rollback()
        let articles = try fixture.context.fetch(FetchDescriptor<Article>())
        let persisted = try #require(articles.first)
        #expect(persisted.isRead)
        #expect(persisted.isStarred)
        #expect(persisted.extractedMarkdown == "# Extracted")
        #expect(persisted.readModifiedAt == changedAt)
        #expect(persisted.starredModifiedAt == changedAt)
        #expect(persisted.extractedModifiedAt == changedAt)
    }

    @Test func reconciliationRepairsDuplicateArticleIDsIdempotently() throws {
        let fixture = try TestStore()
        let feed = Feed(
            feedURLString: "https://unit.test/legacy.xml",
            title: "Legacy"
        )
        let migratedDefaultID = UUID()
        let first = Article(
            id: migratedDefaultID,
            articleKey: "\(feed.id.uuidString)|first",
            feedID: feed.id,
            feedTitle: feed.title,
            title: "First"
        )
        let second = Article(
            id: migratedDefaultID,
            articleKey: "\(feed.id.uuidString)|second",
            feedID: feed.id,
            feedTitle: feed.title,
            title: "Second"
        )
        fixture.context.insert(feed)
        fixture.context.insert(first)
        fixture.context.insert(second)
        try fixture.context.save()

        try CloudDataReconciler.reconcile(in: fixture.context)

        let repaired = try fixture.context.fetch(FetchDescriptor<Article>())
        let repairedIDs = repaired.map(\.id)
        #expect(repaired.count == 2)
        #expect(Set(repairedIDs).count == 2)
        #expect(repairedIDs.contains(migratedDefaultID))

        try CloudDataReconciler.reconcile(in: fixture.context)
        let secondPass = try fixture.context.fetch(FetchDescriptor<Article>())
        #expect(Set(secondPass.map(\.id)) == Set(repairedIDs))
    }

    @Test func changingFeedURLCreatesANewIdentityAndTombstonesTheOldFeed() async throws {
        let fixture = try TestStore()
        let oldFeed = Feed(
            feedURLString: "https://unit.test/old.xml",
            title: "Old Feed"
        )
        let oldArticle = Article(
            articleKey: "\(oldFeed.id.uuidString)|old-entry",
            feedID: oldFeed.id,
            feedTitle: oldFeed.title,
            title: "Old Article"
        )
        fixture.context.insert(oldFeed)
        fixture.context.insert(oldArticle)
        try fixture.context.save()
        let replacementURL = try #require(
            URL(string: "https://unit.test/replacement.xml")
        )

        let updatedFeed = try await FeedSyncService.updateFeed(
            oldFeed,
            title: "Replacement Feed",
            url: replacementURL,
            automaticallyExtractsArticleContent: true,
            modelContext: fixture.context
        )

        let feeds = try fixture.context.fetch(FetchDescriptor<Feed>())
        let articles = try fixture.context.fetch(FetchDescriptor<Article>())
        #expect(updatedFeed.id != oldFeed.id)
        #expect(updatedFeed.isActive)
        #expect(updatedFeed.feedURLString == replacementURL.absoluteString)
        #expect(updatedFeed.automaticallyExtractsArticleContent)
        #expect(oldFeed.deletedAt != nil)
        #expect(feeds.filter(\.isActive).map(\.id) == [updatedFeed.id])
        #expect(articles.count == 1)
        #expect(articles.first?.feedID == updatedFeed.id)
        #expect(articles.first?.title == "Article")

        let restoredFeed = try await FeedSyncService.updateFeed(
            updatedFeed,
            title: "Restored Feed",
            url: try #require(URL(string: oldFeed.feedURLString)),
            automaticallyExtractsArticleContent: false,
            modelContext: fixture.context
        )
        try CloudDataReconciler.reconcile(in: fixture.context)

        let reconciledFeeds = try fixture.context.fetch(
            FetchDescriptor<Feed>()
        )
        #expect(restoredFeed.id != updatedFeed.id)
        #expect(restoredFeed.isActive)
        #expect(restoredFeed.dateAdded > oldFeed.dateAdded)
        #expect(reconciledFeeds.filter(\.isActive).map(\.id) == [restoredFeed.id])
    }
}

private enum PersistenceTestError: Error {
    case intentional
}

@MainActor
private final class TestStore {
    let container: ModelContainer

    var context: ModelContext { container.mainContext }

    init() throws {
        URLProtocol.registerClass(TestFeedURLProtocol.self)
        let schema = Schema([Feed.self, Article.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
    }

    deinit {
        URLProtocol.unregisterClass(TestFeedURLProtocol.self)
    }
}

private final class TestFeedURLProtocol: URLProtocol {
    private static let responseData = Data(
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Example</title>
            <link>https://example.com</link>
            <item>
              <guid>shared-entry-id</guid>
              <title>Article</title>
              <link>https://example.com/article</link>
              <description>Summary</description>
            </item>
          </channel>
        </rss>
        """.utf8
    )

    private static let serverFieldsResponseData = Data(
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Updated Feed</title>
            <link>https://example.com</link>
            <description>Updated feed summary</description>
            <item>
              <guid>shared-entry-id</guid>
              <title>Updated Article</title>
              <link>https://example.com/article-v2</link>
              <description>Updated summary</description>
              <author>Updated Author</author>
              <pubDate>Thu, 13 Aug 2026 09:45:00 +0000</pubDate>
            </item>
          </channel>
        </rss>
        """.utf8
    )

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "unit.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/rss+xml"]
            )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }

        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        let data = url.path == "/server-fields.xml"
            ? Self.serverFieldsResponseData
            : Self.responseData
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
