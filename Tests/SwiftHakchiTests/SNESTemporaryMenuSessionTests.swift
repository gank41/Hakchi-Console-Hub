import Foundation
import Testing
@testable import SwiftHakchi

func temporaryMenuUSB(location: UInt32? = nil, version: UInt16 = 0x6a02) -> RecoveryProbeUSBDevice {
    let fel = probeFEL()
    return .init(vendorID: 0x1f3a, productID: 0xefe8, deviceVersion: version, deviceClass: 0,
        locationID: location ?? fel.locationID, product: "Swift Hakchi SNES Menu Test", registryEntryID: 999)
}
actor TemporaryMenuFakeIO: SNESTemporaryMenuIO {
    var booted = false, boots = 0, closes = 0, reports = 0, starts = 0
    let fault: String, expected: SNESTemporaryMenuExpectation
    init(_ fault: String = "none", booted: Bool = false, expected: SNESTemporaryMenuExpectation = menuExpectation()) { self.fault = fault; self.booted = booted; self.expected = expected }
    func inventory() throws -> [RecoveryProbeUSBDevice] {
        if !booted { return [probeFEL()] }
        return [temporaryMenuUSB(location: fault == "port" ? 88 : nil)]
    }
    func boot(expected: RecoveryProbeUSBDevice) throws {
        #expect(expected == probeFEL()); boots += 1; booted = true
        if fault == "boot" { throw SNESRuntimeBinding.failure() }
    }
    func connect(expected: RecoveryProbeUSBDevice) throws {
        #expect(expected == temporaryMenuUSB())
        if fault == "connect" { throw SNESRuntimeBinding.failure() }
    }
    func startReport(challenge: UUID) throws -> Data { starts += 1; return try report(challenge: challenge) }
    func startCount() -> Int { starts }
    func report(challenge: UUID) throws -> Data {
        reports += 1
        if fault == "start-progress" { throw SNESTemporaryMenuReadFailure(received: Data(), details: Data("SNES_STARTUP_STAGE=starting-menu\n".utf8)) }
        if fault == "cancel" { throw CancellationError() }
        if fault == "stale" { return menuReport() }
        if fault == "truncated" { return Data("partial".utf8) }
        return Data(String(decoding: menuReport(challenge: challenge), as: UTF8.self)
            .replacingOccurrences(of: menuNonce, with: expected.nonce)
            .replacingOccurrences(of: runtimeBindingFixture().expectedHWID, with: expected.binding.expectedHWID)
            .replacingOccurrences(of: String(repeating: "a", count: 64), with: expected.filesSHA256)
            .replacingOccurrences(of: String(repeating: "b", count: 64), with: expected.sourceFilesSHA256).utf8)
    }
    func diagnostics() -> Data { Data("bounded test status".utf8) }
    func disconnect() { closes += 1 }
    func counts() -> [Int] { [boots, reports, closes] }
}
actor TemporaryMenuValidationGate {
    var calls = 0
    let refuseAt: Int
    init(_ n: Int) { refuseAt = n }
    func validate() throws { calls += 1; if calls >= refuseAt { throw SNESRuntimeBinding.failure() } }
}
struct SNESTemporaryMenuSessionTests {
    @Test func startChecksTwoFreshReportsAndFollowupCannotBootAgain() async throws {
        let io = TemporaryMenuFakeIO(), service = SNESTemporaryMenuService(wait: {})
        let result = try await service.start(expected: menuExpectation(), io: io, validate: {})
        #expect(await io.counts() == [1, 2, 1])
        #expect(await io.startCount() == 1)
        #expect(result.challenges.count == 2 && result.challenges[0] != result.challenges[1])
        let followupIO = TemporaryMenuFakeIO(booted: true)
        let after = try await service.check(expected: menuExpectation(), started: result, io: followupIO, validate: {})
        #expect(after.challenges.count == 1)
        #expect(await followupIO.counts() == [0, 1, 1])
        #expect(await followupIO.startCount() == 0)
    }
    @Test(arguments: ["boot", "connect", "port", "stale", "truncated", "cancel"])
    func failedStartNeverRetriesOrMarksGameplayAccepted(fault: String) async {
        let io = TemporaryMenuFakeIO(fault), service = SNESTemporaryMenuService(wait: {})
        await #expect(throws: (any Error).self) { try await service.start(expected: menuExpectation(), io: io, validate: {}) }
        let counts = await io.counts()
        #expect(counts[0] == 1 && counts[2] == 1)
    }
    @Test func changedSourceAfterBootStopsBeforeConnectingAndKeepsFailureIncomplete() async {
        let io = TemporaryMenuFakeIO(), gate = TemporaryMenuValidationGate(3)
        let service = SNESTemporaryMenuService(wait: {})
        do {
            _ = try await service.start(expected: menuExpectation(), io: io, validate: { try await gate.validate() })
            Issue.record("A changed source was accepted")
        } catch { #expect(await io.counts() == [1, 0, 1]) }
    }
    @Test func wrongTemporaryFingerprintAndMultipleConsolesAreRejected() throws {
        #expect(throws: (any Error).self) { try SNESTemporaryMenuUSBPolicy.nativeIdentity(temporaryMenuUSB(version: 0x6a01)) }
        #expect(throws: (any Error).self) { try SNESTemporaryMenuUSBPolicy.after([temporaryMenuUSB(), temporaryMenuUSB()], original: probeFEL()) }
        #expect(throws: (any Error).self) { try SNESTemporaryMenuUSBPolicy.after([temporaryMenuUSB(location: 88)], original: probeFEL()) }
    }
}

private actor TemporaryMenuPause {
    private var paused = false
    private var entered: CheckedContinuation<Void, Never>?, suspended: CheckedContinuation<Void, Never>?
    func pauseOnce() async {
        if paused { return }; paused = true; entered?.resume(); entered = nil
        await withCheckedContinuation { suspended = $0 }
    }
    func waitUntilPaused() async { if !paused { await withCheckedContinuation { entered = $0 } } }
    func release() { suspended?.resume(); suspended = nil }
}
extension SNESTemporaryMenuSessionTests {
    @Test func secondStartCannotShareTheActiveConsoleSession() async throws {
        let service = SNESTemporaryMenuService(wait: {}), gate = TemporaryMenuPause()
        let first = TemporaryMenuFakeIO(), second = TemporaryMenuFakeIO()
        let running = Task {
            try await service.start(expected: menuExpectation(), io: first, validate: {},
                progress: { if $0 == .checkingIdentity { await gate.pauseOnce() } })
        }
        await gate.waitUntilPaused()
        await #expect(throws: (any Error).self) { try await service.start(expected: menuExpectation(), io: second, validate: {}) }
        #expect(await second.counts() == [0,0,0])
        await gate.release(); _ = try await running.value
        #expect(await first.counts() == [1,2,1])
    }
}

extension SNESTemporaryMenuSessionTests {
    @Test func sourceChangeDuringDisconnectStillClosesOnceAndFailsCompletion() async {
        let io = TemporaryMenuFakeIO()
        await #expect(throws: SNESTemporaryMenuFailure.self) {
            try await SNESTemporaryMenuService(wait: {}).start(expected: menuExpectation(), io: io, validate: {
                if await io.counts()[2] > 0 { throw SNESRuntimeBinding.failure() }
            })
        }
        #expect(await io.counts() == [1,2,1])
    }
}

extension SNESTemporaryMenuSessionTests {
    @Test func failedStartupKeepsStreamedProgressAlongsideLaterDiagnostics() async {
        let io = TemporaryMenuFakeIO("start-progress")
        do {
            _ = try await SNESTemporaryMenuService(wait: {}).start(expected: menuExpectation(), io: io, validate: {})
            Issue.record("Failed startup was accepted")
        } catch let failure as SNESTemporaryMenuFailure {
            let details = String(decoding: failure.diagnostics, as: UTF8.self)
            #expect(details.contains("SNES_STARTUP_STAGE=starting-menu\n"))
            #expect(details.contains("bounded test status"))
            #expect(failure.report.isEmpty && failure.capturedReports.isEmpty)
        } catch { Issue.record("Wrong failure type") }
        #expect(await io.counts() == [1,1,1])
        #expect(await io.startCount() == 1)
    }
}
