import Testing
@testable import SwiftHakchi

struct LegacySyncCapacityEstimateTests {
    @Test func selectionShowsInactiveStageHeadroomAndBlocksOnlyDefiniteOverflow() throws {
        let mib: Int64 = 1024 * 1024
        let estimate = LegacySyncCapacityEstimate(freeBytes: 90 * mib,
            stockCodes: ["STOCK"], sourceBytes: ["FIRST": 8 * mib, "SECOND": 10 * mib])
        let selected: Set<String> = ["STOCK", "FIRST"]
        let projection = try #require(estimate.projected(selected))
        let expectedRequired: Int64 = 64 * mib + 2 * (4096 + 2 * 64 * 1024 + 8 * mib)
        #expect(projection.requiredBytes == expectedRequired)
        #expect(projection.headroomBytes == 90 * mib - projection.requiredBytes)
        #expect(!estimate.canInclude("SECOND", in: selected))
        #expect(estimate.canInclude("SECOND", in: ["STOCK"]))
        #expect(estimate.canInclude("UNKNOWN", in: selected))
    }
}
