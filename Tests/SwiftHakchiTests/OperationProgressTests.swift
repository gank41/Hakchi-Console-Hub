import Foundation
import Testing
@testable import SwiftHakchi

private actor ProgressGate {
    var entered = false
    var continuation: CheckedContinuation<Void,Never>?
    func pause() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private actor ReporterBox {
    var value: TaskProgressReporter?
    func put(_ value: TaskProgressReporter) { self.value = value }
}
@MainActor
struct OperationProgressTests {
    @Test(.timeLimit(.minutes(1))) func cancellationWaitsForActualExit() async {
        let runner = TaskRunner(), gate = ProgressGate()
        runner.run(name:"Uploading") { _ in await gate.pause(); try Task.checkCancellation() }
        while !(await gate.entered) { await Task.yield() }
        runner.cancel()
        #expect(runner.isRunning && runner.cancelRequested && !runner.canCancel)
        #expect(!runner.wasCancelled)
        runner.run(name:"Must not start") { _ in Issue.record("Overlapping operation started") }
        #expect(runner.operationName == "Uploading")
        await gate.release()
        while runner.isRunning { await Task.yield() }
        #expect(runner.wasCancelled && runner.endedAt != nil)
    }
    @Test(.timeLimit(.minutes(1))) func successfulOperationAfterCancelReportsCompletion() async {
        let runner = TaskRunner(), gate = ProgressGate()
        runner.run(name:"Committing verified sync") { _ in await gate.pause() }
        while !(await gate.entered) { await Task.yield() }
        runner.cancel()
        #expect(runner.isRunning && runner.cancelRequested)
        await gate.release()
        while runner.isRunning { await Task.yield() }
        #expect(!runner.wasCancelled && runner.error == nil && runner.progress == 1)
        #expect(runner.activity.details.contains("Complete"))
    }
    @Test(.timeLimit(.minutes(1))) func staleReporterCannotUpdateNextRun() async throws {
        let runner = TaskRunner(), box = ReporterBox(), gate = ProgressGate()
        runner.run(name:"First") { reporter in await box.put(reporter) }
        while runner.isRunning { await Task.yield() }
        let stale = try #require(await box.value)
        runner.run(name:"Second") { _ in await gate.pause() }
        while !(await gate.entered) { await Task.yield() }
        await stale.report(status:"Old callback", fraction:0.8)
        #expect(runner.currentTask == "Second" && runner.progress == 0)
        await gate.release()
        while runner.isRunning { await Task.yield() }
    }
    @Test func feedIsBoundedAndRedactsIdentifiers() {
        var feed = OperationActivity()
        for i in 0..<250 { feed.append("Step \(i)") }
        feed.append("HWID=0123456789abcdef0123456789abcdef MAC=aa:bb:cc:dd:ee:ff " + String(repeating:"x",count:5000))
        #expect(feed.entries.count == 200)
        let text = feed.details
        #expect(!text.contains("0123456789abcdef0123456789abcdef"))
        #expect(!text.contains("aa:bb:cc:dd:ee:ff"))
        #expect(feed.entries.last!.message.count <= 1024)
    }
    @Test(.timeLimit(.minutes(1))) func fractionsAreFiniteClampedAndUnknownByDefault() async {
        let runner = TaskRunner(), gate = ProgressGate(), box = ReporterBox()
        runner.run(name:"Working") { reporter in await box.put(reporter); await gate.pause() }
        while !(await gate.entered) { await Task.yield() }
        #expect(!runner.hasMeasuredProgress)
        let reporter = await box.value!
        await reporter.report(status:"Preparing",fraction:.nan)
        #expect(!runner.hasMeasuredProgress && runner.progress.isFinite)
        await reporter.report(status:"Uploading",fraction:2)
        #expect(runner.hasMeasuredProgress && runner.progress == 1)
        await reporter.report(status:"Checking",fraction:-1)
        #expect(runner.progress == 0)
        await gate.release()
        while runner.isRunning { await Task.yield() }
        #expect(runner.operationName == "Working" && runner.endedAt != nil && runner.error == nil)
    }
    @Test(.timeLimit(.minutes(1))) func failurePreservesSelectableDetails() async {
        let runner = TaskRunner()
        runner.run(name:"Reading") { _ in throw RecoveryProbeError.refused("Unplugged") }
        while runner.isRunning { await Task.yield() }
        #expect(runner.error != nil && runner.activity.details.contains("Unplugged"))
    }
}
