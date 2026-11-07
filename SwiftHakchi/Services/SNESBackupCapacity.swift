import Foundation

/// Capacity checks are advisory; the export still handles actual write errors.
enum SNESBackupCapacity {
    static func select(important: Int64?, ordinary: Int?) -> Int64? {
        if let important, important > 0 { return important }
        if let ordinary, ordinary >= 0 { return Int64(ordinary) }
        if important == 0 { return 0 }
        return nil
    }
    static func available(at directory: URL) throws -> Int64? {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return select(important: values.volumeAvailableCapacityForImportantUsage, ordinary: values.volumeAvailableCapacity)
    }
}
