import Foundation
import SwiftData

@Model
final class Feed {
    #Index<Feed>(
        [\.id],
        [\.dateAdded],
        [\.deletedAt, \.mergedIntoFeedID]
    )

    var id: UUID = UUID()
    var feedURLString: String = ""
    var title: String = ""
    var siteURLString: String?
    var summaryText: String = ""
    var dateAdded: Date = Date.now
    var lastFetchedAt: Date?
    var lastError: String?
    var iconData: Data?
    var automaticallyExtractsArticleContent: Bool = false
    var settingsModifiedAt: Date = Date.distantPast
    var deletedAt: Date?
    var mergedIntoFeedID: UUID?

    init(
        id: UUID = UUID(),
        feedURLString: String,
        title: String,
        siteURLString: String? = nil,
        summaryText: String = "",
        dateAdded: Date = .now,
        lastFetchedAt: Date? = nil,
        lastError: String? = nil,
        iconData: Data? = nil,
        automaticallyExtractsArticleContent: Bool = false,
        settingsModifiedAt: Date = .distantPast,
        deletedAt: Date? = nil,
        mergedIntoFeedID: UUID? = nil
    ) {
        self.id = id
        self.feedURLString = feedURLString
        self.title = title
        self.siteURLString = siteURLString
        self.summaryText = summaryText
        self.dateAdded = dateAdded
        self.lastFetchedAt = lastFetchedAt
        self.lastError = lastError
        self.iconData = iconData
        self.automaticallyExtractsArticleContent = automaticallyExtractsArticleContent
        self.settingsModifiedAt = settingsModifiedAt
        self.deletedAt = deletedAt
        self.mergedIntoFeedID = mergedIntoFeedID
    }

    var feedURL: URL? { URL(string: feedURLString) }
    var siteURL: URL? { siteURLString.flatMap(URL.init(string:)) }
    var isActive: Bool { deletedAt == nil && mergedIntoFeedID == nil }
}

@Model
final class Article {
    #Index<Article>(
        [\.id],
        [\.articleKey],
        [\.feedID, \.publishedAt],
        [\.feedID, \.isRead],
        [\.publishedAt]
    )

    var id: UUID = UUID()
    var articleKey: String = ""
    var feedID: UUID = UUID()
    var feedTitle: String = ""
    var title: String = ""
    var urlString: String?
    var summaryText: String = ""
    var author: String?
    var publishedAt: Date = Date.now
    var savedAt: Date = Date.now
    var isRead: Bool = false
    var isStarred: Bool = false
    var extractedMarkdown: String?
    var readModifiedAt: Date = Date.distantPast
    var starredModifiedAt: Date = Date.distantPast
    var extractedModifiedAt: Date = Date.distantPast

    init(
        id: UUID = UUID(),
        articleKey: String,
        feedID: UUID,
        feedTitle: String,
        title: String,
        urlString: String? = nil,
        summaryText: String = "",
        author: String? = nil,
        publishedAt: Date = .now,
        savedAt: Date = .now,
        isRead: Bool = false,
        isStarred: Bool = false,
        extractedMarkdown: String? = nil,
        readModifiedAt: Date = .distantPast,
        starredModifiedAt: Date = .distantPast,
        extractedModifiedAt: Date = .distantPast
    ) {
        self.id = id
        self.articleKey = articleKey
        self.feedID = feedID
        self.feedTitle = feedTitle
        self.title = title
        self.urlString = urlString
        self.summaryText = summaryText
        self.author = author
        self.publishedAt = publishedAt
        self.savedAt = savedAt
        self.isRead = isRead
        self.isStarred = isStarred
        self.extractedMarkdown = extractedMarkdown
        self.readModifiedAt = readModifiedAt
        self.starredModifiedAt = starredModifiedAt
        self.extractedModifiedAt = extractedModifiedAt
    }

    var url: URL? { urlString.flatMap(URL.init(string:)) }
}
