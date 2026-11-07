import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESCompatibilityControllerProfileTests {
    @Test func bundledProfileMatchesReviewedTrialAndRejectsChanges() throws {
        let data = try SNESCompatibilityControllerProfile.load()
        #expect(data.count == 1459)
        #expect(BackupManifest.digest(data) == "55018944a935bd04858d80f0f99d5a7ecfb61353565ba565eedd0075a55d2c35")
        #expect(String(decoding: data, as: UTF8.self).contains("Nintendo Clovercon - controller1"))
        for bad in [Data(), Data(data.dropLast()), data + Data([0]), Data(repeating: 0, count: data.count)] {
            #expect(throws: (any Error).self) { try SNESCompatibilityControllerProfile.validate(bad) }
        }
    }
}
