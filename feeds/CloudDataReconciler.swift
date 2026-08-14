import Foundation
import SwiftData

nonisolated enum CloudDataReconciler {
    static func reconcile(in modelContext: ModelContext) throws {
        try PersistenceService.save(in: modelContext) {
            try applyChanges(in: modelContext)
        }
    }

    static func needsReconciliation(
        in modelContext: ModelContext
    ) throws -> Bool {
        modelContext.autosaveEnabled = false
        defer { modelContext.rollback() }
        let snapshotBefore = try CloudDataDryRunSnapshot(in: modelContext)
        try applyChanges(in: modelContext)
        let snapshotAfter = try CloudDataDryRunSnapshot(in: modelContext)
        return snapshotBefore != snapshotAfter
    }

    private static func applyChanges(
        in modelContext: ModelContext
    ) throws {
        let feeds = try modelContext.fetch(FetchDescriptor<Feed>())
        let articles = try modelContext.fetch(FetchDescriptor<Article>())
        repairDuplicateArticleIDs(articles)
        reconcileFeeds(feeds)
        reconcileArticles(
            articles,
            feeds: feeds,
            modelContext: modelContext
        )
    }

    private static func repairDuplicateArticleIDs(_ articles: [Article]) {
        let duplicateGroups = Dictionary(grouping: articles, by: \.id)
            .values
            .filter { $0.count > 1 }

        for group in duplicateGroups {
            let ordered = group.sorted { lhs, rhs in
                if lhs.articleKey != rhs.articleKey {
                    return lhs.articleKey < rhs.articleKey
                }
                let lhsKey = "\(lhs.feedID.uuidString)|\(lhs.savedAt.timeIntervalSinceReferenceDate)|\(lhs.title)"
                let rhsKey = "\(rhs.feedID.uuidString)|\(rhs.savedAt.timeIntervalSinceReferenceDate)|\(rhs.title)"
                return lhsKey < rhsKey
            }
            for article in ordered.dropFirst() {
                article.id = UUID()
            }
        }
    }

    private static func reconcileFeeds(_ feeds: [Feed]) {
        let groups = Dictionary(
            grouping: feeds,
            by: { normalizedFeedURL($0.feedURLString) }
        )

        for key in groups.keys.sorted() {
            guard let group = groups[key] else { continue }

            // A deleted feed is retained as a tombstone. Any older copy of the
            // same subscription that arrives later must inherit that deletion.
            if let deletionBoundary = group.compactMap(\.deletedAt).max() {
                for feed in group where feed.dateAdded <= deletionBoundary {
                    if feed.deletedAt == nil
                        || feed.deletedAt! < deletionBoundary
                    {
                        feed.deletedAt = deletionBoundary
                        feed.mergedIntoFeedID = nil
                    }
                }
            }

            // A subscription created after the latest tombstone is a genuine
            // re-subscription. Among active copies, the oldest ID-stable record
            // is canonical and all others become durable redirects.
            let activeFeeds = group
                .filter { $0.deletedAt == nil }
                .sorted(by: feedPrecedes)
            guard let canonical = activeFeeds.first else { continue }

            if canonical.mergedIntoFeedID != nil {
                canonical.mergedIntoFeedID = nil
            }
            for duplicate in activeFeeds.dropFirst() {
                merge(duplicate, into: canonical)
                if duplicate.mergedIntoFeedID != canonical.id {
                    duplicate.mergedIntoFeedID = canonical.id
                }
            }
        }
    }

    private static func reconcileArticles(
        _ articles: [Article],
        feeds: [Feed],
        modelContext: ModelContext
    ) {
        var feedByID: [UUID: Feed] = [:]
        for feed in feeds.sorted(by: feedPrecedes) {
            guard let existing = feedByID[feed.id] else {
                feedByID[feed.id] = feed
                continue
            }
            if existing.deletedAt == nil, feed.deletedAt != nil {
                feedByID[feed.id] = feed
            }
        }
        var activeArticles: [Article] = []

        for article in articles {
            guard let sourceFeed = feedByID[article.feedID] else {
                // CloudKit can import an article before its feed. Preserve it
                // until a later reconciliation can classify it safely.
                continue
            }

            switch resolvedFeed(
                from: sourceFeed,
                feedByID: feedByID
            ) {
            case .active(let destination):
                let remoteID = remoteArticleID(
                    from: article.articleKey,
                    fallback: article.urlString ?? article.title
                )
                let destinationArticleKey = articleKey(
                    feedID: destination.id,
                    remoteID: remoteID
                )
                if article.feedID != destination.id {
                    article.feedID = destination.id
                }
                if article.feedTitle != destination.title {
                    article.feedTitle = destination.title
                }
                if article.articleKey != destinationArticleKey {
                    article.articleKey = destinationArticleKey
                }
                activeArticles.append(article)

            case .deleted:
                modelContext.delete(article)

            case .pending:
                // The redirect destination may not have arrived from CloudKit
                // yet. Keep the article attached to the redirect for now.
                continue
            }
        }

        var articleByKey: [String: Article] = [:]
        for article in activeArticles.sorted(by: articlePrecedes) {
            guard let canonical = articleByKey[article.articleKey] else {
                articleByKey[article.articleKey] = article
                continue
            }

            merge(article, into: canonical)
            modelContext.delete(article)
        }
    }

    private static func merge(_ duplicate: Feed, into canonical: Feed) {
        // Equal timestamps retain the deterministic canonical record. This
        // avoids needing a second per-field provenance ID for tie breaking.
        if fieldFromDuplicateWins(
            duplicateDate: duplicate.settingsModifiedAt,
            canonicalDate: canonical.settingsModifiedAt,
            duplicateID: duplicate.id,
            canonicalID: canonical.id
        ) {
            if canonical.title != duplicate.title {
                canonical.title = duplicate.title
            }
            if canonical.automaticallyExtractsArticleContent
                != duplicate.automaticallyExtractsArticleContent
            {
                canonical.automaticallyExtractsArticleContent =
                    duplicate.automaticallyExtractsArticleContent
            }
            if canonical.settingsModifiedAt != duplicate.settingsModifiedAt {
                canonical.settingsModifiedAt = duplicate.settingsModifiedAt
            }
        }

        if let duplicateLastFetchedAt = duplicate.lastFetchedAt,
            canonical.lastFetchedAt == nil
                || duplicateLastFetchedAt > canonical.lastFetchedAt!
        {
            if canonical.siteURLString != duplicate.siteURLString {
                canonical.siteURLString = duplicate.siteURLString
            }
            if canonical.summaryText != duplicate.summaryText {
                canonical.summaryText = duplicate.summaryText
            }
            if let duplicateIconData = duplicate.iconData,
                canonical.iconData != duplicateIconData
            {
                canonical.iconData = duplicateIconData
            }
            if canonical.lastError != duplicate.lastError {
                canonical.lastError = duplicate.lastError
            }
        } else {
            if canonical.siteURLString == nil {
                canonical.siteURLString = duplicate.siteURLString
            }
            if canonical.summaryText.isEmpty {
                canonical.summaryText = duplicate.summaryText
            }
            if canonical.iconData == nil {
                canonical.iconData = duplicate.iconData
            }
            if canonical.lastError == nil {
                canonical.lastError = duplicate.lastError
            }
        }

        let mergedLastFetchedAt = [
            canonical.lastFetchedAt,
            duplicate.lastFetchedAt,
        ]
            .compactMap { $0 }
            .max()
        if canonical.lastFetchedAt != mergedLastFetchedAt {
            canonical.lastFetchedAt = mergedLastFetchedAt
        }
    }

    private static func merge(_ duplicate: Article, into canonical: Article) {
        if fieldFromDuplicateWins(
            duplicateDate: duplicate.readModifiedAt,
            canonicalDate: canonical.readModifiedAt,
            duplicateID: duplicate.id,
            canonicalID: canonical.id
        ) {
            if canonical.isRead != duplicate.isRead {
                canonical.isRead = duplicate.isRead
            }
            if canonical.readModifiedAt != duplicate.readModifiedAt {
                canonical.readModifiedAt = duplicate.readModifiedAt
            }
        }
        if fieldFromDuplicateWins(
            duplicateDate: duplicate.starredModifiedAt,
            canonicalDate: canonical.starredModifiedAt,
            duplicateID: duplicate.id,
            canonicalID: canonical.id
        ) {
            if canonical.isStarred != duplicate.isStarred {
                canonical.isStarred = duplicate.isStarred
            }
            if canonical.starredModifiedAt != duplicate.starredModifiedAt {
                canonical.starredModifiedAt = duplicate.starredModifiedAt
            }
        }
        if fieldFromDuplicateWins(
            duplicateDate: duplicate.extractedModifiedAt,
            canonicalDate: canonical.extractedModifiedAt,
            duplicateID: duplicate.id,
            canonicalID: canonical.id
        ) {
            if canonical.extractedMarkdown != duplicate.extractedMarkdown {
                canonical.extractedMarkdown = duplicate.extractedMarkdown
            }
            if canonical.extractedModifiedAt
                != duplicate.extractedModifiedAt
            {
                canonical.extractedModifiedAt = duplicate.extractedModifiedAt
            }
        }

        if serverStateFromDuplicateWins(
            duplicate: duplicate,
            canonical: canonical
        ) {
            if canonical.feedTitle != duplicate.feedTitle {
                canonical.feedTitle = duplicate.feedTitle
            }
            if canonical.title != duplicate.title {
                canonical.title = duplicate.title
            }
            if canonical.urlString != duplicate.urlString {
                canonical.urlString = duplicate.urlString
            }
            if canonical.summaryText != duplicate.summaryText {
                canonical.summaryText = duplicate.summaryText
            }
            if canonical.author != duplicate.author {
                canonical.author = duplicate.author
            }
            if canonical.publishedAt != duplicate.publishedAt {
                canonical.publishedAt = duplicate.publishedAt
            }
        } else {
            if canonical.title.isEmpty { canonical.title = duplicate.title }
            if canonical.urlString == nil {
                canonical.urlString = duplicate.urlString
            }
            if canonical.summaryText.isEmpty {
                canonical.summaryText = duplicate.summaryText
            }
            if canonical.author == nil { canonical.author = duplicate.author }
        }

        // `savedAt` is creation metadata and part of the stable merge input.
        // Never mutate it while folding duplicate records into the winner.
    }

    private static func feedPrecedes(_ lhs: Feed, _ rhs: Feed) -> Bool {
        if lhs.dateAdded != rhs.dateAdded {
            return lhs.dateAdded < rhs.dateAdded
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func articlePrecedes(
        _ lhs: Article,
        _ rhs: Article
    ) -> Bool {
        lhs.id.uuidString < rhs.id.uuidString
    }

    private static func serverStateFromDuplicateWins(
        duplicate: Article,
        canonical: Article
    ) -> Bool {
        if duplicate.savedAt != canonical.savedAt {
            return duplicate.savedAt > canonical.savedAt
        }
        return duplicate.id.uuidString < canonical.id.uuidString
    }

    private static func fieldFromDuplicateWins(
        duplicateDate: Date,
        canonicalDate: Date,
        duplicateID: UUID,
        canonicalID: UUID
    ) -> Bool {
        duplicateDate > canonicalDate
            || (duplicateDate == canonicalDate
                && duplicateID.uuidString > canonicalID.uuidString)
    }

    private enum FeedResolution {
        case active(Feed)
        case deleted
        case pending
    }

    private static func resolvedFeed(
        from source: Feed,
        feedByID: [UUID: Feed]
    ) -> FeedResolution {
        var current = source
        var visitedIDs: Set<UUID> = []

        while true {
            guard current.deletedAt == nil else { return .deleted }

            guard visitedIDs.insert(current.id).inserted else {
                let cycle = visitedIDs
                    .compactMap { feedByID[$0] }
                    .filter { $0.deletedAt == nil }
                    .sorted(by: feedPrecedes)
                guard let canonical = cycle.first else { return .deleted }

                if canonical.mergedIntoFeedID != nil {
                    canonical.mergedIntoFeedID = nil
                }
                for feed in cycle.dropFirst() {
                    if feed.mergedIntoFeedID != canonical.id {
                        feed.mergedIntoFeedID = canonical.id
                    }
                }
                return .active(canonical)
            }

            guard let destinationID = current.mergedIntoFeedID else {
                for visitedID in visitedIDs where visitedID != current.id {
                    if feedByID[visitedID]?.mergedIntoFeedID != current.id {
                        feedByID[visitedID]?.mergedIntoFeedID = current.id
                    }
                }
                return .active(current)
            }
            guard let destination = feedByID[destinationID] else {
                return .pending
            }
            current = destination
        }
    }

    private static func normalizedFeedURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80)
        {
            components.port = nil
        }
        if components.path.count > 1 && components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string ?? value.lowercased()
    }

    private static func remoteArticleID(
        from articleKey: String,
        fallback: String
    ) -> String {
        guard let separator = articleKey.firstIndex(of: "|") else {
            return fallback
        }
        let remoteID = String(
            articleKey[articleKey.index(after: separator)...]
        )
        return remoteID.isEmpty ? fallback : remoteID
    }

    private static func articleKey(feedID: UUID, remoteID: String) -> String {
        "\(feedID.uuidString)|\(remoteID)"
    }
}

private nonisolated struct CloudDataDryRunSnapshot: Equatable, Sendable {
    private struct FeedRecord: Hashable, Sendable {
        let persistentID: PersistentIdentifier
        let id: UUID
        let feedURLString: String
        let title: String
        let siteURLString: String?
        let summaryText: String
        let dateAdded: Date
        let lastFetchedAt: Date?
        let lastError: String?
        let iconData: Data?
        let automaticallyExtractsArticleContent: Bool
        let settingsModifiedAt: Date
        let deletedAt: Date?
        let mergedIntoFeedID: UUID?
    }

    private struct ArticleRecord: Hashable, Sendable {
        let persistentID: PersistentIdentifier
        let id: UUID
        let articleKey: String
        let feedID: UUID
        let feedTitle: String
        let title: String
        let urlString: String?
        let summaryText: String
        let author: String?
        let publishedAt: Date
        let savedAt: Date
        let isRead: Bool
        let isStarred: Bool
        let extractedMarkdown: String?
        let readModifiedAt: Date
        let starredModifiedAt: Date
        let extractedModifiedAt: Date
    }

    private let feeds: [FeedRecord]
    private let articles: [ArticleRecord]

    init(in modelContext: ModelContext) throws {
        feeds = try modelContext.fetch(FetchDescriptor<Feed>()).map {
            FeedRecord(
                persistentID: $0.persistentModelID,
                id: $0.id,
                feedURLString: $0.feedURLString,
                title: $0.title,
                siteURLString: $0.siteURLString,
                summaryText: $0.summaryText,
                dateAdded: $0.dateAdded,
                lastFetchedAt: $0.lastFetchedAt,
                lastError: $0.lastError,
                iconData: $0.iconData,
                automaticallyExtractsArticleContent:
                    $0.automaticallyExtractsArticleContent,
                settingsModifiedAt: $0.settingsModifiedAt,
                deletedAt: $0.deletedAt,
                mergedIntoFeedID: $0.mergedIntoFeedID
            )
        }.sorted { $0.persistentID < $1.persistentID }
        articles = try modelContext.fetch(FetchDescriptor<Article>()).compactMap {
            guard !$0.isDeleted else { return nil }
            return ArticleRecord(
                persistentID: $0.persistentModelID,
                id: $0.id,
                articleKey: $0.articleKey,
                feedID: $0.feedID,
                feedTitle: $0.feedTitle,
                title: $0.title,
                urlString: $0.urlString,
                summaryText: $0.summaryText,
                author: $0.author,
                publishedAt: $0.publishedAt,
                savedAt: $0.savedAt,
                isRead: $0.isRead,
                isStarred: $0.isStarred,
                extractedMarkdown: $0.extractedMarkdown,
                readModifiedAt: $0.readModifiedAt,
                starredModifiedAt: $0.starredModifiedAt,
                extractedModifiedAt: $0.extractedModifiedAt
            )
        }.sorted { $0.persistentID < $1.persistentID }
    }
}
