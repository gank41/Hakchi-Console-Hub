import Foundation
import Testing
import USBBridge
@testable import SwiftHakchi

private actor FELSessionSpy: FELSessionTransport {
    enum Fault: Error { case transport(String), missingUpload, waitTimeout }
    var events: [String] = []
    var uploads: [UInt32: Data] = [:]
    var executions: [UInt32] = []
    var initializedWith: Data?
    let board: UInt32
    let failOn: String?
    let corruptAddress: UInt32?
    let pauseAt: String?
    private var continuation: CheckedContinuation<Void, Never>?

    init(board: UInt32 = UInt32(EXPECTED_BOARD_ID), failOn: String? = nil,
         corruptAddress: UInt32? = nil, pauseAt: String? = nil) {
        self.board = board; self.failOn = failOn; self.corruptAddress = corruptAddress; self.pauseAt = pauseAt
    }
    private func step(_ name: String) async throws {
        events.append(name)
        if failOn == name { throw Fault.transport(name) }
        if pauseAt == name { await withCheckedContinuation { continuation = $0 } }
    }
    func waitUntil(_ name: String) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !events.contains(name) {
            guard clock.now < deadline else { throw Fault.waitTimeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func resume() { continuation?.resume(); continuation = nil }
    func open() async throws { try await step("open") }
    func close() { events.append("close") }
    func verifyBoard() async throws -> UInt32 { try await step("verify"); return board }
    func initializeDRAM(fes1: Data) async throws { try await step("initialize"); initializedWith = fes1 }
    func write(address: UInt32, data: Data) async throws {
        try await step(address == UInt32(UBOOT_BASE_M) ? "write-uboot" : "write-kernel")
        uploads[address] = data
    }
    func read(address: UInt32, count: Int) async throws -> Data {
        try await step(address == UInt32(UBOOT_BASE_M) ? "read-uboot" : "read-kernel")
        guard var data = uploads[address], data.count == count else { throw Fault.missingUpload }
        if corruptAddress == address { data[0] ^= 1 }
        return data
    }
    func execute(address: UInt32) async throws { executions.append(address); try await step("execute") }
}

struct FELBootSequenceTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_XZ_CANDIDATE"] != nil))
    func unsupportedHistoricalXZNeverOpensTheFELSession() async throws {
        let env=ProcessInfo.processInfo.environment
        let candidate=try SNESStartupAdapterCandidate.load(directory:URL(fileURLWithPath:try #require(env["SWIFTHAKCHI_SNES_XZ_CANDIDATE"])))
        let p=try PinnedFELInputs.load()
        let trial=try PreparedSNESStartupTrial.prepare(candidate:candidate,evidence:URL(fileURLWithPath:try #require(env["SWIFTHAKCHI_SNES_XZ_PREFLIGHT"])),recovery:.init(fes1:p.fes1,uboot:p.uboot,bootImage:p.bootImage))
        let session=FELSessionSpy(failOn:"open"),service=FELService(makeSession:{session})
        await #expect(throws:(any Error).self) {try await service.memboot(startupTrial:trial)}
        #expect(await session.events.isEmpty)
    }

    @Test(arguments: [false, true])
    func sealedSNESProbeChecksReadbackBeforeExecution(corrupt: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        guard let probe = try await privateProbeFixture(root: root) else { return }
        let session = FELSessionSpy(corruptAddress: corrupt ? UInt32(TRANSFER_BASE_M) : nil)
        let service = FELService(makeSession: { session })
        do {
            try await service.memboot(probe: probe)
            #expect(!corrupt)
            #expect(await session.uploads[UInt32(TRANSFER_BASE_M)] == probe.image)
            #expect(await session.executions == [UInt32(UBOOT_BASE_M)])
        } catch FELError.readbackMismatch { #expect(corrupt); #expect(await session.executions.isEmpty) }
        #expect(await session.events.last == "close")
        #expect(await session.events.filter { $0 == "open" }.count == 1)
    }
    @Test func invalidInputsFailBeforeOpenOrProgress() async {
        let session = FELSessionSpy(), service = FELService(makeSession: { session })
        await #expect(throws: (any Error).self) {
            try await service.memboot(fes1Data: Data(), ubootData: Data(), bootImgData: Data(), progress: { _, _ in
                Issue.record("Unvalidated input emitted hardware progress")
            })
        }
        #expect(await session.events.isEmpty)
    }
    @Test func successfulSequenceUsesOneVerifiedSessionAndPreparedBytes() async throws {
        let raw = try PinnedFELInputs.load(), session = FELSessionSpy()
        let service = FELService(makeSession: { session })
        let prepared = try PreparedRecoveryBoot(fes1: raw.fes1, uboot: raw.uboot, bootImage: raw.bootImage)
        try await service.memboot(fes1Data: raw.fes1, ubootData: raw.uboot, bootImgData: raw.bootImage)
        #expect(await session.events == ["open", "verify", "initialize", "write-uboot", "read-uboot", "write-kernel", "read-kernel", "execute", "close"])
        #expect(await session.initializedWith == prepared.fes1)
        #expect(await session.uploads[UInt32(UBOOT_BASE_M)] == prepared.uboot)
        #expect(await session.uploads[UInt32(TRANSFER_BASE_M)] == prepared.bootImage)
        #expect(await session.executions == [UInt32(UBOOT_BASE_M)])
    }
    @Test func wrongBoardClosesBeforeInitializationOrUpload() async throws {
        let raw = try PinnedFELInputs.load(), session = FELSessionSpy(board: 0x123400)
        let service = FELService(makeSession: { session })
        do {
            try await service.memboot(fes1Data: raw.fes1, ubootData: raw.uboot, bootImgData: raw.bootImage)
            Issue.record("Wrong board was allowed to boot")
        } catch FELError.wrongBoard { } catch { Issue.record("Wrong error: \(error)") }
        #expect(await session.events == ["open", "verify", "close"])
        #expect(await session.uploads.isEmpty)
        #expect(await session.executions.isEmpty)
    }
    @Test(arguments: [UInt32(UBOOT_BASE_M), UInt32(TRANSFER_BASE_M)])
    func uploadReadbackMismatchPreventsUbootExecution(address: UInt32) async throws {
        let raw = try PinnedFELInputs.load(), session = FELSessionSpy(corruptAddress: address)
        let service = FELService(makeSession: { session })
        do {
            try await service.memboot(fes1Data: raw.fes1, ubootData: raw.uboot, bootImgData: raw.bootImage)
            Issue.record("Corrupt upload was executed")
        } catch FELError.readbackMismatch { } catch { Issue.record("Wrong error: \(error)") }
        #expect(await session.executions.isEmpty)
        #expect(await session.events.last == "close")
        if address == UInt32(UBOOT_BASE_M) { #expect(await session.uploads[UInt32(TRANSFER_BASE_M)] == nil) }
    }
    @Test(arguments: ["open", "verify", "initialize", "write-uboot", "read-uboot", "write-kernel", "read-kernel", "execute"])
    func everyTransportFailureClosesWithoutReportingSuccess(step: String) async throws {
        let raw = try PinnedFELInputs.load(), session = FELSessionSpy(failOn: step)
        let service = FELService(makeSession: { session })
        await #expect(throws: FELSessionSpy.Fault.self) {
            try await service.memboot(fes1Data: raw.fes1, ubootData: raw.uboot, bootImgData: raw.bootImage)
        }
        #expect(await session.events.last == "close")
        if step != "execute" { #expect(await session.executions.isEmpty) }
    }
    @Test func cancellationDuringReadbackClosesAndDoesNotUploadKernel() async throws {
        let raw = try PinnedFELInputs.load(), session = FELSessionSpy(pauseAt: "read-uboot")
        let service = FELService(makeSession: { session })
        let operation = Task { try await service.memboot(fes1Data: raw.fes1, ubootData: raw.uboot, bootImgData: raw.bootImage) }
        do {
            try await session.waitUntil("read-uboot")
            operation.cancel(); await session.resume()
            await #expect(throws: CancellationError.self) { try await operation.value }
            #expect(await session.executions.isEmpty)
            #expect(await session.uploads[UInt32(TRANSFER_BASE_M)] == nil)
            #expect(await session.events.last == "close")
        } catch {
            operation.cancel(); await session.resume(); _ = try? await operation.value
            throw error
        }
    }
    @Test func simultaneousOperationCannotOpenAnotherSession() async throws {
        let raw = try PinnedFELInputs.load(), session = FELSessionSpy(pauseAt: "open")
        let service = FELService(makeSession: { session })
        let first = Task { try await service.memboot(fes1Data: raw.fes1, ubootData: raw.uboot, bootImgData: raw.bootImage) }
        do {
            try await session.waitUntil("open")
            do { _ = try await service.verifyDevice(); Issue.record("Busy service opened another session") }
            catch FELError.busy { } catch { Issue.record("Wrong error: \(error)") }
            first.cancel(); await session.resume()
            await #expect(throws: CancellationError.self) { try await first.value }
            #expect(await session.events == ["open", "close"])
        } catch {
            first.cancel(); await session.resume(); _ = try? await first.value
            throw error
        }
    }
    @Test func cancelledTaskIsRejectedAtNativeExecutionBoundary() async {
        // No device is opened: cancellation must win even before the handle guard.
        // This exercises the real native actor rather than only the service spy.
        let transport = IOKitFELSessionTransport()
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await transport.execute(address: UInt32(UBOOT_BASE_M))
        }
        await #expect(throws: CancellationError.self) { try await operation.value }
    }
    @Test func standaloneVerificationNeverInitializesOrWritesMemory() async throws {
        let session = FELSessionSpy(), service = FELService(makeSession: { session })
        #expect(try await service.verifyDevice() == UInt32(EXPECTED_BOARD_ID))
        #expect(await session.events == ["open", "verify", "close"])
    }
}

extension FELBootSequenceTests {
    @Test(arguments: [false,true])
    func originalComponentMenuChecksAllRAMBeforeExecution(corrupt:Bool) async throws {
        guard let menu=try privateOriginalMenu() else {return}
        let session=FELSessionSpy(corruptAddress:corrupt ? UInt32(TRANSFER_BASE_M):nil),service=FELService(makeSession:{session})
        do {
            try await service.memboot(originalMenu:menu)
            #expect(!corrupt)
            #expect(await session.uploads[UInt32(TRANSFER_BASE_M)]==menu.image)
            #expect(await session.executions==[UInt32(UBOOT_BASE_M)])
        } catch FELError.readbackMismatch {#expect(corrupt);#expect(await session.executions.isEmpty)}
        #expect((await session.events).filter{$0=="close"}.count==1)
    }
}

extension FELBootSequenceTests {
    @Test func changedOriginalSourcesDuringEachFELAwaitPreventFurtherIO() async throws {
        guard let original=try privateOriginalMenu() else{return}
        let steps=["open","verify","initialize","write-uboot","read-uboot","write-kernel","read-kernel"]
        for (index,step) in steps.enumerated() {
            let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
            let menu=try copiedOriginalMenu(original,root:root),session=FELSessionSpy(pauseAt:step)
            let task=Task {try await FELService(makeSession:{session}).memboot(originalMenu:menu)}
            do {
                try await session.waitUntil(step)
                try Data([1]).write(to:menu.material.components.directoryURL.appendingPathComponent("components.frame"))
                await session.resume()
                await #expect(throws:(any Error).self) {try await task.value}
                #expect(await session.events==Array(steps.prefix(index+1))+["close"])
                #expect(await session.executions.isEmpty)
            } catch {task.cancel();await session.resume();_=try? await task.value;throw error}
        }
    }
}
