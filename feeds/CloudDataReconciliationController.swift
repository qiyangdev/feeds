import Foundation
import SwiftData

actor CloudDataReconciliationController {
    private struct InFlightReconciliation {
        let id: UInt64
        let coveredRequest: UInt64
        let task: Task<Void, Error>
    }

    private var inFlightReconciliation: InFlightReconciliation?
    private var requestGeneration: UInt64 = 0
    private var completedGeneration: UInt64 = 0
    private var nextReconciliationID: UInt64 = 0
    private var lastCleanSnapshot: CloudDataStructureSnapshot?
    #if DEBUG
        private var appliedPassCount = 0
        private let cleanPassHookForTesting: (@Sendable () async -> Void)?

        init(
            cleanPassHookForTesting: (@Sendable () async -> Void)? = nil
        ) {
            self.cleanPassHookForTesting = cleanPassHookForTesting
        }
    #endif

    func reconcileIfNeeded(
        in modelContainer: ModelContainer
    ) async throws {
        try Task.checkCancellation()
        requestGeneration &+= 1
        let requestedGeneration = requestGeneration

        while completedGeneration < requestedGeneration {
            let reconciliation: InFlightReconciliation
            if let inFlightReconciliation {
                reconciliation = inFlightReconciliation
            } else {
                nextReconciliationID &+= 1
                let task = Task<Void, Error> {
                    try await self.performReconciliation(
                        in: modelContainer
                    )
                }
                reconciliation = InFlightReconciliation(
                    id: nextReconciliationID,
                    coveredRequest: requestGeneration,
                    task: task
                )
                inFlightReconciliation = reconciliation
            }

            do {
                try await reconciliation.task.value
            } catch {
                if inFlightReconciliation?.id == reconciliation.id {
                    inFlightReconciliation = nil
                }
                throw error
            }
            if inFlightReconciliation?.id == reconciliation.id {
                completedGeneration = max(
                    completedGeneration,
                    reconciliation.coveredRequest
                )
                inFlightReconciliation = nil
            }
            try Task.checkCancellation()
        }
    }

    private func performReconciliation(
        in modelContainer: ModelContainer
    ) async throws {
        // A concurrent import can land between detection and application. Each
        // pass applies the existing algorithm to the latest main context, then
        // verifies the durable result in a fresh private context.
        for _ in 0..<3 {
            try Task.checkCancellation()
            let modelContext = ModelContext(modelContainer)
            modelContext.autosaveEnabled = false
            let snapshot = try CloudDataStructureSnapshot(in: modelContext)
            guard snapshot != lastCleanSnapshot else { return }

            let needsReconciliation = try CloudDataReconciler
                .needsReconciliation(in: modelContext)
            guard needsReconciliation else {
                #if DEBUG
                    if let cleanPassHookForTesting {
                        await cleanPassHookForTesting()
                    }
                #endif
                lastCleanSnapshot = snapshot
                return
            }

            lastCleanSnapshot = nil
            try Task.checkCancellation()
            try await MainActor.run {
                try CloudDataReconciler.reconcile(
                    in: modelContainer.mainContext
                )
            }
            #if DEBUG
                appliedPassCount += 1
            #endif
        }
    }

    #if DEBUG
        func appliedPassCountForTesting() -> Int {
            appliedPassCount
        }

        func requestGenerationForTesting() -> UInt64 {
            requestGeneration
        }
    #endif
}

private nonisolated struct CloudDataStructureSnapshot: Equatable, Sendable {
    private struct FeedRecord: Hashable, Sendable {
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

    private let feeds: [FeedRecord: Int]
    private let articles: [ArticleRecord: Int]

    init(in modelContext: ModelContext) throws {
        var feedRecords: [FeedRecord: Int] = [:]
        for feed in try modelContext.fetch(FetchDescriptor<Feed>()) {
            let record = FeedRecord(
                id: feed.id,
                feedURLString: feed.feedURLString,
                title: feed.title,
                siteURLString: feed.siteURLString,
                summaryText: feed.summaryText,
                dateAdded: feed.dateAdded,
                lastFetchedAt: feed.lastFetchedAt,
                lastError: feed.lastError,
                iconData: feed.iconData,
                automaticallyExtractsArticleContent:
                    feed.automaticallyExtractsArticleContent,
                settingsModifiedAt: feed.settingsModifiedAt,
                deletedAt: feed.deletedAt,
                mergedIntoFeedID: feed.mergedIntoFeedID
            )
            feedRecords[record, default: 0] += 1
        }

        var articleRecords: [ArticleRecord: Int] = [:]
        for article in try modelContext.fetch(FetchDescriptor<Article>()) {
            let record = ArticleRecord(
                id: article.id,
                articleKey: article.articleKey,
                feedID: article.feedID,
                feedTitle: article.feedTitle,
                title: article.title,
                urlString: article.urlString,
                summaryText: article.summaryText,
                author: article.author,
                publishedAt: article.publishedAt,
                savedAt: article.savedAt,
                isRead: article.isRead,
                isStarred: article.isStarred,
                extractedMarkdown: article.extractedMarkdown,
                readModifiedAt: article.readModifiedAt,
                starredModifiedAt: article.starredModifiedAt,
                extractedModifiedAt: article.extractedModifiedAt
            )
            articleRecords[record, default: 0] += 1
        }

        feeds = feedRecords
        articles = articleRecords
    }
}
