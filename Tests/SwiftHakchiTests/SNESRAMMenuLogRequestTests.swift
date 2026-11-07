import Foundation
import Testing
@testable import SwiftHakchi

struct SNESRAMMenuLogRequestTests {
    @Test func onlyAcceptsAnExplicitCanonicalNonce() throws {
        let nonce = "A30F6A86-F0E0-4C9C-A1F8-507086C44026"
        let parsed = try SNESRAMMenuLogRequest.parse(["--read-snes-ram-menu-logs",nonce])
        let unrelated = try SNESRAMMenuLogRequest.parse(["--unrelated"])
        #expect(parsed?.uuidString == nonce)
        #expect(unrelated == nil)
        #expect(throws:(any Error).self) { try SNESRAMMenuLogRequest.parse(["--read-snes-ram-menu-logs","bad"]) }
        #expect(throws:(any Error).self) { try SNESRAMMenuLogRequest.parse(["--read-snes-ram-menu-logs"]) }
    }
}
