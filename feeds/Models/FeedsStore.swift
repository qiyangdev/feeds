import SwiftData

enum FeedsStore {
    nonisolated static let cloudKitContainerIdentifier =
        "iCloud.dev.qiyang.feeds"

    nonisolated static var schema: Schema {
        Schema([Feed.self, Article.self])
    }

    nonisolated static func configuration(
        isStoredInMemoryOnly: Bool = false,
        cloudKitDatabase: ModelConfiguration.CloudKitDatabase
    ) -> ModelConfiguration {
        ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: isStoredInMemoryOnly,
            cloudKitDatabase: cloudKitDatabase
        )
    }

    nonisolated static func makeContainer(
        isStoredInMemoryOnly: Bool = false,
        cloudKitDatabase: ModelConfiguration.CloudKitDatabase
    ) throws -> ModelContainer {
        let configuration = configuration(
            isStoredInMemoryOnly: isStoredInMemoryOnly,
            cloudKitDatabase: cloudKitDatabase
        )
        return try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
    }
}
