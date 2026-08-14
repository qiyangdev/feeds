#if DEBUG
    import CloudKit
    import CoreData
    import Foundation
    import SwiftData

    enum CloudKitSchemaInitializer {
        nonisolated static let launchArgument = "--initialize-cloudkit-schema"

        /// The caller must use an in-memory, CloudKit-disabled SwiftData container
        /// while this mode is active. The initializer temporarily opens the app's
        /// persistent store through Core Data and unloads it before returning.
        nonisolated static func isRequested(
            arguments: [String] = ProcessInfo.processInfo.arguments
        ) -> Bool {
            arguments.contains(launchArgument)
        }

        /// Initializes the development schema only when `launchArgument` is
        /// present. Returns `false` without touching CloudKit otherwise.
        @discardableResult
        nonisolated static func initializeIfRequested(
            arguments: [String] = ProcessInfo.processInfo.arguments
        ) async throws -> Bool {
            guard isRequested(arguments: arguments) else {
                return false
            }

            try await verifyCloudKitAccess()
            try initializeDevelopmentSchema()
            return true
        }

        private nonisolated static func verifyCloudKitAccess() async throws {
            let container = CKContainer(
                identifier: FeedsStore.cloudKitContainerIdentifier
            )
            let accountStatus = try await container.accountStatus()

            guard accountStatus == .available else {
                throw CloudKitSchemaInitializationError.accountUnavailable(
                    String(describing: accountStatus)
                )
            }

            let database = container.privateCloudDatabase
            let zone = CKRecordZone(
                zoneName: "Feeds.SchemaPreflight.\(UUID().uuidString)"
            )
            let savedZone = try await database.save(zone)
            _ = try? await database.deleteRecordZone(withID: savedZone.zoneID)
        }

        private nonisolated static func initializeDevelopmentSchema() throws {
            try autoreleasepool {
                let configuration = FeedsStore.configuration(
                    cloudKitDatabase: .private(
                        FeedsStore.cloudKitContainerIdentifier
                    )
                )
                let description = NSPersistentStoreDescription(
                    url: configuration.url
                )
                description.cloudKitContainerOptions =
                    NSPersistentCloudKitContainerOptions(
                        containerIdentifier:
                            FeedsStore.cloudKitContainerIdentifier
                    )
                description.shouldAddStoreAsynchronously = false
                description.setOption(
                    true as NSNumber,
                    forKey: NSPersistentHistoryTrackingKey
                )
                description.setOption(
                    true as NSNumber,
                    forKey:
                        NSPersistentStoreRemoteChangeNotificationPostOptionKey
                )

                guard
                    let managedObjectModel =
                        NSManagedObjectModel.makeManagedObjectModel(
                            for: FeedsStore.schema
                        )
                else {
                    throw CloudKitSchemaInitializationError
                        .managedObjectModelUnavailable
                }

                let container = NSPersistentCloudKitContainer(
                    name: "Feeds",
                    managedObjectModel: managedObjectModel
                )
                container.persistentStoreDescriptions = [description]

                let semaphore = DispatchSemaphore(value: 0)
                let lock = NSLock()
                var loadError: Error?
                container.loadPersistentStores { _, error in
                    lock.lock()
                    loadError = error
                    lock.unlock()
                    semaphore.signal()
                }

                semaphore.wait()

                lock.lock()
                let persistentStoreLoadError = loadError
                lock.unlock()
                if let persistentStoreLoadError {
                    throw persistentStoreLoadError
                }

                let coordinator = container.persistentStoreCoordinator
                guard let store = coordinator.persistentStores.first else {
                    throw CloudKitSchemaInitializationError
                        .persistentStoreUnavailable
                }

                do {
                    try container.initializeCloudKitSchema()
                    try coordinator.remove(store)
                } catch {
                    if coordinator.persistentStores.contains(store) {
                        try? coordinator.remove(store)
                    }
                    throw error
                }
            }
        }
    }

    private enum CloudKitSchemaInitializationError: LocalizedError {
        case accountUnavailable(String)
        case managedObjectModelUnavailable
        case persistentStoreUnavailable

        var errorDescription: String? {
            switch self {
            case .accountUnavailable(let status):
                "The iCloud account is unavailable (\(status))."
            case .managedObjectModelUnavailable:
                "Couldn’t create a Core Data model from the SwiftData schema."
            case .persistentStoreUnavailable:
                "The temporary Core Data store did not finish loading."
            }
        }
    }
#endif
