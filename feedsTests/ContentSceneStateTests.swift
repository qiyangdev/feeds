import Foundation
import Testing
@testable import feeds

@Suite
@MainActor
struct ContentSceneStateTests {
    @Test func JSONRoundTripPreservesState() throws {
        let feedID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        )!
        let articleID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000002"
        )!
        let state = ContentSceneState(
            hasInitializedNavigation: true,
            subscription: .feed(feedID),
            article: StoredArticleReference(
                id: articleID,
                key: "\(feedID.uuidString)|entry",
                feedID: feedID
            ),
            normalColumnVisibility: .doubleColumn,
            preferredCompactColumn: .detail,
            wantsArticleFullScreen: true
        )

        let data = try #require(state.encoded())
        let restored = try #require(ContentSceneState.restored(from: data))

        #expect(restored == state)
    }

    @Test func damagedOrUnsupportedStateFallsBack() throws {
        #expect(
            ContentSceneState.restored(
                from: Data("not valid JSON".utf8)
            ) == nil
        )

        var unsupportedState = ContentSceneState()
        unsupportedState.version = ContentSceneState.currentVersion + 1
        let unsupportedData = try #require(unsupportedState.encoded())

        #expect(ContentSceneState.restored(from: unsupportedData) == nil)
    }

    @Test func activeFeedResolves() {
        let feed = makeFeed(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000010"
            )!
        )

        #expect(
            ContentSceneResolver.resolveFeed(
                id: feed.id,
                feeds: [feed]
            ) == .resolved(feed.id)
        )
    }

    @Test func redirectWithMissingDestinationRemainsPending() {
        let missingDestinationID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000021"
        )!
        let redirect = makeFeed(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000020"
            )!,
            mergedIntoFeedID: missingDestinationID
        )

        #expect(
            ContentSceneResolver.resolveFeed(
                id: redirect.id,
                feeds: [redirect]
            ) == .pending
        )
    }

    @Test func tombstonedFeedIsInvalid() {
        let tombstone = makeFeed(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000030"
            )!,
            deletedAt: Date(timeIntervalSince1970: 1)
        )

        #expect(
            ContentSceneResolver.resolveFeed(
                id: tombstone.id,
                feeds: [tombstone]
            ) == .invalid
        )
    }

    @Test func articleResolvesByStableID() {
        let feed = makeFeed(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000040"
            )!
        )
        let article = makeArticle(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000041"
            )!,
            feed: feed,
            remoteID: "current-entry"
        )
        let reference = StoredArticleReference(
            id: article.id,
            key: "\(feed.id.uuidString)|outdated-entry",
            feedID: feed.id
        )

        let resolution = ContentSceneResolver.resolveArticle(
            reference,
            subscription: .feed(feed.id),
            feeds: [feed],
            articles: [article]
        )

        assertResolved(resolution, is: article)
    }

    @Test func articleResolvesByKeyWhenIDChanged() {
        let feed = makeFeed(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000050"
            )!
        )
        let article = makeArticle(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000051"
            )!,
            feed: feed,
            remoteID: "shared-entry"
        )
        let reference = StoredArticleReference(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000052"
            )!,
            key: article.articleKey,
            feedID: feed.id
        )

        let resolution = ContentSceneResolver.resolveArticle(
            reference,
            subscription: .all,
            feeds: [feed],
            articles: [article]
        )

        assertResolved(resolution, is: article)
    }

    @Test func articleKeyWinsWhenLegacyIDsAreDuplicated() {
        let feed = makeFeed(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000053"
            )!
        )
        let duplicatedID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000054"
        )!
        let otherArticle = makeArticle(
            id: duplicatedID,
            feed: feed,
            remoteID: "other-entry"
        )
        let expectedArticle = makeArticle(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000055"
            )!,
            feed: feed,
            remoteID: "restored-entry"
        )
        let reference = StoredArticleReference(
            id: duplicatedID,
            key: expectedArticle.articleKey,
            feedID: feed.id
        )

        let resolution = ContentSceneResolver.resolveArticle(
            reference,
            subscription: .feed(feed.id),
            feeds: [feed],
            articles: [otherArticle, expectedArticle]
        )

        assertResolved(resolution, is: expectedArticle)
    }

    @Test func legacyArticleIDFallbackDoesNotCrossFeeds() {
        let expectedFeed = makeFeed(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000056"
            )!
        )
        let otherFeed = makeFeed(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000057"
            )!
        )
        let duplicatedLegacyID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000058"
        )!
        let wrongFeedArticle = makeArticle(
            id: duplicatedLegacyID,
            feed: otherFeed,
            remoteID: "other-feed-entry"
        )
        let reference = StoredArticleReference(
            id: duplicatedLegacyID,
            key: "\(expectedFeed.id.uuidString)|missing-entry",
            feedID: expectedFeed.id
        )

        let resolution = ContentSceneResolver.resolveArticle(
            reference,
            subscription: .all,
            feeds: [expectedFeed, otherFeed],
            articles: [wrongFeedArticle]
        )

        guard case .pending = resolution else {
            Issue.record(
                "A legacy article ID from another feed must not satisfy restoration."
            )
            return
        }
    }

    @Test func articleResolvesByRemoteIDAfterFeedRedirect() {
        let canonical = makeFeed(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000060"
            )!
        )
        let redirect = makeFeed(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000061"
            )!,
            mergedIntoFeedID: canonical.id
        )
        let article = makeArticle(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000062"
            )!,
            feed: canonical,
            remoteID: "redirected-entry"
        )
        let reference = StoredArticleReference(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000063"
            )!,
            key: "\(redirect.id.uuidString)|redirected-entry",
            feedID: redirect.id
        )

        let resolution = ContentSceneResolver.resolveArticle(
            reference,
            subscription: .feed(canonical.id),
            feeds: [redirect, canonical],
            articles: [article]
        )

        assertResolved(resolution, is: article)
    }

    @Test func redirectedRemoteIDWinsOverAReusedLegacyID() {
        let canonical = makeFeed(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000064"
            )!
        )
        let redirect = makeFeed(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000065"
            )!,
            mergedIntoFeedID: canonical.id
        )
        let legacyID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000066"
        )!
        let wrongArticle = makeArticle(
            id: legacyID,
            feed: canonical,
            remoteID: "wrong-entry"
        )
        let expectedArticle = makeArticle(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000067"
            )!,
            feed: canonical,
            remoteID: "expected-entry"
        )
        let reference = StoredArticleReference(
            id: legacyID,
            key: "\(redirect.id.uuidString)|expected-entry",
            feedID: redirect.id
        )

        let resolution = ContentSceneResolver.resolveArticle(
            reference,
            subscription: .feed(canonical.id),
            feeds: [redirect, canonical],
            articles: [wrongArticle, expectedArticle]
        )

        assertResolved(resolution, is: expectedArticle)
    }

    private func makeFeed(
        id: UUID,
        deletedAt: Date? = nil,
        mergedIntoFeedID: UUID? = nil
    ) -> Feed {
        Feed(
            id: id,
            feedURLString: "https://unit.test/\(id.uuidString).xml",
            title: "Feed \(id.uuidString)",
            deletedAt: deletedAt,
            mergedIntoFeedID: mergedIntoFeedID
        )
    }

    private func makeArticle(
        id: UUID,
        feed: Feed,
        remoteID: String
    ) -> Article {
        Article(
            id: id,
            articleKey: "\(feed.id.uuidString)|\(remoteID)",
            feedID: feed.id,
            feedTitle: feed.title,
            title: remoteID
        )
    }

    private func assertResolved(
        _ resolution: StoredArticleResolution,
        is expectedArticle: Article,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case .resolved(let article) = resolution else {
            Issue.record(
                "Expected the stored article reference to resolve.",
                sourceLocation: sourceLocation
            )
            return
        }
        #expect(article === expectedArticle, sourceLocation: sourceLocation)
    }
}
