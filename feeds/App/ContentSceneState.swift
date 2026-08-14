import Foundation
import SwiftUI

enum SubscriptionSelection: Hashable {
    case all
    case feed(UUID)
}

enum StoredSubscriptionSelection: Codable, Hashable {
    case all
    case feed(UUID)
}

struct StoredArticleReference: Codable, Hashable {
    var id: UUID
    var key: String
    var feedID: UUID
}

enum StoredSplitViewVisibility: String, Codable, CaseIterable {
    case automatic
    case all
    case doubleColumn
    case detailOnly

    init(_ visibility: NavigationSplitViewVisibility) {
        if visibility == .all {
            self = .all
        } else if visibility == .doubleColumn {
            self = .doubleColumn
        } else if visibility == .detailOnly {
            self = .detailOnly
        } else {
            self = .automatic
        }
    }

    var value: NavigationSplitViewVisibility {
        switch self {
        case .automatic:
            .automatic
        case .all:
            .all
        case .doubleColumn:
            .doubleColumn
        case .detailOnly:
            .detailOnly
        }
    }
}

enum StoredSplitViewColumn: String, Codable, CaseIterable {
    case sidebar
    case content
    case detail

    init(_ column: NavigationSplitViewColumn) {
        if column == .content {
            self = .content
        } else if column == .detail {
            self = .detail
        } else {
            self = .sidebar
        }
    }

    var value: NavigationSplitViewColumn {
        switch self {
        case .sidebar:
            .sidebar
        case .content:
            .content
        case .detail:
            .detail
        }
    }
}

struct ContentSceneState: Codable, Hashable {
    static let currentVersion = 1

    var version = currentVersion
    var hasInitializedNavigation = false
    var subscription: StoredSubscriptionSelection? = nil
    var article: StoredArticleReference? = nil
    var normalColumnVisibility = StoredSplitViewVisibility.automatic
    var preferredCompactColumn = StoredSplitViewColumn.sidebar
    var wantsArticleFullScreen = false

    static func restored(from data: Data?) -> ContentSceneState? {
        guard let data,
            let state = try? JSONDecoder().decode(Self.self, from: data),
            state.version == currentVersion
        else {
            return nil
        }
        return state
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }
}

enum SceneStorageKeys {
    static let contentState = "ContentView.sceneState.v1"
    static let iCloudSectionExpanded = "SubscriptionsView.iCloudExpanded"
}

struct ContentSceneHost: View {
    @SceneStorage(SceneStorageKeys.contentState)
    private var sceneStateData: Data?
    @AppStorage(AppPreferences.uiTestingContentSceneState)
    private var uiTestingSceneStateData: Data?

    private var usesUITestingStorage: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-ui-testing")
            || arguments.contains("-ui-testing-sample")
            || arguments.contains("-ui-testing-restoration-sample")
    }

    var body: some View {
        ContentView(restorationData: restorationBinding)
    }

    private var restorationBinding: Binding<Data?> {
        usesUITestingStorage
            ? $uiTestingSceneStateData
            : $sceneStateData
    }
}

enum StoredFeedResolution: Equatable {
    case resolved(UUID)
    case pending
    case invalid
}

enum StoredArticleResolution {
    case resolved(Article)
    case pending
    case invalid
}

@MainActor
enum ContentSceneResolver {
    static func resolveFeed(
        id: UUID,
        feeds: [Feed]
    ) -> StoredFeedResolution {
        let feedsByID = Dictionary(grouping: feeds, by: \Feed.id)
        guard var current = feedsByID[id]?.first else {
            return .pending
        }
        var visitedIDs: Set<UUID> = []

        while true {
            guard current.deletedAt == nil else { return .invalid }
            guard visitedIDs.insert(current.id).inserted else {
                return .pending
            }
            guard let destinationID = current.mergedIntoFeedID else {
                return .resolved(current.id)
            }
            guard let destination = feedsByID[destinationID]?.first else {
                return .pending
            }
            current = destination
        }
    }

    static func resolveSubscription(
        _ stored: StoredSubscriptionSelection,
        feeds: [Feed]
    ) -> SubscriptionResolution {
        switch stored {
        case .all:
            .resolved(.all)
        case .feed(let id):
            switch resolveFeed(id: id, feeds: feeds) {
            case .resolved(let resolvedID):
                .resolved(.feed(resolvedID))
            case .pending:
                .pending
            case .invalid:
                .invalid
            }
        }
    }

    static func resolveArticle(
        _ reference: StoredArticleReference,
        subscription: SubscriptionSelection,
        feeds: [Feed],
        articles: [Article]
    ) -> StoredArticleResolution {
        let activeFeedIDs = Set(feeds.filter(\.isActive).map(\.id))
        let allowedFeedIDs: Set<UUID>
        switch subscription {
        case .all:
            allowedFeedIDs = activeFeedIDs
        case .feed(let feedID):
            allowedFeedIDs = [feedID]
        }

        let eligibleArticles = articles.filter {
            allowedFeedIDs.contains($0.feedID)
        }
        if let article = eligibleArticles.first(where: {
            $0.articleKey == reference.key
        }) {
            return .resolved(article)
        }
        switch resolveFeed(id: reference.feedID, feeds: feeds) {
        case .invalid:
            return .invalid
        case .pending:
            return .pending
        case .resolved(let resolvedFeedID):
            if case .feed(let selectedFeedID) = subscription,
                selectedFeedID != resolvedFeedID
            {
                return .invalid
            }

            let remoteID = remoteArticleID(from: reference.key)
            if let article = eligibleArticles.first(where: {
                $0.feedID == resolvedFeedID
                    && remoteArticleID(from: $0.articleKey) == remoteID
            }) {
                return .resolved(article)
            }
            if let article = eligibleArticles.first(where: {
                $0.feedID == resolvedFeedID
                    && $0.id == reference.id
            }) {
                return .resolved(article)
            }
            return .pending
        }
    }

    private static func remoteArticleID(from articleKey: String) -> String {
        guard let separator = articleKey.firstIndex(of: "|") else {
            return articleKey
        }
        return String(articleKey[articleKey.index(after: separator)...])
    }
}

enum SubscriptionResolution {
    case resolved(SubscriptionSelection)
    case pending
    case invalid
}
