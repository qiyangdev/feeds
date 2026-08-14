import Foundation
import SwiftData

actor SubscriptionArticleCountController {
    func counts(
        in modelContainer: ModelContainer,
        activeFeedIDs: [UUID]
    ) throws -> SubscriptionArticleCounts {
        guard !activeFeedIDs.isEmpty else { return .empty }

        let modelContext = ModelContext(modelContainer)
        modelContext.autosaveEnabled = false
        let feedIDs = activeFeedIDs
        let totalDescriptor = FetchDescriptor<Article>(
            predicate: #Predicate<Article> { article in
                feedIDs.contains(article.feedID)
            }
        )
        let unreadDescriptor = FetchDescriptor<Article>(
            predicate: #Predicate<Article> { article in
                feedIDs.contains(article.feedID) && !article.isRead
            }
        )

        let total = try modelContext.fetchCount(totalDescriptor)
        var unreadByFeedID: [UUID: Int] = [:]
        try modelContext.enumerate(
            unreadDescriptor,
            batchSize: 500
        ) { (article: Article) in
            try Task.checkCancellation()
            unreadByFeedID[article.feedID, default: 0] += 1
        }
        return SubscriptionArticleCounts(
            total: total,
            unreadByFeedID: unreadByFeedID
        )
    }
}
