import SwiftData
import SwiftUI

private struct ModelContainerEnvironmentKey: EnvironmentKey {
    static let defaultValue: ModelContainer? = nil
}

private struct CloudDataReconciliationControllerEnvironmentKey:
    EnvironmentKey
{
    static let defaultValue: CloudDataReconciliationController? = nil
}

extension EnvironmentValues {
    var feedsModelContainer: ModelContainer? {
        get { self[ModelContainerEnvironmentKey.self] }
        set { self[ModelContainerEnvironmentKey.self] = newValue }
    }

    var cloudDataReconciliationController: CloudDataReconciliationController?
    {
        get { self[CloudDataReconciliationControllerEnvironmentKey.self] }
        set {
            self[CloudDataReconciliationControllerEnvironmentKey.self] =
                newValue
        }
    }
}

nonisolated enum PersistenceService {
    static func save(
        in modelContext: ModelContext,
        changes: () throws -> Void
    ) throws {
        do {
            try modelContext.transaction {
                try changes()
            }
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}
