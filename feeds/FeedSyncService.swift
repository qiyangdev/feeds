import Foundation
import SwiftData

enum FeedSyncError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case duplicateFeed
    case feedNoLongerActive
    case refreshAndPersistenceFailed(
        refreshError: Error,
        persistenceError: Error
    )

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Enter a valid feed URL."
        case .invalidResponse:
            "The server returned an invalid response."
        case .httpStatus(let status):
            "The server returned HTTP \(status)."
        case .duplicateFeed:
            "This feed has already been added."
        case .feedNoLongerActive:
            "This feed was changed or removed while the operation was in progress."
        case .refreshAndPersistenceFailed(
            let refreshError,
            let persistenceError
        ):
            "Refresh failed (\(refreshError.localizedDescription)) and the error state could not be saved (\(persistenceError.localizedDescription))."
        }
    }
}

@MainActor
enum FeedSyncService {
    static func normalizedURL(from input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            throw FeedSyncError.invalidURL
        }
        return url
    }

    static func normalizedFeedURLString(_ url: URL) -> String {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return url.absoluteString
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
        return components.string ?? url.absoluteString
    }

    @discardableResult
    static func addFeed(
        url: URL,
        automaticallyExtractsArticleContent: Bool = false,
        modelContext: ModelContext
    ) async throws -> Feed {
        let parsed = try await fetch(url: url)
        let normalizedURLString = normalizedFeedURLString(url)
        let initiallyMatchingFeed = try activeFeed(
            matching: normalizedURLString,
            modelContext: modelContext
        )
        let iconData: Data?
        if let existingIconData = initiallyMatchingFeed?.iconData {
            iconData = existingIconData
        } else {
            iconData = await FeedIconService.fetchIconData(
                siteURLString: parsed.siteURL,
                feedURL: url
            )
        }
        let candidate = Feed(
            feedURLString: normalizedURLString,
            title: parsed.title,
            siteURLString: parsed.siteURL,
            summaryText: parsed.summary,
            lastFetchedAt: .now,
            iconData: iconData,
            automaticallyExtractsArticleContent:
                automaticallyExtractsArticleContent,
            settingsModifiedAt: .now
        )
        var savedFeed = candidate
        try PersistenceService.save(in: modelContext) {
            if let existing = try activeFeed(
                matching: normalizedURLString,
                modelContext: modelContext
            ) {
                existing.feedURLString = normalizedURLString
                existing.automaticallyExtractsArticleContent =
                    automaticallyExtractsArticleContent
                existing.settingsModifiedAt = .now
                existing.iconData = existing.iconData ?? iconData
                try apply(parsed, to: existing, modelContext: modelContext)
                savedFeed = existing
            } else {
                modelContext.insert(candidate)
                try apply(parsed, to: candidate, modelContext: modelContext)
            }
        }
        return savedFeed
    }

    static func refresh(_ feed: Feed, modelContext: ModelContext) async throws {
        guard let url = feed.feedURL else { throw FeedSyncError.invalidURL }
        let feedID = feed.id
        let expectedURLString = normalizedFeedURLString(url)
        let parsed: ParsedFeed

        do {
            parsed = try await fetch(url: url)
        } catch {
            guard let currentFeed = try currentActiveFeed(
                id: feedID,
                expectedURLString: expectedURLString,
                modelContext: modelContext
            ) else {
                return
            }
            try saveRefreshError(
                error,
                to: currentFeed,
                modelContext: modelContext
            )
            throw error
        }

        guard let currentFeed = try currentActiveFeed(
            id: feedID,
            expectedURLString: expectedURLString,
            modelContext: modelContext
        ) else {
            return
        }

        do {
            try PersistenceService.save(in: modelContext) {
                try apply(parsed, to: currentFeed, modelContext: modelContext)
            }
        } catch {
            let refreshError = error
            try saveRefreshError(
                refreshError,
                to: currentFeed,
                modelContext: modelContext
            )
            throw refreshError
        }
    }

    static func updateFeed(
        _ feed: Feed,
        title: String,
        url: URL,
        automaticallyExtractsArticleContent: Bool,
        modelContext: ModelContext
    ) async throws -> Feed {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURLString = normalizedFeedURLString(url)
        let currentNormalizedURLString = feed.feedURL.flatMap {
            normalizedFeedURLString($0)
        } ?? feed.feedURLString
        let urlChanged = currentNormalizedURLString != normalizedURLString

        let replacement: (parsed: ParsedFeed, iconData: Data?)?

        if urlChanged {
            let allFeeds = try modelContext.fetch(FetchDescriptor<Feed>())
            guard !allFeeds.contains(where: {
                guard $0.id != feed.id,
                    $0.isActive,
                    let candidateURL = URL(string: $0.feedURLString)
                else {
                    return false
                }
                return normalizedFeedURLString(candidateURL) == normalizedURLString
            }) else {
                throw FeedSyncError.duplicateFeed
            }

            let parsed = try await fetch(url: url)
            let iconData = await FeedIconService.fetchIconData(
                siteURLString: parsed.siteURL,
                feedURL: url
            )
            replacement = (parsed, iconData)
        } else {
            replacement = nil
        }

        let operationDate = Date.now
        var updatedFeed = feed
        try PersistenceService.save(in: modelContext) {
            let allFeeds = try modelContext.fetch(FetchDescriptor<Feed>())
            guard let currentFeed = allFeeds.first(where: {
                $0.id == feed.id && $0.isActive
            }) else {
                throw FeedSyncError.feedNoLongerActive
            }

            if let replacement {
                let hasDuplicate = allFeeds.contains { candidate in
                    guard candidate.id != currentFeed.id,
                        candidate.isActive,
                        let candidateURL = candidate.feedURL
                    else {
                        return false
                    }
                    return normalizedFeedURLString(candidateURL)
                        == normalizedURLString
                }
                guard !hasDuplicate else {
                    throw FeedSyncError.duplicateFeed
                }

                let newFeed = Feed(
                    feedURLString: normalizedURLString,
                    title: trimmedTitle,
                    siteURLString: replacement.parsed.siteURL,
                    summaryText: replacement.parsed.summary,
                    dateAdded: operationDate,
                    lastFetchedAt: operationDate,
                    iconData: replacement.iconData,
                    automaticallyExtractsArticleContent:
                        automaticallyExtractsArticleContent,
                    settingsModifiedAt: operationDate
                )
                modelContext.insert(newFeed)
                try apply(
                    replacement.parsed,
                    to: newFeed,
                    modelContext: modelContext
                )

                currentFeed.deletedAt = operationDate
                let oldArticles = try modelContext.fetch(
                    FetchDescriptor<Article>()
                )
                for article in oldArticles where article.feedID == currentFeed.id {
                    modelContext.delete(article)
                }
                updatedFeed = newFeed
            } else {
                currentFeed.title = trimmedTitle
                currentFeed.automaticallyExtractsArticleContent =
                    automaticallyExtractsArticleContent
                currentFeed.settingsModifiedAt = operationDate
                let currentArticles = try modelContext.fetch(
                    FetchDescriptor<Article>()
                )
                for article in currentArticles
                where article.feedID == currentFeed.id
                {
                    article.feedTitle = trimmedTitle
                }
                updatedFeed = currentFeed
            }
        }
        return updatedFeed
    }

    static func delete(_ feed: Feed, modelContext: ModelContext) throws {
        try PersistenceService.save(in: modelContext) {
            let feeds = try modelContext.fetch(FetchDescriptor<Feed>())
            guard let currentFeed = feeds.first(where: {
                $0.id == feed.id && $0.isActive
            }) else {
                return
            }
            currentFeed.deletedAt = .now
            let articles = try modelContext.fetch(FetchDescriptor<Article>())
            for article in articles where article.feedID == currentFeed.id {
                modelContext.delete(article)
            }
        }
    }

    static func updateReadState(
        articleID: UUID,
        isRead: Bool,
        modifiedAt: Date,
        modelContainer: ModelContainer
    ) throws {
        try updateArticle(
            id: articleID,
            modelContainer: modelContainer
        ) { article in
            article.isRead = isRead
            article.readModifiedAt = modifiedAt
        }
    }

    static func updateStarredState(
        articleID: UUID,
        isStarred: Bool,
        modifiedAt: Date,
        modelContainer: ModelContainer
    ) throws {
        try updateArticle(
            id: articleID,
            modelContainer: modelContainer
        ) { article in
            article.isStarred = isStarred
            article.starredModifiedAt = modifiedAt
        }
    }

    static func saveExtractedMarkdown(
        _ markdown: String,
        articleID: UUID,
        modifiedAt: Date,
        modelContainer: ModelContainer
    ) throws {
        try updateArticle(
            id: articleID,
            modelContainer: modelContainer
        ) { article in
            article.extractedMarkdown = markdown
            article.extractedModifiedAt = modifiedAt
        }
    }

    private static func fetch(url: URL) async throws -> ParsedFeed {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Feeds/1.0 RSS Reader", forHTTPHeaderField: "User-Agent")
        request.setValue("application/rss+xml, application/atom+xml, application/xml, text/xml, */*", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw FeedSyncError.invalidResponse }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw FeedSyncError.httpStatus(httpResponse.statusCode)
        }
        return try FeedParser().parse(data)
    }

    private static func updateArticle(
        id: UUID,
        modelContainer: ModelContainer,
        changes: (Article) -> Void
    ) throws {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        try PersistenceService.save(in: context) {
            let articles = try context.fetch(FetchDescriptor<Article>())
            let matchingArticles = articles.filter { $0.id == id }
            guard matchingArticles.count == 1,
                let article = matchingArticles.first
            else {
                throw FeedSyncError.feedNoLongerActive
            }
            changes(article)
        }
    }

    private static func apply(
        _ parsed: ParsedFeed,
        to feed: Feed,
        modelContext: ModelContext
    ) throws {
        feed.siteURLString = parsed.siteURL
        feed.summaryText = parsed.summary
        feed.lastFetchedAt = .now
        feed.lastError = nil

        let allArticles = try modelContext.fetch(FetchDescriptor<Article>())
        let feedArticles = allArticles
            .filter { $0.feedID == feed.id }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        var existingByKey: [String: Article] = [:]
        for article in feedArticles {
            if let canonical = existingByKey[article.articleKey] {
                mergeDuplicateArticle(article, into: canonical)
                modelContext.delete(article)
            } else {
                existingByKey[article.articleKey] = article
            }
        }

        for entry in parsed.entries {
            let key = "\(feed.id.uuidString)|\(entry.id)"
            if let existing = existingByKey[key] {
                existing.feedTitle = feed.title
                existing.title = entry.title
                existing.urlString = entry.url
                existing.summaryText = entry.summary
                existing.author = entry.author
                existing.publishedAt = entry.publishedAt
                continue
            }
            let article = Article(
                articleKey: key,
                feedID: feed.id,
                feedTitle: feed.title,
                title: entry.title,
                urlString: entry.url,
                summaryText: entry.summary,
                author: entry.author,
                publishedAt: entry.publishedAt
            )
            existingByKey[key] = article
            modelContext.insert(
                article
            )
        }
    }

    private static func activeFeed(
        matching normalizedURLString: String,
        modelContext: ModelContext
    ) throws -> Feed? {
        try modelContext.fetch(FetchDescriptor<Feed>())
            .filter(\.isActive)
            .filter { feed in
                guard let url = feed.feedURL else { return false }
                return normalizedFeedURLString(url) == normalizedURLString
            }
            .sorted {
                if $0.dateAdded != $1.dateAdded {
                    return $0.dateAdded < $1.dateAdded
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            .first
    }

    private static func currentActiveFeed(
        id: UUID,
        expectedURLString: String,
        modelContext: ModelContext
    ) throws -> Feed? {
        try modelContext.fetch(FetchDescriptor<Feed>()).first { feed in
            guard feed.id == id,
                feed.isActive,
                let currentURL = feed.feedURL
            else {
                return false
            }
            return normalizedFeedURLString(currentURL) == expectedURLString
        }
    }

    private static func saveRefreshError(
        _ refreshError: Error,
        to feed: Feed,
        modelContext: ModelContext
    ) throws {
        do {
            try PersistenceService.save(in: modelContext) {
                feed.lastError = refreshError.localizedDescription
            }
        } catch {
            throw FeedSyncError.refreshAndPersistenceFailed(
                refreshError: refreshError,
                persistenceError: error
            )
        }
    }

    private static func mergeDuplicateArticle(
        _ duplicate: Article,
        into canonical: Article
    ) {
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
        if duplicate.savedAt > canonical.savedAt {
            canonical.feedTitle = duplicate.feedTitle
            canonical.title = duplicate.title
            canonical.urlString = duplicate.urlString
            canonical.summaryText = duplicate.summaryText
            canonical.author = duplicate.author
            canonical.publishedAt = duplicate.publishedAt
        }
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
}
