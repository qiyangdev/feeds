import OSLog
import SwiftData
import SwiftUI

#if os(iOS)
    import UIKit
#endif

private let cloudDataLogger = Logger(
    subsystem: "dev.qiyang.feeds",
    category: "CloudDataReconciliation"
)

private struct CloudDataSnapshot: Hashable {
    let feeds: [String]
    let articles: [String]
}

private struct SceneResolutionSnapshot: Hashable {
    let state: ContentSceneState
    let feeds: [String]
    let articles: [String]
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \Feed.dateAdded) private var allFeeds: [Feed]
    @Query private var articles: [Article]
    @Binding private var restorationData: Data?

    init(restorationData: Binding<Data?> = .constant(nil)) {
        _restorationData = restorationData
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
        guard case .resolved(let selection) = ContentSceneResolver
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
        guard case .resolved(let article) = ContentSceneResolver.resolveArticle(
            reference,
            subscription: selectedSubscription,
            feeds: allFeeds,
            articles: articles
        ) else {
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

    private var cloudDataSnapshot: CloudDataSnapshot {
        CloudDataSnapshot(
            feeds: allFeeds
                .map {
                    "\($0.id.uuidString)|\($0.feedURLString)|\($0.deletedAt?.timeIntervalSinceReferenceDate ?? -1)|\($0.mergedIntoFeedID?.uuidString ?? "-")"
                }
                .sorted(),
            articles: articles
                .map { "\($0.id.uuidString)|\($0.articleKey)|\($0.feedID.uuidString)" }
                .sorted()
        )
    }

    private var sceneResolutionSnapshot: SceneResolutionSnapshot {
        SceneResolutionSnapshot(
            state: sceneState,
            feeds: cloudDataSnapshot.feeds,
            articles: cloudDataSnapshot.articles
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
        .task(id: cloudDataSnapshot) {
            do {
                try CloudDataReconciler.reconcile(in: modelContext)
            } catch {
                cloudDataLogger.error(
                    "Unable to reconcile imported CloudKit data: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        .task(id: sceneResolutionSnapshot) {
            normalizeSceneState()
        }
    }

    private var columnVisibilityBinding:
        Binding<NavigationSplitViewVisibility>
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
                    state.preferredCompactColumn = selection == nil
                        ? .sidebar : .content
                }
            }
        )
    }

    private var selectedArticleKeyBinding: Binding<String?> {
        Binding(
            get: { selectedArticle?.articleKey },
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
        articles.first { article in
            guard article.articleKey == articleKey,
                activeFeedIDs.contains(article.feedID)
            else {
                return false
            }
            switch selection {
            case .all:
                return true
            case .feed(let feedID):
                return article.feedID == feedID
            }
        }
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

private extension StoredSubscriptionSelection {
    init(_ selection: SubscriptionSelection) {
        switch selection {
        case .all:
            self = .all
        case .feed(let id):
            self = .feed(id)
        }
    }
}

private extension StoredArticleReference {
    init(article: Article) {
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
        .modelContainer(container)
}

#Preview("Empty State") {
    @Previewable @State var restorationData: Data?
    let container = PreviewSampleData.makeContainer(populated: false)

    ContentView(restorationData: $restorationData)
        .environment(\.feedsModelContainer, container)
        .modelContainer(container)
}
