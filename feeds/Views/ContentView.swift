import Combine
import CoreData
import OSLog
import SwiftData
import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

private let cloudDataLogger = Logger(
    subsystem: "dev.qiyang.feeds",
    category: "CloudDataReconciliation"
)

private struct SceneResolutionSnapshot: Hashable {
    let state: ContentSceneState
    let feeds: [FeedResolutionRecord]
    let articles: [ArticleResolutionRecord]

    struct FeedResolutionRecord: Hashable {
        let id: UUID
        let feedURLString: String
        let deletedAt: Date?
        let mergedIntoFeedID: UUID?
    }

    struct ArticleResolutionRecord: Hashable {
        let id: UUID
        let articleKey: String
        let feedID: UUID
    }
}

struct ContentView: View {
    @Environment(\.feedsModelContainer) private var modelContainer
    @Environment(\.cloudDataReconciliationController)
    private var reconciliationController
    @Query(sort: \Feed.dateAdded) private var allFeeds: [Feed]
    @Binding private var restorationData: Data?
    @State private var reconciliationRevision = 0

    init(restorationData: Binding<Data?> = .constant(nil)) {
        _restorationData = restorationData
    }

    var body: some View {
        ContentNavigationView(
            allFeeds: allFeeds,
            restorationData: $restorationData
        )
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSPersistentCloudKitContainer.eventChangedNotification
            )
            .receive(on: DispatchQueue.main)
        ) { notification in
            guard
                let event = notification.userInfo?[
                    NSPersistentCloudKitContainer.eventNotificationUserInfoKey
                ] as? NSPersistentCloudKitContainer.Event,
                event.type == .import,
                event.endDate != nil,
                event.succeeded
            else {
                return
            }
            reconciliationRevision &+= 1
        }
        .task(id: reconciliationRevision) {
            guard let modelContainer, let reconciliationController else {
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(200))
                try Task.checkCancellation()
                try await reconciliationController.reconcileIfNeeded(
                    in: modelContainer
                )
            } catch {
                guard !(error is CancellationError) else { return }
                cloudDataLogger.error(
                    "Unable to reconcile imported CloudKit data: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: applicationDidBecomeActiveNotification
            )
            .receive(on: DispatchQueue.main)
        ) { _ in
            reconciliationRevision &+= 1
        }
    }
}

private var applicationDidBecomeActiveNotification: Notification.Name {
    #if canImport(UIKit)
        UIApplication.didBecomeActiveNotification
    #elseif canImport(AppKit)
        NSApplication.didBecomeActiveNotification
    #endif
}

private struct ContentNavigationView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query private var articles: [Article]
    let allFeeds: [Feed]
    @Binding private var restorationData: Data?

    init(allFeeds: [Feed], restorationData: Binding<Data?>) {
        self.allFeeds = allFeeds
        _restorationData = restorationData
        let reference = ContentSceneState.restored(
            from: restorationData.wrappedValue
        )?.article
        _articles = Query(
            filter: FeedPersistenceQueries.restoredArticlePredicate(
                reference: reference,
                candidateArticleKeys: Self.candidateArticleKeys(
                    reference: reference,
                    feeds: allFeeds
                )
            )
        )
    }

    private static func candidateArticleKeys(
        reference: StoredArticleReference?,
        feeds: [Feed]
    ) -> [String] {
        guard let reference else { return [] }
        var keys = [reference.key]
        if case .resolved(let resolvedFeedID) =
            ContentSceneResolver.resolveFeed(
                id: reference.feedID,
                feeds: feeds
            )
        {
            let remoteID: Substring
            if let separator = reference.key.firstIndex(of: "|") {
                remoteID =
                    reference.key[
                        reference.key.index(after: separator)...
                    ]
            } else {
                remoteID = reference.key[...]
            }
            keys.append("\(resolvedFeedID.uuidString)|\(remoteID)")
        }
        return Array(Set(keys)).sorted()
    }

    private var sceneState: ContentSceneState {
        ContentSceneState.restored(from: restorationData)
            ?? ContentSceneState()
    }

    private var feeds: [Feed] {
        allFeeds.filter(\.isActive)
    }

    private var activeFeedIDs: Set<UUID> {
        Set(feeds.map(\.id))
    }

    private var selectedSubscription: SubscriptionSelection? {
        guard let stored = sceneState.subscription else { return nil }
        guard
            case .resolved(let selection) =
                ContentSceneResolver
                .resolveSubscription(stored, feeds: allFeeds)
        else {
            return nil
        }
        return selection
    }

    private var selectedArticle: Article? {
        guard let reference = sceneState.article,
            let selectedSubscription
        else {
            return nil
        }
        guard
            case .resolved(let article) = ContentSceneResolver.resolveArticle(
                reference,
                subscription: selectedSubscription,
                feeds: allFeeds,
                articles: articles
            )
        else {
            return nil
        }
        return article
    }

    private var isRestoringSubscription: Bool {
        guard let stored = sceneState.subscription else { return false }
        if case .pending = ContentSceneResolver.resolveSubscription(
            stored,
            feeds: allFeeds
        ) {
            return true
        }
        return false
    }

    private var isRestoringArticle: Bool {
        guard sceneState.article != nil, selectedArticle == nil else {
            return false
        }
        if isRestoringSubscription { return true }
        guard let selectedSubscription,
            let reference = sceneState.article
        else {
            return false
        }
        if case .pending = ContentSceneResolver.resolveArticle(
            reference,
            subscription: selectedSubscription,
            feeds: allFeeds,
            articles: articles
        ) {
            return true
        }
        return false
    }

    private var isIPad: Bool {
        #if os(iOS)
            UIDevice.current.userInterfaceIdiom == .pad
        #else
            false
        #endif
    }

    private var supportsArticleFullScreen: Bool {
        isIPad && horizontalSizeClass == .regular
    }

    private var isShowingArticleFullScreen: Bool {
        supportsArticleFullScreen
            && sceneState.wantsArticleFullScreen
            && selectedArticle != nil
    }

    private var hasArticleFullScreenPresentation: Bool {
        isIPad
            && sceneState.wantsArticleFullScreen
            && selectedArticle != nil
    }

    private var shouldPersistColumnVisibility: Bool {
        #if os(iOS)
            horizontalSizeClass != .compact
        #else
            true
        #endif
    }

    private var sceneResolutionSnapshot: SceneResolutionSnapshot {
        SceneResolutionSnapshot(
            state: sceneState,
            feeds: allFeeds.map {
                .init(
                    id: $0.id,
                    feedURLString: $0.feedURLString,
                    deletedAt: $0.deletedAt,
                    mergedIntoFeedID: $0.mergedIntoFeedID
                )
            },
            articles: articles.map {
                .init(
                    id: $0.id,
                    articleKey: $0.articleKey,
                    feedID: $0.feedID
                )
            }
        )
    }

    var body: some View {
        NavigationSplitView(
            columnVisibility: columnVisibilityBinding,
            preferredCompactColumn: preferredCompactColumnBinding
        ) {
            SubscriptionsView(selection: subscriptionBinding)
                #if os(macOS)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260)
                #endif
        } content: {
            Group {
                if isRestoringSubscription {
                    ContentUnavailableView(
                        "Restoring Feed",
                        systemImage: "arrow.trianglehead.2.clockwise.rotate.90",
                        description: Text(
                            "Waiting for this feed to finish syncing from iCloud."
                        )
                    )
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Show All") {
                                showAllArticles()
                            }
                            .accessibilityIdentifier(
                                "cancelFeedRestorationButton"
                            )
                        }
                    }
                } else {
                    FeedArticlesView(
                        selection: selectedSubscription,
                        selectedArticleKey: selectedArticleKeyBinding
                    )
                }
            }
            #if os(macOS)
                .navigationSplitViewColumnWidth(min: 300, ideal: 380)
            #endif
        } detail: {
            if let selectedArticle {
                ArticleDetailView(
                    article: selectedArticle,
                    isFullScreen: hasArticleFullScreenPresentation,
                    onToggleFullScreen: toggleArticleFullScreen
                )
                .id(selectedArticle.id)
            } else if isRestoringArticle {
                ContentUnavailableView(
                    "Restoring Article",
                    systemImage: "arrow.trianglehead.2.clockwise.rotate.90",
                    description: Text(
                        "Waiting for this article to finish syncing from iCloud."
                    )
                )
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Cancel") {
                            cancelArticleRestoration()
                        }
                        .accessibilityIdentifier(
                            "cancelArticleRestorationButton"
                        )
                    }
                }
            } else {
                ContentUnavailableView(
                    "Select an Article",
                    systemImage: "text.page",
                    description: Text("Article content appears here.")
                )
            }
        }
        .task(id: sceneResolutionSnapshot) {
            normalizeSceneState()
        }
    }

    private var columnVisibilityBinding: Binding<NavigationSplitViewVisibility>
    {
        Binding(
            get: {
                isShowingArticleFullScreen
                    ? .detailOnly
                    : sceneState.normalColumnVisibility.value
            },
            set: { visibility in
                if isShowingArticleFullScreen {
                    guard visibility != .detailOnly else { return }
                    updateSceneState { state in
                        state.wantsArticleFullScreen = false
                        if shouldPersistColumnVisibility {
                            state.normalColumnVisibility = .init(visibility)
                        }
                    }
                } else if shouldPersistColumnVisibility {
                    updateSceneState {
                        $0.normalColumnVisibility = .init(visibility)
                    }
                }
            }
        )
    }

    private var preferredCompactColumnBinding:
        Binding<NavigationSplitViewColumn>
    {
        Binding(
            get: { sceneState.preferredCompactColumn.value },
            set: { column in
                updateSceneState {
                    $0.preferredCompactColumn = .init(column)
                }
            }
        )
    }

    private var subscriptionBinding: Binding<SubscriptionSelection?> {
        Binding(
            get: { selectedSubscription },
            set: { selection in
                if selection == nil, isRestoringSubscription {
                    return
                }
                updateSceneState { state in
                    state.hasInitializedNavigation = true
                    state.subscription = selection.map {
                        StoredSubscriptionSelection($0)
                    }
                    state.article = nil
                    state.wantsArticleFullScreen = false
                    state.preferredCompactColumn =
                        selection == nil
                        ? .sidebar : .content
                }
            }
        )
    }

    private var selectedArticleKeyBinding: Binding<String?> {
        Binding(
            get: { sceneState.article?.key },
            set: { articleKey in
                if articleKey == nil, isRestoringArticle {
                    return
                }
                guard let articleKey else {
                    updateSceneState { state in
                        state.article = nil
                        state.wantsArticleFullScreen = false
                        state.preferredCompactColumn = .content
                    }
                    return
                }
                guard let selectedSubscription,
                    let article = article(
                        matching: articleKey,
                        in: selectedSubscription
                    )
                else {
                    return
                }
                updateSceneState { state in
                    state.article = StoredArticleReference(article: article)
                    state.preferredCompactColumn = .detail
                }
            }
        )
    }

    private func article(
        matching articleKey: String,
        in selection: SubscriptionSelection
    ) -> Article? {
        let feedIDs: [UUID]
        switch selection {
        case .all:
            feedIDs = activeFeedIDs.sorted {
                $0.uuidString < $1.uuidString
            }
        case .feed(let feedID):
            guard activeFeedIDs.contains(feedID) else { return nil }
            feedIDs = [feedID]
        }
        return try? modelContext.fetch(
            FeedPersistenceQueries.articles(
                articleKey: articleKey,
                feedIDs: feedIDs
            )
        ).first
    }

    @MainActor
    private func normalizeSceneState() {
        var next = sceneState

        if !next.hasInitializedNavigation {
            if next.subscription != nil {
                next.hasInitializedNavigation = true
            } else if let firstFeed = feeds.first {
                next.hasInitializedNavigation = true
                next.subscription = .feed(firstFeed.id)
                next.preferredCompactColumn = .content
            }
        }

        guard let storedSubscription = next.subscription else {
            if next.hasInitializedNavigation {
                next.article = nil
                next.wantsArticleFullScreen = false
            }
            if !isIPad {
                next.wantsArticleFullScreen = false
            }
            commit(next)
            return
        }

        switch ContentSceneResolver.resolveSubscription(
            storedSubscription,
            feeds: allFeeds
        ) {
        case .pending:
            break
        case .invalid:
            next.subscription = .all
            next.article = nil
            next.wantsArticleFullScreen = false
            next.preferredCompactColumn = .content
        case .resolved(let selection):
            next.subscription = .init(selection)
            if let reference = next.article {
                switch ContentSceneResolver.resolveArticle(
                    reference,
                    subscription: selection,
                    feeds: allFeeds,
                    articles: articles
                ) {
                case .resolved(let article):
                    next.article = StoredArticleReference(article: article)
                case .pending:
                    break
                case .invalid:
                    next.article = nil
                    next.wantsArticleFullScreen = false
                    next.preferredCompactColumn = .content
                }
            } else {
                next.wantsArticleFullScreen = false
            }
        }

        if !isIPad {
            next.wantsArticleFullScreen = false
        }
        commit(next)
    }

    private func toggleArticleFullScreen() {
        guard isIPad, selectedArticle != nil else { return }
        updateSceneState { state in
            if state.wantsArticleFullScreen {
                state.wantsArticleFullScreen = false
                if horizontalSizeClass == .compact {
                    state.preferredCompactColumn = .content
                }
            } else {
                guard supportsArticleFullScreen else { return }
                if state.normalColumnVisibility == .detailOnly {
                    state.normalColumnVisibility = .automatic
                }
                state.wantsArticleFullScreen = true
            }
        }
    }

    private func showAllArticles() {
        updateSceneState { state in
            state.hasInitializedNavigation = true
            state.subscription = .all
            state.article = nil
            state.wantsArticleFullScreen = false
            state.preferredCompactColumn = .content
        }
    }

    private func cancelArticleRestoration() {
        updateSceneState { state in
            state.article = nil
            state.wantsArticleFullScreen = false
            state.preferredCompactColumn = .content
        }
    }

    private func updateSceneState(
        _ update: (inout ContentSceneState) -> Void
    ) {
        var next = sceneState
        update(&next)
        commit(next)
    }

    private func commit(_ next: ContentSceneState) {
        if let stored = ContentSceneState.restored(from: restorationData),
            stored == next
        {
            return
        }
        restorationData = next.encoded()
    }
}

extension StoredSubscriptionSelection {
    fileprivate init(_ selection: SubscriptionSelection) {
        switch selection {
        case .all:
            self = .all
        case .feed(let id):
            self = .feed(id)
        }
    }
}

extension StoredArticleReference {
    fileprivate init(article: Article) {
        self.init(
            id: article.id,
            key: article.articleKey,
            feedID: article.feedID
        )
    }
}

#Preview("Populated") {
    @Previewable @State var restorationData: Data?
    let container = PreviewSampleData.makeContainer()

    ContentView(restorationData: $restorationData)
        .environment(\.feedsModelContainer, container)
        .environment(
            \.cloudDataReconciliationController,
            CloudDataReconciliationController()
        )
        .modelContainer(container)
}

#Preview("Empty State") {
    @Previewable @State var restorationData: Data?
    let container = PreviewSampleData.makeContainer(populated: false)

    ContentView(restorationData: $restorationData)
        .environment(\.feedsModelContainer, container)
        .environment(
            \.cloudDataReconciliationController,
            CloudDataReconciliationController()
        )
        .modelContainer(container)
}
