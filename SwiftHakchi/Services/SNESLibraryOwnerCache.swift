import Foundation

struct SNESLibraryOwnerCacheKey: Hashable, Sendable {
    let reference: SNESLibraryInstallationReference
    let deviceVersion: UInt16
    let workspaceRoot: URL
    let backupRoots: [URL]
    let journalRoot: URL
}

/// Process-local Mac evidence only. USB sessions and inventories never belong here.
actor SNESLibraryOwnerCache<Owner: Sendable> {
    private var entries: [SNESLibraryOwnerCacheKey: Owner] = [:]
    private var insertionOrder: [SNESLibraryOwnerCacheKey] = []

    func value(for key: SNESLibraryOwnerCacheKey,
               validate: @Sendable (Owner) throws -> Void,
               load: @Sendable () async throws -> Owner) async throws -> Owner {
        try Task.checkCancellation()
        if let saved = entries[key] {
            do {
                try validate(saved)
                try Task.checkCancellation()
                return saved
            } catch {
                entries.removeValue(forKey: key)
                insertionOrder.removeAll { $0 == key }
                throw error
            }
        }
        let value = try await load()
        try Task.checkCancellation()
        try validate(value)
        try Task.checkCancellation()
        insertionOrder.removeAll { $0 == key }
        while insertionOrder.count >= 4 {
            entries.removeValue(forKey: insertionOrder.removeFirst())
        }
        entries[key] = value
        insertionOrder.append(key)
        return value
    }
}
