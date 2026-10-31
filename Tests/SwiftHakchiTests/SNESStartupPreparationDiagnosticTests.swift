import Foundation
import Testing
@testable import SwiftHakchi

struct SNESStartupPreparationDiagnosticTests {
    @Test(arguments:[["--prepare-snes-startup"],["--prepare-snes-startup","relative"],
        ["--prepare-snes-startup"]+Array(repeating:"/does-not-exist",count:9)])
    @MainActor func invalidStartupPreparationRemainsOffline(_ arguments:[String]) async {
        await #expect(throws:(any Error).self) {
            try await SNESOfflineBuildDiagnostic.dispatch(arguments) { Issue.record("File-only preparation entered a hardware handler") }
        }
    }
}
