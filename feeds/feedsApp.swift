import SwiftData
import SwiftUI

private enum UITestSampleData {
    static let firstFeedID = UUID(
        uuidString: "11111111-1111-1111-1111-111111111111"
    )!
    static let firstArticleID = UUID(
        uuidString: "11111111-1111-1111-1111-111111111112"
    )!
    static let readArticleID = UUID(
        uuidString: "11111111-1111-1111-1111-111111111113"
    )!
    static let secondFeedID = UUID(
        uuidString: "22222222-2222-2222-2222-222222222221"
    )!
    static let secondArticleID = UUID(
        uuidString: "22222222-2222-2222-2222-222222222222"
    )!
}

@main
struct feedsApp: App {
    private let sharedModelContainer: ModelContainer = {
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        AppPreferences.migrateLegacyReadingTheme()
        let isUITesting =
            arguments.contains("-ui-testing")
            || arguments.contains("-ui-testing-sample")
            || arguments.contains("-ui-testing-restoration-sample")
        if arguments.contains("-ui-testing-reset-preferences") {
            UserDefaults.standard.removeObject(
                forKey: AppPreferences.hidesReadArticles
            )
            for key in AppPreferences.articleReadingKeys {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        if arguments.contains("-ui-testing-reset-scene-state") {
            UserDefaults.standard.removeObject(
                forKey: AppPreferences.uiTestingContentSceneState
            )
        }
        let isUnitTesting = environment["XCTestConfigurationFilePath"] != nil
        #if DEBUG
            let isInitializingCloudKitSchema =
                CloudKitSchemaInitializer.isRequested(arguments: arguments)
        #else
            let isInitializingCloudKitSchema = false
        #endif
        let usesEphemeralStore =
            isUITesting || isUnitTesting || isInitializingCloudKitSchema

        do {
            let container = try FeedsStore.makeContainer(
                isStoredInMemoryOnly: usesEphemeralStore,
                cloudKitDatabase: usesEphemeralStore
                    ? .none
                    : .private(FeedsStore.cloudKitContainerIdentifier)
            )
            container.mainContext.autosaveEnabled = false
            if !isInitializingCloudKitSchema {
                try CloudDataReconciler.reconcile(in: container.mainContext)
            }
            if arguments.contains("-ui-testing-sample")
                || arguments.contains("-ui-testing-restoration-sample")
            {
                let feed = Feed(
                    id: UITestSampleData.firstFeedID,
                    feedURLString: "https://example.com/feed.xml",
                    title: "Example Feed",
                    siteURLString: "https://example.com",
                    dateAdded: Date(timeIntervalSinceReferenceDate: 1)
                )
                container.mainContext.insert(feed)
                container.mainContext.insert(
                    Article(
                        id: UITestSampleData.firstArticleID,
                        articleKey: "\(feed.id.uuidString)|example-article",
                        feedID: feed.id,
                        feedTitle: feed.title,
                        title: "Example Article",
                        urlString: "https://example.com/article",
                        summaryText: "An example article for testing the three-column navigation.",
                        publishedAt: Date(timeIntervalSinceReferenceDate: 3),
                        savedAt: Date(timeIntervalSinceReferenceDate: 3)
                    )
                )
                if arguments.contains("-ui-testing-read-sample") {
                    container.mainContext.insert(
                        Article(
                            id: UITestSampleData.readArticleID,
                            articleKey: "\(feed.id.uuidString)|read-example-article",
                            feedID: feed.id,
                            feedTitle: feed.title,
                            title: "Read Example Article",
                            urlString: "https://example.com/read-article",
                            summaryText:
                                "A read article used to verify the global filter preference.",
                            publishedAt: Date(timeIntervalSinceReferenceDate: 2),
                            savedAt: Date(timeIntervalSinceReferenceDate: 2),
                            isRead: true
                        )
                    )
                }
                if arguments.contains("-ui-testing-restoration-sample") {
                    let secondFeed = Feed(
                        id: UITestSampleData.secondFeedID,
                        feedURLString: "https://second.example.com/feed.xml",
                        title: "Second Feed",
                        siteURLString: "https://second.example.com",
                        dateAdded: Date(timeIntervalSinceReferenceDate: 2)
                    )
                    container.mainContext.insert(secondFeed)
                    container.mainContext.insert(
                        Article(
                            id: UITestSampleData.secondArticleID,
                            articleKey: "\(secondFeed.id.uuidString)|second-example-article",
                            feedID: secondFeed.id,
                            feedTitle: secondFeed.title,
                            title: "Second Example Article",
                            urlString: "https://second.example.com/article",
                            summaryText: "A second article used to verify scene restoration.",
                            publishedAt: Date(
                                timeIntervalSinceReferenceDate: 4
                            ),
                            savedAt: Date(
                                timeIntervalSinceReferenceDate: 4
                            )
                        )
                    )
                }
                try container.mainContext.save()
            }
            return container
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    @AppStorage(AppPreferences.appAppearanceMode)
    private var appAppearanceMode = AppAppearanceMode.system

    var body: some Scene {
        WindowGroup {
            ContentSceneHost()
                .environment(\.feedsModelContainer, sharedModelContainer)
                .preferredColorScheme(appAppearanceMode.colorScheme)
                #if DEBUG
                    .task {
                        guard CloudKitSchemaInitializer.isRequested() else {
                            return
                        }
                        do {
                            _ =
                                try await CloudKitSchemaInitializer
                            .initializeIfRequested()
                            print(
                                "CloudKit development schema initialized successfully. Remove \(CloudKitSchemaInitializer.launchArgument) before relaunching."
                            )
                        } catch {
                            fatalError(
                                "Unable to initialize CloudKit schema: \(error)"
                            )
                        }
                    }
                #endif
        }
        .modelContainer(sharedModelContainer)
        #if os(macOS)
            .defaultSize(width: 1180, height: 760)
        #endif
    }
}
