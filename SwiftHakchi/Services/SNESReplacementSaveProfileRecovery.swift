import Foundation

/// A comparison of inventories; it neither proves a live connection nor
/// authorizes a retry, deletion or journal completion.
enum SNESReplacementSaveProfileRecovery {
    enum Outcome: Equatable, Sendable { case absent, reserved, published, needsReview }

    /// Classify an unused suspend slot inside an existing game profile. This
    /// compares inventories only and does not authorize any console write.
    static func inspectExistingSuspendPoint(review: SNESReplacementSaveEnvelope, group: Int,
                                            observed: SNESLibraryInventory) throws -> Outcome {
        try review.validate()
        let before = review.plan.destinationInventory, groups = try review.plan.protectedGroups()
        guard groups.indices.contains(group) else { throw SNESLibraryInventory.failure() }
        let selected = groups[group]
        guard case let .suspendPoint(number) = selected.kind else { throw SNESLibraryInventory.failure() }
        let profile = "clover/profiles/0/" + selected.gameCode, slot = profile + "/suspendpoint\(number)"
        guard before.directories.contains(where: { $0.path == profile && $0.mode == 0o700 }),
              !before.directories.contains(where: { $0.path == slot || $0.path.hasPrefix(slot + "/") }),
              !before.files.contains(where: { $0.path == slot || $0.path.hasPrefix(slot + "/") }),
              selected.paths.allSatisfy({ $0.hasPrefix(slot + "/") }) else { throw SNESLibraryInventory.failure() }
        let assessment = try SNESReplacementSaveRecovery.inspect(plan: review.plan, observed: observed)
        let selectedPaths = Set(selected.paths)
        guard Set(assessment.copiedPaths).isSubset(of: selectedPaths),
              Set(assessment.conflictingPaths).isSubset(of: selectedPaths) else { throw SNESLibraryInventory.failure() }
        let directories = observed.directories.filter { $0.path == slot || $0.path.hasPrefix(slot + "/") }
        let files = observed.files.filter { $0.path.hasPrefix(slot + "/") }
        func finish(_ outcome: Outcome) throws -> Outcome { try review.validate(); return outcome }
        guard directories.allSatisfy({ $0.mode == 0o700 }) else { return try finish(.needsReview) }
        if directories.isEmpty && files.isEmpty { return try finish(.absent) }
        if directories.count == 1 && directories[0].path == slot && files.isEmpty { return try finish(.reserved) }
        guard Set(assessment.copiedPaths) == selectedPaths, assessment.conflictingPaths.isEmpty,
              Set(files.map(\.path)) == selectedPaths else { return try finish(.needsReview) }
        var expected: Set<String> = [slot]
        for path in selected.paths {
            var parent = String(path[..<path.lastIndex(of: "/")!])
            while parent != slot {
                expected.insert(parent)
                guard let slash = parent.lastIndex(of: "/") else { throw SNESLibraryInventory.failure() }
                parent = String(parent[..<slash])
            }
        }
        guard Set(directories.map(\.path)) == expected else { return try finish(.needsReview) }
        return try finish(.published)
    }
    /// Compare a previously verified publication with a later game-test
    /// inventory. This reports changes for review; it grants no write or
    /// completion permission and does not authenticate either observation.
    static func changesAfterGameTest(review: SNESReplacementSaveEnvelope, group: Int,
                                     published: SNESLibraryInventory, observed: SNESLibraryInventory) throws -> [String] {
        guard try inspect(review: review, group: group, observed: published) == .published else { throw SNESLibraryInventory.failure() }
        let groups = try review.plan.protectedGroups()
        guard groups.indices.contains(group) else { throw SNESLibraryInventory.failure() }
        let profile = "clover/profiles/0/" + groups[group].gameCode
        let allowed = Set(groups[group].paths + [profile + "/cartridge.sram", profile + "/cartridge.sram.hash",
                                               profile + "/save/system-save.json/data", profile + "/save/system-save.json/hash"])
        guard observed.hwid == published.hwid, observed.catalogSHA256 == published.catalogSHA256,
              observed.selection == published.selection, observed.menus == published.menus,
              observed.capacity.objects == published.capacity.objects,
              observed.capacity.namespaceReady == published.capacity.namespaceReady,
              observed.capacity.descriptionStoreReady == published.capacity.descriptionStoreReady,
              observed.capacity.blockSize == published.capacity.blockSize,
              observed.totalBytes == published.totalBytes,
              observed.excludedMenuID == nil, !observed.incompleteNamespace else { throw SNESLibraryInventory.failure() }
        let beforeFiles = Dictionary(uniqueKeysWithValues: published.files.map { ($0.path, $0) })
        let afterFiles = Dictionary(uniqueKeysWithValues: observed.files.map { ($0.path, $0) })
        for pair in [[profile + "/cartridge.sram", profile + "/cartridge.sram.hash"],
                     [profile + "/save/system-save.json/data", profile + "/save/system-save.json/hash"]] {
            let count = pair.filter { afterFiles[$0] != nil }.count
            guard count == 0 || count == pair.count else { throw SNESLibraryInventory.failure() }
        }
        let beforeDirs = Dictionary(uniqueKeysWithValues: published.directories.map { ($0.path, $0) })
        let afterDirs = Dictionary(uniqueKeysWithValues: observed.directories.map { ($0.path, $0) })
        var changed: [String] = []
        for (path, prior) in beforeFiles {
            guard let current = afterFiles[path], current.mode == prior.mode else { throw SNESLibraryInventory.failure() }
            if current.byteCount != prior.byteCount || current.sha256 != prior.sha256 || current.modified != prior.modified {
                guard allowed.contains(path) else { throw SNESLibraryInventory.failure() }
                changed.append(path)
            }
        }
        for path in afterFiles.keys where beforeFiles[path] == nil {
            guard allowed.contains(path) else { throw SNESLibraryInventory.failure() }
            changed.append(path)
        }
        for (path, prior) in beforeDirs { guard afterDirs[path] == prior else { throw SNESLibraryInventory.failure() } }
        for path in afterDirs.keys where beforeDirs[path] == nil {
            guard allowed.contains(where: { $0.hasPrefix(path + "/") }) else { throw SNESLibraryInventory.failure() }
        }
        try review.validate()
        return changed.sorted()
    }
    static func inspect(review: SNESReplacementSaveEnvelope, group: Int, observed: SNESLibraryInventory) throws -> Outcome {
        let groups = try review.plan.protectedGroups()
        guard groups.indices.contains(group) else { throw SNESLibraryInventory.failure() }
        let originalProfile = "clover/profiles/0/" + groups[group].gameCode
        let before = review.plan.destinationInventory
        if before.directories.contains(where: { $0.path == originalProfile }) || before.files.contains(where: { $0.path == originalProfile }) {
            return try inspectExistingSuspendPoint(review: review, group: group, observed: observed)
        }
        let selected = try SNESReplacementSaveProfilePublication.eligibleGroup(review: review, group: group, before: review.plan.destinationInventory)
        let assessment = try SNESReplacementSaveRecovery.inspect(plan: review.plan, observed: observed)
        let selectedPaths = Set(selected.paths)
        guard Set(assessment.copiedPaths).isSubset(of: selectedPaths),
              Set(assessment.conflictingPaths).isSubset(of: selectedPaths) else { throw SNESLibraryInventory.failure() }
        let profile = "clover/profiles/0/" + selected.gameCode
        let profileDirectories = observed.directories.filter { $0.path == profile || $0.path.hasPrefix(profile + "/") }
        let profileFiles = observed.files.filter { $0.path.hasPrefix(profile + "/") }
        func finish(_ outcome: Outcome) throws -> Outcome { try review.validate(); return outcome }
        guard profileDirectories.allSatisfy({ $0.mode == 0o700 }) else { return try finish(.needsReview) }
        let copied = Set(assessment.copiedPaths).intersection(selectedPaths)
        let conflicting = Set(assessment.conflictingPaths).intersection(selectedPaths)
        if profileDirectories.isEmpty && profileFiles.isEmpty && copied.isEmpty && conflicting.isEmpty { return try finish(.absent) }
        if profileDirectories.count == 1 && profileDirectories[0].path == profile && profileFiles.isEmpty && copied.isEmpty && conflicting.isEmpty { return try finish(.reserved) }
        guard copied == selectedPaths, conflicting.isEmpty, Set(profileFiles.map(\.path)) == selectedPaths else { return try finish(.needsReview) }
        var expectedDirectories: Set<String> = [profile]
        for path in selected.paths {
            var parent = String(path[..<path.lastIndex(of: "/")!])
            while parent != profile {
                expectedDirectories.insert(parent)
                guard let slash = parent.lastIndex(of: "/") else { throw SNESLibraryInventory.failure() }
                parent = String(parent[..<slash])
            }
        }
        guard Set(profileDirectories.map(\.path)) == expectedDirectories else { return try finish(.needsReview) }
        return try finish(.published)
    }
}
