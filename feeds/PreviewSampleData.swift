import Foundation
import SwiftData

@MainActor
enum PreviewSampleData {
    static let primaryFeedID = UUID(uuidString: "B5595529-31E6-4CF3-B5B7-39B2E568A221")!

    static func makeContainer(populated: Bool = true) -> ModelContainer {
        do {
            let container = try FeedsStore.makeContainer(
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
            if populated {
                insertSamples(into: container.mainContext)
            }
            return container
        } catch {
            fatalError("Could not create preview ModelContainer: \(error)")
        }
    }

    static func primaryFeed(in container: ModelContainer) -> Feed {
        let feeds = (try? container.mainContext.fetch(FetchDescriptor<Feed>())) ?? []
        guard let feed = feeds.first(where: { $0.id == primaryFeedID }) else {
            fatalError("Preview primary feed is missing")
        }
        return feed
    }

    static func featuredArticle(in container: ModelContainer) -> Article {
        let articles = (try? container.mainContext.fetch(FetchDescriptor<Article>())) ?? []
        guard let article = articles.first(where: { $0.articleKey == "preview-swiftui" }) else {
            fatalError("Preview featured article is missing")
        }
        return article
    }

    private static func insertSamples(into context: ModelContext) {
        let designFeed = Feed(
            id: primaryFeedID,
            feedURLString: "https://example.com/design/feed.xml",
            title: "Design Details",
            siteURLString: "https://example.com/design",
            summaryText: "Articles about product design and development.",
            dateAdded: Date.now.addingTimeInterval(-86_400),
            lastFetchedAt: .now,
            automaticallyExtractsArticleContent: true
        )
        let swiftFeed = Feed(
            feedURLString: "https://example.com/swift/atom.xml",
            title: "Swift Weekly",
            siteURLString: "https://example.com/swift",
            summaryText: "A weekly selection from the Swift community.",
            dateAdded: Date.now.addingTimeInterval(-43_200),
            lastFetchedAt: .now
        )

        context.insert(designFeed)
        context.insert(swiftFeed)
        context.insert(
            Article(
                articleKey: "preview-swiftui",
                feedID: designFeed.id,
                feedTitle: designFeed.title,
                title: "Building a More Native SwiftUI Three-Column Interface for macOS",
                urlString: "https://example.com/design/swiftui-macos",
                summaryText: "Refine a cross-platform RSS reader—from the sidebar and article list to the detail toolbar—with interactions that feel at home on the desktop.",
                author: "Qiyang Wang",
                publishedAt: Date.now.addingTimeInterval(-3_600),
                isStarred: true,
                extractedMarkdown: """
                ## Start with the Information Architecture

                `NavigationSplitView` works well for an RSS reader because feeds, articles, and content form a stable hierarchy.

                - Preserve native selection behavior in the sidebar
                - Emphasize titles and read status in the article list
                - Provide content extraction and favorite actions in the detail view

                > A good cross-platform interface respects each platform's interaction conventions.
                """
            )
        )
        context.insert(
            Article(
                articleKey: "preview-design-systems",
                feedID: designFeed.id,
                feedTitle: designFeed.title,
                title: "Small Products Deserve Design Systems Too",
                urlString: "https://example.com/design/systems",
                summaryText: "Use semantic colors, spacing, and component constraints to reduce visual drift during UI iteration.",
                author: "Design Details",
                publishedAt: Date.now.addingTimeInterval(-86_400),
                isRead: true
            )
        )
        context.insert(
            Article(
                articleKey: "preview-swift-news",
                feedID: swiftFeed.id,
                feedTitle: swiftFeed.title,
                title: "This Week in the Swift Community",
                urlString: "https://example.com/swift/weekly",
                summaryText: "The latest developments in Swift Concurrency, SwiftData, and the open-source ecosystem.",
                publishedAt: Date.now.addingTimeInterval(-172_800)
            )
        )

        try? context.save()
    }
}
