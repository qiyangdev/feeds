import Foundation
import SwiftData
import Testing
@testable import feeds

@Suite(.serialized)
@MainActor
struct FeedQueryPerformanceTests {
    @Test func restoredArticlePredicateReturnsOnlyResolutionCandidates() throws {
        let fixture = try QueryTestStore()
        let originalFeedID = UUID()
        let redirectedFeedID = UUID()
        let exactID = UUID()
        let reference = StoredArticleReference(
            id: exactID,
            key: "\(originalFeedID.uuidString)|shared-entry",
            feedID: originalFeedID
        )
        let exactKey = Article(
            articleKey: reference.key,
            feedID: originalFeedID,
            feedTitle: "Original",
            title: "Exact key"
        )
        let exactLegacyID = Article(
            id: exactID,
            articleKey: "\(originalFeedID.uuidString)|legacy-entry",
            feedID: originalFeedID,
            feedTitle: "Original",
            title: "Exact legacy ID"
        )
        let redirectedRemoteID = Article(
            articleKey: "\(redirectedFeedID.uuidString)|shared-entry",
            feedID: redirectedFeedID,
            feedTitle: "Redirected",
            title: "Redirected remote ID"
        )
        let unrelated = Article(
            articleKey: "\(redirectedFeedID.uuidString)|other-entry",
            feedID: redirectedFeedID,
            feedTitle: "Redirected",
            title: "Unrelated"
        )
        for article in [
            exactKey,
            exactLegacyID,
            redirectedRemoteID,
            unrelated,
        ] {
            fixture.context.insert(article)
        }
        try fixture.context.save()

        let candidates = try fixture.context.fetch(
            FetchDescriptor<Article>(
                predicate: FeedPersistenceQueries.restoredArticlePredicate(
                    reference: reference,
                    candidateArticleKeys: [
                        reference.key,
                        redirectedRemoteID.articleKey,
                    ]
                )
            )
        )
        let noReferenceCandidates = try fixture.context.fetch(
            FetchDescriptor<Article>(
                predicate: FeedPersistenceQueries.restoredArticlePredicate(
                    reference: nil,
                    candidateArticleKeys: [reference.key]
                )
            )
        )

        #expect(
            Set(candidates.map(\.id))
                == [exactKey.id, exactLegacyID.id, redirectedRemoteID.id]
        )
        #expect(!candidates.contains { $0.id == unrelated.id })
        #expect(noReferenceCandidates.isEmpty)
    }

    @Test func articleKeyQueryStaysWithinScopedFeedIDs() throws {
        let fixture = try QueryTestStore()
        let activeFeedID = UUID()
        let outOfScopeFeedID = UUID()
        let targetKey = "\(activeFeedID.uuidString)|shared-entry"
        let firstScoped = Article(
            articleKey: targetKey,
            feedID: activeFeedID,
            feedTitle: "Active",
            title: "First scoped copy"
        )
        let secondScoped = Article(
            articleKey: targetKey,
            feedID: activeFeedID,
            feedTitle: "Active",
            title: "Second scoped copy"
        )
        let sameKeyOutOfScope = Article(
            articleKey: targetKey,
            feedID: outOfScopeFeedID,
            feedTitle: "Out of scope",
            title: "Same key outside the active feeds"
        )
        let differentKeyInScope = Article(
            articleKey: "\(activeFeedID.uuidString)|other-entry",
            feedID: activeFeedID,
            feedTitle: "Active",
            title: "Different key in scope"
        )
        for article in [
            firstScoped,
            secondScoped,
            sameKeyOutOfScope,
            differentKeyInScope,
        ] {
            fixture.context.insert(article)
        }
        try fixture.context.save()

        let descriptor = FeedPersistenceQueries.articles(
            articleKey: targetKey,
            feedIDs: [activeFeedID]
        )
        let matches = try fixture.context.fetch(descriptor)

        #expect(descriptor.fetchLimit == 2)
        #expect(Set(matches.map(\.id)) == [firstScoped.id, secondScoped.id])
        #expect(matches.allSatisfy { $0.feedID == activeFeedID })
        #expect(matches.allSatisfy { $0.articleKey == targetKey })
    }

    @Test func articlePredicatePreservesListFilteringSemantics() throws {
        let fixture = try QueryTestStore()
        let firstFeedID = UUID()
        let secondFeedID = UUID()
        let orphanFeedID = UUID()

        let unread = Article(
            articleKey: "\(firstFeedID.uuidString)|unread",
            feedID: firstFeedID,
            feedTitle: "First",
            title: "Matching unread article",
            publishedAt: Date(timeIntervalSince1970: 10)
        )
        let selectedRead = Article(
            articleKey: "\(firstFeedID.uuidString)|selected",
            feedID: firstFeedID,
            feedTitle: "First",
            title: "Selected article",
            publishedAt: Date(timeIntervalSince1970: 20),
            isRead: true
        )
        let otherRead = Article(
            articleKey: "\(firstFeedID.uuidString)|read",
            feedID: firstFeedID,
            feedTitle: "First",
            title: "Matching read article",
            publishedAt: Date(timeIntervalSince1970: 30),
            isRead: true
        )
        let secondFeedArticle = Article(
            articleKey: "\(secondFeedID.uuidString)|second",
            feedID: secondFeedID,
            feedTitle: "Second",
            title: "Matching second-feed article",
            publishedAt: Date(timeIntervalSince1970: 40)
        )
        let orphanArticle = Article(
            articleKey: "\(orphanFeedID.uuidString)|orphan",
            feedID: orphanFeedID,
            feedTitle: "Orphan",
            title: "Matching orphan article",
            publishedAt: Date(timeIntervalSince1970: 50)
        )

        for article in [
            unread,
            selectedRead,
            otherRead,
            secondFeedArticle,
            orphanArticle,
        ] {
            fixture.context.insert(article)
        }
        try fixture.context.save()

        let selectedDescriptor = descriptor(
            feedIDs: [firstFeedID],
            hidesReadArticles: true,
            selectedArticleKey: selectedRead.articleKey,
            searchText: ""
        )
        let selectedResults = try fixture.context.fetch(selectedDescriptor)
        #expect(
            selectedResults.map(\.articleKey)
                == [selectedRead.articleKey, unread.articleKey]
        )

        let searchDescriptor = descriptor(
            feedIDs: [firstFeedID],
            hidesReadArticles: true,
            selectedArticleKey: selectedRead.articleKey,
            searchText: "Matching"
        )
        let searchResults = try fixture.context.fetch(searchDescriptor)
        #expect(searchResults.map(\.articleKey) == [unread.articleKey])

        let allActiveDescriptor = descriptor(
            feedIDs: [firstFeedID, secondFeedID],
            hidesReadArticles: false,
            selectedArticleKey: nil,
            searchText: ""
        )
        let allActiveResults = try fixture.context.fetch(allActiveDescriptor)
        #expect(
            allActiveResults.map(\.articleKey)
                == [
                    secondFeedArticle.articleKey,
                    otherRead.articleKey,
                    selectedRead.articleKey,
                    unread.articleKey,
                ]
        )
    }

    @Test func articlePageDescriptorBoundsTheInitialResultSet() throws {
        let fixture = try QueryTestStore()
        let feedID = UUID()
        for index in 0..<125 {
            fixture.context.insert(
                Article(
                    articleKey: "\(feedID.uuidString)|\(index)",
                    feedID: feedID,
                    feedTitle: "Feed",
                    title: "Article \(index)",
                    publishedAt: Date(timeIntervalSince1970: Double(index))
                )
            )
        }
        try fixture.context.save()

        let descriptor = FeedPersistenceQueries.articlePage(
            feedIDs: [feedID],
            hidesReadArticles: false,
            selectedArticleKey: nil,
            searchText: "",
            fetchLimit: 100
        )
        let articles = try fixture.context.fetch(descriptor)

        #expect(descriptor.fetchLimit == 100)
        #expect(articles.count == 100)
        #expect(articles.first?.publishedAt == Date(timeIntervalSince1970: 124))
        #expect(articles.last?.publishedAt == Date(timeIntervalSince1970: 25))
    }

    @Test func articlePageDoesNotLetSelectedReadArticleDisplaceUnread() throws {
        let fixture = try QueryTestStore()
        let feedID = UUID()
        let selectedRead = Article(
            articleKey: "\(feedID.uuidString)|selected-read",
            feedID: feedID,
            feedTitle: "Feed",
            title: "Selected read",
            publishedAt: Date(timeIntervalSince1970: 10_000),
            isRead: true
        )
        fixture.context.insert(selectedRead)
        for index in 0..<101 {
            fixture.context.insert(
                Article(
                    articleKey: "\(feedID.uuidString)|unread-\(index)",
                    feedID: feedID,
                    feedTitle: "Feed",
                    title: "Unread \(index)",
                    publishedAt: Date(timeIntervalSince1970: Double(index))
                )
            )
        }
        try fixture.context.save()

        let page = try fixture.context.fetch(
            FeedPersistenceQueries.articlePage(
                feedIDs: [feedID],
                hidesReadArticles: true,
                selectedArticleKey: nil,
                searchText: "",
                fetchLimit: 100
            )
        )

        #expect(page.count == 100)
        #expect(page.allSatisfy { !$0.isRead })
        #expect(!page.contains { $0.id == selectedRead.id })
    }

    @Test func subscriptionCountsUseOneActiveArticleSnapshot() {
        let firstFeedID = UUID()
        let secondFeedID = UUID()
        let inactiveFeedID = UUID()
        let articles = [
            makeArticle(feedID: firstFeedID, remoteID: "unread"),
            makeArticle(feedID: firstFeedID, remoteID: "read", isRead: true),
            makeArticle(feedID: secondFeedID, remoteID: "second"),
            makeArticle(feedID: inactiveFeedID, remoteID: "inactive"),
        ]

        let counts = SubscriptionArticleCounts(
            articles: articles,
            activeFeedIDs: [firstFeedID, secondFeedID]
        )

        #expect(counts.total == 3)
        #expect(counts.unreadCount(for: firstFeedID) == 1)
        #expect(counts.unreadCount(for: secondFeedID) == 1)
        #expect(counts.unreadCount(for: inactiveFeedID) == 0)
    }

    @Test func asyncSubscriptionCountsScopeAndRefreshPersistedState() async throws {
        let fixture = try QueryTestStore()
        let firstFeedID = UUID()
        let secondFeedID = UUID()
        let inactiveFeedID = UUID()
        let orphanFeedID = UUID()
        let firstUnread = makeArticle(
            feedID: firstFeedID,
            remoteID: "first-unread"
        )
        let articles = [
            firstUnread,
            makeArticle(
                feedID: firstFeedID,
                remoteID: "first-read",
                isRead: true
            ),
            makeArticle(feedID: secondFeedID, remoteID: "second-unread"),
            makeArticle(feedID: inactiveFeedID, remoteID: "inactive"),
            makeArticle(feedID: orphanFeedID, remoteID: "orphan"),
        ]
        for article in articles {
            fixture.context.insert(article)
        }
        try fixture.context.save()

        let controller = SubscriptionArticleCountController()
        let activeFeedIDs = [firstFeedID, secondFeedID]
        let initialCounts = try await controller.counts(
            in: fixture.container,
            activeFeedIDs: activeFeedIDs
        )

        #expect(initialCounts.total == 3)
        #expect(initialCounts.unreadCount(for: firstFeedID) == 1)
        #expect(initialCounts.unreadCount(for: secondFeedID) == 1)
        #expect(initialCounts.unreadCount(for: inactiveFeedID) == 0)
        #expect(initialCounts.unreadCount(for: orphanFeedID) == 0)

        firstUnread.isRead = true
        try fixture.context.save()

        let refreshedCounts = try await controller.counts(
            in: fixture.container,
            activeFeedIDs: activeFeedIDs
        )
        let emptyCounts = try await controller.counts(
            in: fixture.container,
            activeFeedIDs: []
        )

        #expect(refreshedCounts.total == 3)
        #expect(refreshedCounts.unreadCount(for: firstFeedID) == 0)
        #expect(refreshedCounts.unreadCount(for: secondFeedID) == 1)
        #expect(emptyCounts.total == 0)
        #expect(emptyCounts.unreadCount(for: firstFeedID) == 0)
        #expect(emptyCounts.unreadCount(for: secondFeedID) == 0)
    }

    private func descriptor(
        feedIDs: [UUID],
        hidesReadArticles: Bool,
        selectedArticleKey: String?,
        searchText: String
    ) -> FetchDescriptor<Article> {
        FetchDescriptor(
            predicate: FeedPersistenceQueries.articlePredicate(
                feedIDs: feedIDs,
                hidesReadArticles: hidesReadArticles,
                selectedArticleKey: selectedArticleKey,
                searchText: searchText
            ),
            sortBy: [SortDescriptor(\Article.publishedAt, order: .reverse)]
        )
    }

    private func makeArticle(
        feedID: UUID,
        remoteID: String,
        isRead: Bool = false
    ) -> Article {
        Article(
            articleKey: "\(feedID.uuidString)|\(remoteID)",
            feedID: feedID,
            feedTitle: "Feed",
            title: remoteID,
            isRead: isRead
        )
    }
}

@MainActor
private final class QueryTestStore {
    let container: ModelContainer
    let context: ModelContext

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
        context = ModelContext(container)
        context.autosaveEnabled = false
    }
}
