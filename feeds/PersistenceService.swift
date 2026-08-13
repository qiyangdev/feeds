import SwiftData
import SwiftUI

private struct ModelContainerEnvironmentKey: EnvironmentKey {
    static let defaultValue: ModelContainer? = nil
}

extension EnvironmentValues {
    var feedsModelContainer: ModelContainer? {
        get { self[ModelContainerEnvironmentKey.self] }
        set { self[ModelContainerEnvironmentKey.self] = newValue }
    }
}

@MainActor
enum PersistenceService {
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
