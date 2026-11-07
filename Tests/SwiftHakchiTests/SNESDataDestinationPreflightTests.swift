import Darwin
import Foundation
import Testing
@testable import SwiftHakchi

@Suite(.serialized) struct SNESDataDestinationPreflightTests {
    @Test func verifiesWritableDestinationWithoutLeavingProbeFiles() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryBootSnapshotStore(root: root)
        try await store.checkWritableDestination()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    @Test func rejectsReadOnlyDestinationBeforeConsoleWork() async throws {
        let root = try testDirectory(); defer { _ = chmod(root.path, 0o700); try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryBootSnapshotStore(root: root)
        #expect(chmod(root.path, 0o500) == 0)
        await #expect(throws: (any Error).self) { try await store.checkWritableDestination() }
    }
}
