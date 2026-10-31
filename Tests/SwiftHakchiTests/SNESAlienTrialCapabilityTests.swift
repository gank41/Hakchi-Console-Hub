import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESAlienTrialCapabilityTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HC_TRIAL_MENU_DIRECTORY"] != nil && ProcessInfo.processInfo.environment["HC_TRIAL_PAYLOAD"] != nil && ProcessInfo.processInfo.environment["HC_TRIAL_REPORT"] != nil, "Requires private SNES recovery and trial files"))
    func preparedTrialIsBoundToValidatedOriginalMenu() async throws {
        let env = ProcessInfo.processInfo.environment
        let baseURL = URL(fileURLWithPath: try #require(env["HC_TRIAL_MENU_DIRECTORY"]))
        let root = URL(fileURLWithPath: try #require(env["HC_TRIAL_PAYLOAD"]))
        let report = try Data(contentsOf: URL(fileURLWithPath: try #require(env["HC_TRIAL_REPORT"])))
        let pinned = try PinnedFELInputs.load()
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: baseURL.appendingPathComponent("manifest.json"))) as? [String: Any])
        func path(_ key: String) throws -> URL { URL(fileURLWithPath: try #require(saved[key] as? String)) }
        print("HC_CAPABILITY stage=setup")
        let setup = try SNESOfflineSource.load(snapshot: path("setupPath"))
        print("HC_CAPABILITY stage=preparation")
        let src = try SNESMenuSupportSource.load(setup: setup, preparation: path("preparationPath"))
        print("HC_CAPABILITY stage=support")
        let sup = try SNESMenuSupportMaterial.load(source: src, directory: path("supportPath"))
        print("HC_CAPABILITY stage=components")
        let components = try SNESOriginalComponentMaterial.load(source: SNESOriginalComponentSource(material: sup), directory: path("componentsPath"))
        print("HC_CAPABILITY stage=runtime")
        let runtime = try SNESRuntimeMaterial.load(directory: path("runtimePath"), source: setup)
        let material = try SNESOriginalMenuMaterial(components: components, runtime: runtime)
        print("HC_CAPABILITY stage=load-base")
        let archived = try Data(contentsOf: baseURL.appendingPathComponent("original-menu.img"))
        let base = try SNESOriginalMenuRecipe.prepare(material: material, archivedImage: archived, recovery: .init(fes1: pinned.fes1, uboot: pinned.uboot, bootImage: pinned.bootImage))
        let names = ["retroarch", "snes9x2010_libretro.so", "alien3.smc", "retroarch.cfg", "autoconfig/Nintendo Clovercon - controller1.cfg", "trial-start"]
        let payload = try Dictionary(uniqueKeysWithValues: names.map { ($0, try Data(contentsOf: root.appendingPathComponent($0))) })
        print("HC_CAPABILITY stage=build-trial")
        let trial = try PreparedSNESAlienTrial(base: base, payload: payload, report: report)
        print("HC_CAPABILITY stage=validate-trial")
        try trial.validateCurrent()
        #expect(trial.expectation.nonce == base.nonce)
        #expect(trial.expectation.filesSHA256 != base.filesSHA256)
        #expect(trial.expectation.binding.expectedHWID == base.expectation.binding.expectedHWID)
        #expect(try LegacyBootImageBuilder.inspect(trial.image).kernel == LegacyBootImageBuilder.inspect(base.image).kernel)
        var bad = payload; bad["retroarch"] = Data()
        #expect(throws: (any Error).self) { try PreparedSNESAlienTrial(base: base, payload: bad, report: report) }
        let errorRoot = try testDirectory(); defer { try? FileManager.default.removeItem(at: errorRoot) }
        let emptyFailure = SNESAlienTrialFailure(stage: "temporary-startup-requested", cause: "USB unavailable", diagnostics: Data())
        let failureDirectory = try await RecoveryBootSnapshotStore(root: errorRoot).saveSNESAlienTrialFailure(emptyFailure, trial: trial)
        let failureLog = try Data(contentsOf: failureDirectory.appendingPathComponent("diagnostic.log"))
        #expect(!failureLog.isEmpty)
        let io = AlienTrialFakeIO(trial: trial)
        let serviceRoot = try testDirectory(); defer { try? FileManager.default.removeItem(at: serviceRoot) }
        let result = try await SNESAlienTrialService(wait: {}).start(trial: trial, store: RecoveryBootSnapshotStore(root: serviceRoot), io: io)
        #expect(result.report.pid == 123)
        #expect(await io.events == ["inventory", "boot", "inventory", "inventory", "connect", "checkpoint", "inventory", "launch", "report", "inventory", "disconnect"])
        let bootFailureIO = AlienTrialFakeIO(trial: trial, failBoot: true)
        do {
            _ = try await SNESAlienTrialService(wait: {}).start(trial: trial, store: RecoveryBootSnapshotStore(root: serviceRoot), io: bootFailureIO)
            Issue.record("Boot failure was accepted")
        } catch let failure as SNESAlienTrialFailure {
            #expect(failure.stage == "temporary-startup-requested")
            #expect(failure.cause.contains("fixture boot failure"))
        }
        #expect(!(await bootFailureIO.events).contains("launch"))
        #expect((await bootFailureIO.events).last == "disconnect")
        let badIO = AlienTrialFakeIO(trial: trial, failCheckpoint: true)
        await #expect(throws: (any Error).self) { _ = try await SNESAlienTrialService(wait: {}).start(trial: trial, store: RecoveryBootSnapshotStore(root: serviceRoot), io: badIO) }
        #expect(!(await badIO.events).contains("launch"))
        #expect((await badIO.events).last == "disconnect")
        let failedReportIO = AlienTrialFakeIO(trial: trial, failReport: true)
        await #expect(throws: (any Error).self) { _ = try await SNESAlienTrialService(wait: {}).start(trial: trial, store: RecoveryBootSnapshotStore(root: serviceRoot), io: failedReportIO) }
        #expect((await failedReportIO.events).filter { $0 == "launch" }.count == 1)
        #expect((await failedReportIO.events).contains("diagnostics"))
        #expect((await failedReportIO.events).last == "disconnect")
        let before = probeFEL()
        let after = RecoveryProbeUSBDevice(vendorID: 0x1f3a, productID: 0xefe8, deviceVersion: 0x6a03, deviceClass: 0, locationID: before.locationID, product: SNESOriginalMenuUSBPolicy.product, registryEntryID: 999)
        let challenge = UUID()
        let raw = originalMenuReportFixture(expected: trial.expectation, challenge: challenge, state: .preMenu)
        let checkpoint = SNESAlienTrialCheckpoint(before: before, after: after, challenge: challenge, report: raw)
        let temporary = try testDirectory(); defer { try? FileManager.default.removeItem(at: temporary) }
        let store = try RecoveryBootSnapshotStore(root: temporary)
        let request = try await checkpoint.persistForLaunch(trial: trial, store: store)
        try request.validateCurrent()
        #expect(request.command.contains(BackupManifest.digest(raw)))
        try Data("tampered".utf8).write(to: request.checkpointDirectory.appendingPathComponent("checkpoint.bin"))
        #expect(throws: (any Error).self) { try request.validateCurrent() }

    }
}

actor AlienTrialFakeIO: SNESAlienTrialIO {
    let trial: PreparedSNESAlienTrial, failCheckpoint: Bool, failReport: Bool, failBoot: Bool
    var events: [String] = [], inventories = 0
    init(trial: PreparedSNESAlienTrial, failCheckpoint: Bool = false, failReport: Bool = false, failBoot: Bool = false) { self.trial = trial; self.failCheckpoint = failCheckpoint; self.failReport = failReport; self.failBoot = failBoot }
    func inventory() throws -> [RecoveryProbeUSBDevice] {
        events.append("inventory"); inventories += 1
        let before = probeFEL()
        if inventories == 1 { return [before] }
        return [RecoveryProbeUSBDevice(vendorID: 0x1f3a, productID: 0xefe8, deviceVersion: 0x6a03, deviceClass: 0, locationID: before.locationID, product: SNESOriginalMenuUSBPolicy.product, registryEntryID: 999)]
    }
    func boot(expected: RecoveryProbeUSBDevice) throws { events.append("boot"); if failBoot { throw NSError(domain: "fixture boot failure", code: 42, userInfo: [NSLocalizedDescriptionKey: "fixture boot failure"]) } }
    func connect(expected: RecoveryProbeUSBDevice) { events.append("connect") }
    func checkpoint(challenge: UUID) -> Data { events.append("checkpoint"); if failCheckpoint { return Data() }; return originalMenuReportFixture(expected: trial.expectation, challenge: challenge, state: .preMenu) }
    func launch(_ request: SNESAlienTrialLaunchRequest) throws { events.append("launch"); try request.validateCurrent() }
    func report(challenge: UUID) -> Data {
        events.append("report")
        if failReport { return Data() }
        return Data("SWIFTHAKCHI_SNES_TRIAL_V1\nNONCE=\(trial.expectation.nonce)\nCHALLENGE=\(challenge.uuidString)\nSTATUS=running\nTRIAL_PID=123\nDAEMON_PID=456\nEXEC_SHA=\(trial.frontendSHA256)\nEND\n".utf8)
    }
    func diagnostics() -> Data { events.append("diagnostics"); return originalMenuDiagnosticsFixture(nonce: trial.expectation.nonce) }
    func disconnect() { events.append("disconnect") }
}
