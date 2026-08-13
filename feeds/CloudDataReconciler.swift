import Foundation
import SwiftData

@MainActor
enum CloudDataReconciler {
    static func reconcile(in modelContext: ModelContext) throws {
        try PersistenceService.save(in: modelContext) {
            let feeds = try modelContext.fetch(FetchDescriptor<Feed>())
            reconcileFeeds(feeds)

            let articles = try modelContext.fetch(FetchDescriptor<Article>())
            repairDuplicateArticleIDs(articles)
            reconcileArticles(
                articles,
                feeds: feeds,
                modelContext: modelContext
            )
        }
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

            canonical.mergedIntoFeedID = nil
            for duplicate in activeFeeds.dropFirst() {
                merge(duplicate, into: canonical)
                duplicate.mergedIntoFeedID = canonical.id
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
                article.feedID = destination.id
                article.feedTitle = destination.title
                article.articleKey = articleKey(
                    feedID: destination.id,
                    remoteID: remoteID
                )
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
            canonical.title = duplicate.title
            canonical.automaticallyExtractsArticleContent =
                duplicate.automaticallyExtractsArticleContent
            canonical.settingsModifiedAt = duplicate.settingsModifiedAt
        }

        if let duplicateLastFetchedAt = duplicate.lastFetchedAt,
            canonical.lastFetchedAt == nil
                || duplicateLastFetchedAt > canonical.lastFetchedAt!
        {
            canonical.siteURLString = duplicate.siteURLString
            canonical.summaryText = duplicate.summaryText
            canonical.iconData = duplicate.iconData ?? canonical.iconData
            canonical.lastError = duplicate.lastError
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

        canonical.lastFetchedAt = [canonical.lastFetchedAt, duplicate.lastFetchedAt]
            .compactMap { $0 }
            .max()
    }

    private static func merge(_ duplicate: Article, into canonical: Article) {
        if fieldFromDuplicateWins(
            duplicateDate: duplicate.readModifiedAt,
            canonicalDate: canonical.readModifiedAt,
            duplicateID: duplicate.id,
            canonicalID: canonical.id
        ) {
            canonical.isRead = duplicate.isRead
            canonical.readModifiedAt = duplicate.readModifiedAt
        }
        if fieldFromDuplicateWins(
            duplicateDate: duplicate.starredModifiedAt,
            canonicalDate: canonical.starredModifiedAt,
            duplicateID: duplicate.id,
            canonicalID: canonical.id
        ) {
            canonical.isStarred = duplicate.isStarred
            canonical.starredModifiedAt = duplicate.starredModifiedAt
        }
        if fieldFromDuplicateWins(
            duplicateDate: duplicate.extractedModifiedAt,
            canonicalDate: canonical.extractedModifiedAt,
            duplicateID: duplicate.id,
            canonicalID: canonical.id
        ) {
            canonical.extractedMarkdown = duplicate.extractedMarkdown
            canonical.extractedModifiedAt = duplicate.extractedModifiedAt
        }

        if serverStateFromDuplicateWins(
            duplicate: duplicate,
            canonical: canonical
        ) {
            canonical.feedTitle = duplicate.feedTitle
            canonical.title = duplicate.title
            canonical.urlString = duplicate.urlString
            canonical.summaryText = duplicate.summaryText
            canonical.author = duplicate.author
            canonical.publishedAt = duplicate.publishedAt
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

                canonical.mergedIntoFeedID = nil
                for feed in cycle.dropFirst() {
                    feed.mergedIntoFeedID = canonical.id
                }
                return .active(canonical)
            }

            guard let destinationID = current.mergedIntoFeedID else {
                for visitedID in visitedIDs where visitedID != current.id {
                    feedByID[visitedID]?.mergedIntoFeedID = current.id
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
