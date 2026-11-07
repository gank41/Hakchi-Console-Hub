import Foundation
import Testing
@testable import SwiftHakchi

struct SNESStartupToolInputsTests {
    @Test func refusesUnexpectedOrOversizedInputsWithoutStartingAnything() async {
        await #expect(throws: (any Error).self) {
            try await SNESStartupToolInputs.acquire { _, _ in Data([1, 2, 3]) }
        }
        await #expect(throws: CancellationError.self) {
            try await SNESStartupToolInputs.acquire { _, _ in throw CancellationError() }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_BUSYBOX"] != nil && ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_CLOVERSHELL"] != nil))
    func verifiedUpstreamInputsCanBeLoadedWithoutPersonalPaths() async throws {
        let env = ProcessInfo.processInfo.environment
        let busybox = try Data(contentsOf: URL(fileURLWithPath: try #require(env["SWIFTHAKCHI_SNES_BUSYBOX"])))
        let daemon = try Data(contentsOf: URL(fileURLWithPath: try #require(env["SWIFTHAKCHI_SNES_CLOVERSHELL"])))
        let inputs = try await SNESStartupToolInputs.acquire { url, maximum in
            #expect(url.host == "raw.githubusercontent.com")
            if url.lastPathComponent == "busybox" { #expect(maximum == busybox.count); return busybox }
            #expect(url.lastPathComponent == "clovershell.hmod" && maximum == daemon.count); return daemon
        }
        #expect(inputs.busybox == busybox && inputs.daemonHmod == daemon)
    }
}
