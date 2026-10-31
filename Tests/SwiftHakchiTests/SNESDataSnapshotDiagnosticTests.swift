import Foundation
import Testing
@testable import SwiftHakchi

struct SNESDataSnapshotDiagnosticTests {
    @Test(arguments: [["--snapshot-snes-data"], ["--snapshot-snes-data","relative","/tmp"], ["--snapshot-snes-data","/tmp","/tmp","extra"]])
    func rejectsArgumentsBeforeAnyPayloadOrDeviceWork(args:[String]) async {
        await #expect(throws:(any Error).self) {
            try await SNESDataSnapshotDiagnostic.runIfPresent(args,loadInputs:{ Issue.record("Payload loader was reached for invalid arguments"); throw SNESDataSnapshotError.refused },
                checkHost:{ Issue.record("Host check was reached for invalid arguments"); throw SNESDataSnapshotError.refused })
        }
    }
    @Test func ignoresOtherActions() async throws {
        let result=try await SNESDataSnapshotDiagnostic.runIfPresent(["--inspect"],loadInputs:{ Issue.record("Wrong action loaded payloads"); throw SNESDataSnapshotError.refused })
        #expect(result == nil)
    }
    @Test func missingSourceStopsBeforePayloadLoading() async throws {
        let root=try testDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        await #expect(throws:(any Error).self) {
            try await SNESDataSnapshotDiagnostic.runIfPresent(["--snapshot-snes-data",root.path,root.path],loadInputs:{ Issue.record("Invalid source loaded payloads"); throw SNESDataSnapshotError.refused },
                checkHost:{ Issue.record("Invalid source inspected USB host"); throw SNESDataSnapshotError.refused })
        }
    }
}
