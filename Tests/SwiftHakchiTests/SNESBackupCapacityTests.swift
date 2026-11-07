import Testing
@testable import SwiftHakchi

struct SNESBackupCapacityTests {
    @Test func usesOrdinaryFreeSpaceWhenImportantCapacityIsUnavailableOrZero() {
        #expect(SNESBackupCapacity.select(important: 0, ordinary: 2_000_000_000) == 2_000_000_000)
        #expect(SNESBackupCapacity.select(important: nil, ordinary: 200) == 200)
        #expect(SNESBackupCapacity.select(important: -1, ordinary: 200) == 200)
        #expect(SNESBackupCapacity.select(important: 100, ordinary: 200) == 100)
        #expect(SNESBackupCapacity.select(important: 0, ordinary: 0) == 0)
        #expect(SNESBackupCapacity.select(important: nil, ordinary: nil) == nil)
    }
}
