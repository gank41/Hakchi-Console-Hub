import Foundation
import Testing
@testable import SwiftHakchi
@testable import SwiftHakchiCore

@MainActor
struct TaskAndSnapshotTests {
    @Test(.timeLimit(.minutes(1))) func cancellationIsReportedAsCancellation() async {
        let runner = TaskRunner()
        runner.run(name: "Upload") { _ in try await Task.sleep(for: .seconds(60)) }
        runner.cancel()
        while runner.isRunning { await Task.yield() }
        #expect(runner.wasCancelled)
        #expect(runner.canCancel == false)
        #expect(runner.currentTask == "Cancelled")
    }
    @Test func missingSelectedConsoleGameRequiresImport() {
        let game = Game(code: "CLV-H-AAAAA", desktopContent: "[Desktop Entry]\nName=Installed\nExec=/bin/play /var/games/CLV-H-AAAAA/a.nes\nCode=CLV-H-AAAAA\n", consoleType: .nes, source: .console)
        #expect(throws: SyncPlanError.self) { try SyncPlanAdapter.inputs(games: [game]) }
    }
}
