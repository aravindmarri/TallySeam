import Foundation
import SwiftData

/// Owns the SwiftData container. Local only: CloudKit is explicitly disabled.
@MainActor
final class PersistenceService {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init(inMemory: Bool = false) throws {
        container = try Self.makeContainer(inMemory: inMemory)
    }

    /// Opens (or creates) a store at a specific file. Used by tests that close and reopen a real on-disk store.
    init(storeURL: URL) throws {
        let schema = Schema(versionedSchema: TallySeamCurrentSchema.self)
        let configuration = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, migrationPlan: TallySeamMigrationPlan.self, configurations: [configuration])
    }

    static func makeContainer(inMemory: Bool) throws -> ModelContainer {
        let schema = Schema(versionedSchema: TallySeamCurrentSchema.self)
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(schema: schema, url: try storeURL(), cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, migrationPlan: TallySeamMigrationPlan.self, configurations: [configuration])
    }

    /// Application Support/Store/TallySeam.store, protected with iOS Data Protection.
    /// `completeUntilFirstUserAuthentication` keeps the store encrypted at rest until the first unlock after boot.
    static func storeURL() throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Store", directoryHint: .isDirectory)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dir.path)
        #endif
        return dir.appending(path: "TallySeam.store")
    }

    /// Seeds system categories and the settings row on first launch. Idempotent.
    /// Inserts no transactions, payment methods or other sample data.
    func seedDefaultsIfNeeded() throws {
        if try context.fetchCount(FetchDescriptor<SpendingCategory>()) == 0 {
            DefaultCategories.makeAll().forEach { context.insert($0) }
        }
        if try context.fetchCount(FetchDescriptor<AppSettings>()) == 0 {
            context.insert(AppSettings())
        }
        if try context.fetchCount(FetchDescriptor<SubscriptionType>()) == 0 {
            DefaultSubscriptionTypes.makeAll().forEach { context.insert($0) }
        }
        if context.hasChanges { try context.save() }
    }

    func settings() throws -> AppSettings {
        if let existing = try context.fetch(FetchDescriptor<AppSettings>()).first { return existing }
        let s = AppSettings()
        context.insert(s)
        try context.save()
        return s
    }
}
