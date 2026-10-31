import Foundation
import SwiftHakchiCore

/// A projection, never deletion/copy authority. Inventory must come from a later checked live context.
struct SNESLibraryCapacity: Sendable {
    struct Inventory: Sendable {
        let measuredAt: Date, contextSHA256: String, freeBytes: Int64, blockSize: Int64
        let objects: [String: SNESLibraryObjects.Record]
        let namespaceReady: Bool, descriptionStoreReady: Bool
        init(measuredAt: Date, contextSHA256: String, freeBytes: Int64, blockSize: Int64,
             objects: [String: SNESLibraryObjects.Record], namespaceReady: Bool = false, descriptionStoreReady: Bool = false) {
            self.measuredAt = measuredAt; self.contextSHA256 = contextSHA256; self.freeBytes = freeBytes
            self.blockSize = blockSize; self.objects = objects; self.namespaceReady = namespaceReady; self.descriptionStoreReady = descriptionStoreReady
        }
    }
    let newObjectBytes: Int64, newAllocatedBytes: Int64, neededToCopy: Int64, freeAfterFinishing: Int64
    let reserveBytes: Int64
    let canFit: Bool
    static func project(menu: SNESLibraryMenu, inventory: Inventory?, expectedContext: String, now: Date = Date(),
                        verifiedReclaimableBytes: Int64 = 0) throws -> Self {
        try menu.validate()
        guard let live = inventory, SNESDataSnapshotChunk.isDigest(expectedContext), live.contextSHA256 == expectedContext,
              (0...60).contains(now.timeIntervalSince(live.measuredAt)), live.freeBytes >= 0,
              live.freeBytes <= 512 * 1024 * 1024, (512...65536).contains(live.blockSize), live.blockSize.nonzeroBitCount == 1,
              live.objects.count <= 2048, (0...512 * 1024 * 1024).contains(verifiedReclaimableBytes) else {
            throw SNESLibraryCompatibility.failure("Refresh the console connection to check available space.")
        }
        func add(_ a: Int64, _ b: Int64) throws -> Int64 {
            let result = a.addingReportingOverflow(b); guard !result.overflow else { throw SNESLibraryMenu.failure() }; return result.partialValue
        }
        func allocated(_ bytes: Int64) throws -> Int64 {
            guard bytes > 0 else { throw SNESLibraryMenu.failure() }
            let rounded = try add(bytes, live.blockSize - 1) / live.blockSize
            let result = rounded.multipliedReportingOverflow(by: live.blockSize)
            guard !result.overflow else { throw SNESLibraryMenu.failure() }; return result.partialValue
        }
        for (name, record) in live.objects {
            try record.validate()
            guard name == record.name else { throw SNESLibraryMenu.failure() }
        }
        guard live.namespaceReady || (live.objects.isEmpty && !live.descriptionStoreReady) else { throw SNESLibraryMenu.failure() }
        var newObjects: Int64 = 0
        for record in menu.objectRecords {
            try record.validate()
            if let existing = live.objects[record.name] {
                guard existing == record else { throw SNESLibraryMenu.failure() }
            } else { newObjects = try add(newObjects, allocated(Int64(record.byteCount))) }
        }
        let wire = try SNESLibraryStartupScripts.manifest(for: menu)
        var menuBytes = try add(allocated(Int64(menu.manifest.count)), allocated(Int64(wire.count)))
        for file in menu.description.files { menuBytes = try add(menuBytes, allocated(Int64(file.byteCount))) }
        // The new menu/pages directories plus every screen and game/link directory.
        // First use also reserves a possibly missing shared parent, namespace, menus, objects and restore-description roots.
        let directoryBytes = Int64(2 + (live.namespaceReady ? 0 : 4) + (live.descriptionStoreReady ? 0 : 1) + menu.graph.screens.count + menu.description.placements.count) * live.blockSize
        let newBytes = try add(newObjects, add(menuBytes, directoryBytes))
        // Streaming retains only one bounded chunk, never a second archive of the library.
        let reserve: Int64 = 2 * 1024 * 1024
        let needed = try add(newBytes, add(256 * 1024, reserve))
        let final = try add(live.freeBytes - newBytes, verifiedReclaimableBytes)
        guard final <= 512 * 1024 * 1024 else { throw SNESLibraryMenu.failure() }
        return .init(newObjectBytes: newObjects, newAllocatedBytes: newBytes, neededToCopy: needed,
                     freeAfterFinishing: final, reserveBytes: reserve, canFit: needed <= live.freeBytes)
    }
}
