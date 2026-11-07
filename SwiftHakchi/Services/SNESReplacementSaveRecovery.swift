import Foundation

/// An inert comparison, not proof that a console is connected or a retry permit.
struct SNESReplacementSaveRecovery: Sendable {
    let copiedPaths: [String], pendingPaths: [String], conflictingPaths: [String]
    /// Group consistency only; a retry still needs a live-console check and separate authorization.
    let canResume: Bool

    static func inspect(plan: SNESReplacementSavePlan, observed: SNESLibraryInventory) throws -> Self {
        try plan.validate(); let groups = try plan.protectedGroups()
        let before = plan.destinationInventory
        guard observed.hwid == before.hwid, observed.catalogSHA256 == before.catalogSHA256,
              observed.selection == before.selection, observed.menus == before.menus,
              observed.capacity.objects == before.capacity.objects,
              observed.capacity.namespaceReady == before.capacity.namespaceReady,
              observed.capacity.descriptionStoreReady == before.capacity.descriptionStoreReady,
              observed.capacity.blockSize == before.capacity.blockSize, observed.totalBytes == before.totalBytes,
              observed.excludedMenuID == nil, !observed.incompleteNamespace else { throw SNESLibraryInventory.failure() }
        let originalFiles = Dictionary(uniqueKeysWithValues: before.files.map { ($0.path, $0) })
        let currentFiles = Dictionary(uniqueKeysWithValues: observed.files.map { ($0.path, $0) })
        let originalDirs = Dictionary(uniqueKeysWithValues: before.directories.map { ($0.path, $0) })
        let currentDirs = Dictionary(uniqueKeysWithValues: observed.directories.map { ($0.path, $0) })
        let planned = Dictionary(uniqueKeysWithValues: plan.files.map { ($0.path, $0) })
        for (path, prior) in originalFiles {
            guard let current = currentFiles[path], current.byteCount == prior.byteCount,
                  current.sha256 == prior.sha256, current.mode == prior.mode, current.modified == prior.modified else {
                throw SNESLibraryInventory.failure()
            }
        }
        for (path, prior) in originalDirs { guard currentDirs[path] == prior else { throw SNESLibraryInventory.failure() } }
        for path in currentFiles.keys where originalFiles[path] == nil {
            guard planned[path] != nil else { throw SNESLibraryInventory.failure() }
        }
        for path in currentDirs.keys where originalDirs[path] == nil {
            guard planned[path] != nil || planned.keys.contains(where: { $0.hasPrefix(path + "/") }) else { throw SNESLibraryInventory.failure() }
        }
        var copied: [String] = [], pending: [String] = [], conflicting: [String] = []
        for entry in plan.files {
            if let current = currentFiles[entry.path] {
                if current.byteCount == entry.byteCount && current.sha256 == entry.sourceSHA256 && current.mode == entry.sourceMode && current.modified == entry.sourceModified { copied.append(entry.path) }
                else { conflicting.append(entry.path) }
            } else if currentDirs[entry.path] != nil { conflicting.append(entry.path) }
            else { pending.append(entry.path) }
        }
        let completed = Set(copied)
        let wholeGroups = groups.allSatisfy { group in
            let count = group.paths.filter { completed.contains($0) }.count
            return count == 0 || count == group.paths.count
        }
        try plan.validate()
        return .init(copiedPaths: copied.sorted(), pendingPaths: pending.sorted(), conflictingPaths: conflicting.sorted(),
                     canResume: conflicting.isEmpty && wholeGroups)
    }
}
