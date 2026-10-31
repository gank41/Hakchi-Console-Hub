import Foundation
import Testing
@testable import SwiftHakchi

private actor ProbeDiagnosticCalls {
    var inputs = 0, host = 0, io = 0
    func input() { inputs += 1 }
    func check() { host += 1 }
    func open() { io += 1 }
}
struct SNESRAMProbeDiagnosticTests {
    @Test func optionsAreStrictAndUnrelatedModesRemainUnchanged() throws {
        #expect(try SNESRAMProbeDiagnosticOptions.parseIfPresent(["--inspect"]) == nil)
        #expect(try SNESRAMProbeDiagnosticOptions.parseIfPresent(["--capture-snes-runtime", "/setup", "/Backups"]) == .capture("/setup", "/Backups"))
        #expect(try SNESRAMProbeDiagnosticOptions.parseIfPresent(["--test-snes-ram-probe", "/probe"]) == .test("/probe"))
        #expect(try SNESRAMProbeDiagnosticOptions.parseIfPresent(["--prepare-snes-ram-probe", "/setup", "/runtime", "/kernel", "/hmod", "/busybox", "/Backups"]) != nil)
        for args in [["--capture-snes-runtime"], ["--test-snes-ram-probe", "relative"],
                     ["--test-snes-ram-probe", "/probe", "extra"], ["--prepare-snes-ram-probe", "/setup", "/runtime", "/kernel", "/hmod", "/Backups"],
                     ["--test-snes-ram-probe", "/bad\0path"]] {
            #expect(throws: (any Error).self) { try SNESRAMProbeDiagnosticOptions.parseIfPresent(args) }
        }
    }
    @Test(arguments: [
        ["--capture-snes-runtime", "/missing-setup", "/missing-backups"],
        ["--prepare-snes-ram-probe", "/missing-setup", "/runtime", "/kernel", "/hmod", "/busybox", "/Backups"],
        ["--test-snes-ram-probe", "/missing-probe"],
        ["--test-snes-ram-probe", "relative"]])
    func invalidMaterialNeverChecksHostOrCreatesIO(args: [String]) async throws {
        let calls = ProbeDiagnosticCalls()
        await #expect(throws: (any Error).self) {
            try await SNESRAMProbeDiagnostic.runIfPresent(args, loadInputs: {
                await calls.input(); let raw = try PinnedFELInputs.load()
                return .init(fes1: raw.fes1, uboot: raw.uboot, bootImage: raw.bootImage)
            }, checkHost: { await calls.check() }, makeCaptureIO: {
                Issue.record("Capture I/O constructed before material validation")
                return NativeRecoveryProbeIO(observationCommand: SNESBackupPolicy.command)
            }, makeProbeIO: { probe in
                Issue.record("Probe I/O constructed before material validation")
                return NativeSNESRAMProbeIO(probe: probe)
            })
        }
        #expect(await calls.host == 0)
    }
    @Test func unrelatedModeDoesNotLoadInputsOrCheckHost() async throws {
        let calls = ProbeDiagnosticCalls()
        let result = try await SNESRAMProbeDiagnostic.runIfPresent(["--inspect"], loadInputs: {
            await calls.input(); throw SNESRuntimeBinding.failure()
        }, checkHost: { await calls.check() })
        #expect(result == nil)
        #expect(await calls.inputs == 0)
        #expect(await calls.host == 0)
    }
}
