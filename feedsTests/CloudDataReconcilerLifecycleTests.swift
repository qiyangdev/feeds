import Foundation
import SwiftData
import Testing
@testable import feeds

@Suite(.serialized)
@MainActor
struct CloudDataReconcilerLifecycleTests {
    @Test func backgroundDetectionDoesNotWriteAndCachesOnlyCleanState() async throws {
        let fixture = try ReconcilerTestStore()
        let canonicalID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000101"
        )!
        let duplicateID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000102"
        )!
        let canonical = Feed(
            id: canonicalID,
            feedURLString: "https://unit.test/background.xml",
            title: "Canonical",
            dateAdded: Date(timeIntervalSince1970: 1),
            settingsModifiedAt: Date(timeIntervalSince1970: 10)
        )
        let duplicate = Feed(
            id: duplicateID,
            feedURLString: "https://unit.test/background.xml",
            title: "Duplicate",
            dateAdded: Date(timeIntervalSince1970: 2),
            settingsModifiedAt: Date(timeIntervalSince1970: 20)
        )
        let canonicalArticle = Article(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000111"
            )!,
            articleKey: "\(canonicalID.uuidString)|shared-entry",
            feedID: canonicalID,
            feedTitle: canonical.title,
            title: "Canonical article",
            isRead: true,
            readModifiedAt: Date(timeIntervalSince1970: 100)
        )
        let duplicateArticle = Article(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000112"
            )!,
            articleKey: "\(duplicateID.uuidString)|shared-entry",
            feedID: duplicateID,
            feedTitle: duplicate.title,
            title: "Duplicate article",
            isStarred: true,
            starredModifiedAt: Date(timeIntervalSince1970: 200)
        )
        fixture.context.insert(canonical)
        fixture.context.insert(duplicate)
        fixture.context.insert(canonicalArticle)
        fixture.context.insert(duplicateArticle)
        try fixture.context.save()

        let detectionContext = ModelContext(fixture.container)
        detectionContext.autosaveEnabled = false
        #expect(
            try CloudDataReconciler.needsReconciliation(
                in: detectionContext
            )
        )

        // Detection mutates only its private context and rolls it back. The
        // durable store is unchanged until the main actor applies the repair.
        let preApplyContext = ModelContext(fixture.container)
        #expect(
            try preApplyContext.fetch(FetchDescriptor<Feed>()).count == 2
        )
        #expect(
            try preApplyContext.fetch(FetchDescriptor<Article>()).count == 2
        )

        let controller = CloudDataReconciliationController()
        try await controller.reconcileIfNeeded(in: fixture.container)
        #expect(await controller.appliedPassCountForTesting() == 1)
        try await controller.reconcileIfNeeded(in: fixture.container)
        #expect(await controller.appliedPassCountForTesting() == 1)

        let firstVerificationContext = ModelContext(fixture.container)
        firstVerificationContext.autosaveEnabled = false
        let firstPassFeeds = try firstVerificationContext.fetch(
            FetchDescriptor<Feed>()
        )
        let firstPassArticles = try firstVerificationContext.fetch(
            FetchDescriptor<Article>()
        )
        let firstPassCanonical = try #require(
            firstPassFeeds.first { $0.id == canonicalID }
        )
        let firstPassDuplicate = try #require(
            firstPassFeeds.first { $0.id == duplicateID }
        )
        let mergedArticle = try #require(firstPassArticles.first)

        #expect(firstPassFeeds.count == 2)
        #expect(firstPassCanonical.isActive)
        #expect(firstPassCanonical.title == "Duplicate")
        #expect(firstPassDuplicate.mergedIntoFeedID == canonicalID)
        #expect(firstPassArticles.count == 1)
        #expect(mergedArticle.feedID == canonicalID)
        #expect(
            mergedArticle.articleKey
                == "\(canonicalID.uuidString)|shared-entry"
        )
        #expect(mergedArticle.isRead)
        #expect(mergedArticle.isStarred)

        firstPassCanonical.lastError = "Edited after reconciliation"
        try firstVerificationContext.save()

        try await controller.reconcileIfNeeded(in: fixture.container)
        #expect(await controller.appliedPassCountForTesting() == 1)

        let secondVerificationContext = ModelContext(fixture.container)
        let secondPassFeeds = try secondVerificationContext.fetch(
            FetchDescriptor<Feed>()
        )
        let secondPassArticles = try secondVerificationContext.fetch(
            FetchDescriptor<Article>()
        )
        let secondPassCanonical = try #require(
            secondPassFeeds.first { $0.id == canonicalID }
        )

        #expect(secondPassFeeds.count == 2)
        #expect(
            secondPassCanonical.lastError == "Edited after reconciliation"
        )
        #expect(
            secondPassFeeds.first { $0.id == duplicateID }?.mergedIntoFeedID
                == canonicalID
        )
        #expect(secondPassArticles.count == 1)
        #expect(secondPassArticles.first?.id == mergedArticle.id)
        #expect(secondPassArticles.first?.feedID == canonicalID)
    }

    @Test func concurrentRequestsShareOneMainContextRepair() async throws {
        let fixture = try ReconcilerTestStore()
        let canonicalID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000201"
        )!
        let duplicateID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000202"
        )!
        fixture.context.insert(
            Feed(
                id: canonicalID,
                feedURLString: "https://unit.test/single-flight.xml",
                title: "Canonical",
                dateAdded: Date(timeIntervalSince1970: 1)
            )
        )
        fixture.context.insert(
            Feed(
                id: duplicateID,
                feedURLString: "https://unit.test/single-flight.xml",
                title: "Duplicate",
                dateAdded: Date(timeIntervalSince1970: 2)
            )
        )
        try fixture.context.save()

        let controller = CloudDataReconciliationController()
        let container = fixture.container
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    try await controller.reconcileIfNeeded(
                        in: container
                    )
                }
            }
            try await group.waitForAll()
        }

        #expect(await controller.appliedPassCountForTesting() == 1)
        let verificationContext = ModelContext(fixture.container)
        let feeds = try verificationContext.fetch(FetchDescriptor<Feed>())
        #expect(feeds.filter(\.isActive).map(\.id) == [canonicalID])
        #expect(
            feeds.first { $0.id == duplicateID }?.mergedIntoFeedID
                == canonicalID
        )
    }

    @Test func requestArrivingAfterCleanScanForcesFollowUpDetection() async throws {
        let fixture = try ReconcilerTestStore()
        let canonicalID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000301"
        )!
        let duplicateID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000302"
        )!
        let feedURL = "https://unit.test/mid-flight-import.xml"
        fixture.context.insert(
            Feed(
                id: canonicalID,
                feedURLString: feedURL,
                title: "Canonical",
                dateAdded: Date(timeIntervalSince1970: 1)
            )
        )
        try fixture.context.save()

        let gate = ReconciliationSuspensionGate()
        let controller = CloudDataReconciliationController {
            await gate.suspend()
        }
        let container = fixture.container
        let initialRequest = Task {
            try await controller.reconcileIfNeeded(in: container)
        }
        await gate.waitUntilSuspended()

        // Simulate a CloudKit import after the first flight's final clean scan
        // but before that flight is settled by the controller actor.
        fixture.context.insert(
            Feed(
                id: duplicateID,
                feedURLString: feedURL,
                title: "Imported duplicate",
                dateAdded: Date(timeIntervalSince1970: 2)
            )
        )
        try fixture.context.save()
        let importRequest = Task {
            try await controller.reconcileIfNeeded(in: container)
        }
        while await controller.requestGenerationForTesting() < 2 {
            await Task.yield()
        }
        await gate.resume()

        try await initialRequest.value
        try await importRequest.value
        #expect(await controller.appliedPassCountForTesting() == 1)

        let verificationContext = ModelContext(container)
        let feeds = try verificationContext.fetch(FetchDescriptor<Feed>())
        #expect(feeds.filter(\.isActive).map(\.id) == [canonicalID])
        #expect(
            feeds.first { $0.id == duplicateID }?.mergedIntoFeedID
                == canonicalID
        )
    }

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

private actor ReconciliationSuspensionGate {
    private var isSuspended = false
    private var isReleased = false
    private var arrivalContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        isSuspended = true
        arrivalContinuation?.resume()
        arrivalContinuation = nil
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            arrivalContinuation = continuation
        }
    }

    func resume() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
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
