import Foundation
import SwiftData
import Testing
@testable import feeds

@Suite(.serialized)
@MainActor
struct CloudDataReconcilerLifecycleTests {
    @Test func duplicateFeedRedirectsCurrentAndLateArticles() throws {
        let fixture = try ReconcilerTestStore()
        let canonicalID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        )!
        let duplicateID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000002"
        )!
        let canonical = Feed(
            id: canonicalID,
            feedURLString: "https://unit.test/feed.xml",
            title: "Canonical",
            dateAdded: Date(timeIntervalSince1970: 1)
        )
        let duplicate = Feed(
            id: duplicateID,
            feedURLString: "https://unit.test/feed.xml",
            title: "Duplicate",
            dateAdded: Date(timeIntervalSince1970: 2)
        )
        let firstArticle = Article(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000010"
            )!,
            articleKey: "\(duplicateID.uuidString)|entry",
            feedID: duplicateID,
            feedTitle: duplicate.title,
            title: "Article",
            savedAt: Date(timeIntervalSince1970: 1)
        )
        fixture.context.insert(canonical)
        fixture.context.insert(duplicate)
        fixture.context.insert(firstArticle)
        try fixture.context.save()

        try CloudDataReconciler.reconcile(in: fixture.context)

        #expect(canonical.isActive)
        #expect(!duplicate.isActive)
        #expect(duplicate.mergedIntoFeedID == canonicalID)
        #expect(firstArticle.feedID == canonicalID)
        #expect(
            firstArticle.articleKey == "\(canonicalID.uuidString)|entry"
        )

        let lateArticle = Article(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000020"
            )!,
            articleKey: "\(duplicateID.uuidString)|entry",
            feedID: duplicateID,
            feedTitle: duplicate.title,
            title: "Late duplicate",
            savedAt: Date(timeIntervalSince1970: 2)
        )
        fixture.context.insert(lateArticle)
        try fixture.context.save()

        try CloudDataReconciler.reconcile(in: fixture.context)

        let feeds = try fixture.context.fetch(FetchDescriptor<Feed>())
        let articles = try fixture.context.fetch(FetchDescriptor<Article>())
        #expect(feeds.count == 2)
        #expect(articles.count == 1)
        #expect(articles.first?.id == firstArticle.id)
        #expect(articles.first?.feedID == canonicalID)
        #expect(articles.first?.title == "Late duplicate")
    }

    @Test func tombstoneRejectsStaleCopiesAndAllowsResubscription() throws {
        let fixture = try ReconcilerTestStore()
        let deletionDate = Date(timeIntervalSince1970: 20)
        let deleted = Feed(
            feedURLString: "HTTPS://UNIT.TEST/feed/",
            title: "Deleted",
            dateAdded: Date(timeIntervalSince1970: 10),
            deletedAt: deletionDate
        )
        let stale = Feed(
            feedURLString: "https://unit.test/feed",
            title: "Stale copy",
            dateAdded: Date(timeIntervalSince1970: 15)
        )
        let renewed = Feed(
            feedURLString: "https://unit.test:443/feed#latest",
            title: "Renewed",
            dateAdded: Date(timeIntervalSince1970: 21)
        )

        let deletedArticle = makeArticle(for: deleted, remoteID: "deleted")
        let staleArticle = makeArticle(for: stale, remoteID: "stale")
        let renewedArticle = makeArticle(for: renewed, remoteID: "renewed")
        fixture.context.insert(deleted)
        fixture.context.insert(stale)
        fixture.context.insert(renewed)
        fixture.context.insert(deletedArticle)
        fixture.context.insert(staleArticle)
        fixture.context.insert(renewedArticle)
        try fixture.context.save()

        try CloudDataReconciler.reconcile(in: fixture.context)

        #expect(deleted.deletedAt == deletionDate)
        #expect(stale.deletedAt == deletionDate)
        #expect(!stale.isActive)
        #expect(renewed.isActive)
        var articles = try fixture.context.fetch(FetchDescriptor<Article>())
        #expect(articles.count == 1)
        #expect(articles.first?.feedID == renewed.id)

        let lateArticle = makeArticle(for: stale, remoteID: "late")
        fixture.context.insert(lateArticle)
        try fixture.context.save()
        try CloudDataReconciler.reconcile(in: fixture.context)

        articles = try fixture.context.fetch(FetchDescriptor<Article>())
        #expect(articles.count == 1)
        #expect(articles.first?.feedID == renewed.id)
    }

    @Test func articleFieldsMergeIndependentlyWithoutChangingSavedAt() throws {
        let fixture = try ReconcilerTestStore()
        let feed = Feed(
            feedURLString: "https://unit.test/feed.xml",
            title: "Feed"
        )
        let lowerID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        )!
        let higherID = UUID(
            uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
        )!
        let originalSavedAt = Date(timeIntervalSince1970: 1)
        let canonical = Article(
            id: lowerID,
            articleKey: "\(feed.id.uuidString)|entry",
            feedID: feed.id,
            feedTitle: feed.title,
            title: "Old title",
            savedAt: originalSavedAt,
            isRead: true,
            isStarred: false,
            extractedMarkdown: "# Old extraction",
            readModifiedAt: Date(timeIntervalSince1970: 10),
            starredModifiedAt: Date(timeIntervalSince1970: 30),
            extractedModifiedAt: Date(timeIntervalSince1970: 10)
        )
        let duplicate = Article(
            id: higherID,
            articleKey: canonical.articleKey,
            feedID: feed.id,
            feedTitle: feed.title,
            title: "New title",
            savedAt: Date(timeIntervalSince1970: 2),
            isRead: false,
            isStarred: true,
            extractedMarkdown: nil,
            readModifiedAt: Date(timeIntervalSince1970: 20),
            starredModifiedAt: Date(timeIntervalSince1970: 30),
            extractedModifiedAt: Date(timeIntervalSince1970: 20)
        )
        fixture.context.insert(feed)
        fixture.context.insert(canonical)
        fixture.context.insert(duplicate)
        try fixture.context.save()

        try CloudDataReconciler.reconcile(in: fixture.context)

        let articles = try fixture.context.fetch(FetchDescriptor<Article>())
        let merged = try #require(articles.first)
        #expect(articles.count == 1)
        #expect(merged.id == lowerID)
        #expect(merged.title == "New title")
        #expect(merged.savedAt == originalSavedAt)
        #expect(!merged.isRead)
        #expect(merged.isStarred)
        #expect(merged.extractedMarkdown == nil)
        #expect(
            merged.readModifiedAt == Date(timeIntervalSince1970: 20)
        )
        #expect(
            merged.starredModifiedAt == Date(timeIntervalSince1970: 30)
        )
        #expect(
            merged.extractedModifiedAt == Date(timeIntervalSince1970: 20)
        )
    }

    @Test func newerFalseFeedSettingsWinDuringReconciliation() throws {
        let fixture = try ReconcilerTestStore()
        let older = Feed(
            feedURLString: "https://unit.test/settings.xml",
            title: "Older Title",
            dateAdded: Date(timeIntervalSince1970: 1),
            automaticallyExtractsArticleContent: true,
            settingsModifiedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = Feed(
            feedURLString: "https://unit.test/settings.xml",
            title: "Newer Title",
            dateAdded: Date(timeIntervalSince1970: 2),
            automaticallyExtractsArticleContent: false,
            settingsModifiedAt: Date(timeIntervalSince1970: 20)
        )
        fixture.context.insert(older)
        fixture.context.insert(newer)
        try fixture.context.save()

        try CloudDataReconciler.reconcile(in: fixture.context)

        #expect(older.isActive)
        #expect(older.title == "Newer Title")
        #expect(!older.automaticallyExtractsArticleContent)
        #expect(older.settingsModifiedAt == Date(timeIntervalSince1970: 20))
        #expect(newer.mergedIntoFeedID == older.id)
    }

    private func makeArticle(
        for feed: Feed,
        remoteID: String
    ) -> Article {
        Article(
            articleKey: "\(feed.id.uuidString)|\(remoteID)",
            feedID: feed.id,
            feedTitle: feed.title,
            title: remoteID
        )
    }
}

@MainActor
private final class ReconcilerTestStore {
    let container: ModelContainer

    var context: ModelContext { container.mainContext }

    init() throws {
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
        context.autosaveEnabled = false
    }
}
