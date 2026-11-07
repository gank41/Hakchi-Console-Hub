import Foundation
import Testing
@testable import SwiftHakchi

private actor SNESLibraryDiagnosticAccess {
    var calls = 0
    func used() { calls += 1 }
}
struct SNESLibraryStartupDiagnosticTests {
    @Test func malformedRequestsStopBeforeLoadingRecoveryOrOpeningUSB() async throws {
        let access = SNESLibraryDiagnosticAccess(), digest = String(repeating: "a", count: 64)
        let invalid = [
            ["--prepare-snes-library-startup"],
            ["--prepare-snes-parallel-startup"],
            ["--prepare-snes-parallel-startup", "relative", digest, "/out"],
            ["--test-snes-parallel-startup", "/operation", digest, "/candidate", "/out"],
            ["--prepare-snes-library-startup", "relative", digest, "/out"],
            ["--prepare-snes-library-startup", "/operation", "not-a-digest", "/out"],
            ["--test-snes-library-startup", "/operation", digest, "/candidate", "/out"],
            ["--preflight-snes-library-startup", "/operation", digest, "/candidate\u{0}", "/out"],
            ["--check-snes-library-startup", "/operation", digest, "/candidate", "/evidence", "/started", "relative"]]
        for args in invalid {
            await #expect(throws: (any Error).self) {
                try await SNESLibraryStartupDiagnostic.runIfPresent(args, loadInputs: {
                    await access.used(); throw SNESRuntimeBinding.failure()
                }, checkHost: { await access.used() })
            }
        }
        for mode in ["--inspect", "--write-snes-parallel-startup", "--install-snes-parallel-startup"] {
            let other = try await SNESLibraryStartupDiagnostic.runIfPresent([mode], loadInputs: {
                await access.used(); throw SNESRuntimeBinding.failure()
            }, checkHost: { await access.used() })
            #expect(other == nil)
        }
        #expect(await access.calls == 0)
    }
}
