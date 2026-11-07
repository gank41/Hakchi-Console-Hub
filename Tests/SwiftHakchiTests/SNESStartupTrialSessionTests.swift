import Foundation
import os
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

let startupTrialFEL=RecoveryProbeUSBDevice(vendorID:0x1f3a,productID:0xefe8,deviceVersion:0x2b3,deviceClass:0,locationID:42,product:"",registryEntryID:1)
let startupTrialUSB=RecoveryProbeUSBDevice(vendorID:0x1f3a,productID:0xefe8,deviceVersion:0x6a04,deviceClass:0,locationID:42,product:"Swift Hakchi SNES Startup",registryEntryID:2)
actor StartupTrialSessionFake:SNESStartupTrialIO {
    let expected:SNESStartupTrialExpectation,fault:String
    var booted:Bool,events:[String]=[],reports=0
    init(expected:SNESStartupTrialExpectation,fault:String,booted:Bool=false){self.expected=expected;self.fault=fault;self.booted=booted}
    private var startupUSB: RecoveryProbeUSBDevice {
        RecoveryProbeUSBDevice(vendorID: 0x1f3a, productID: 0xefe8, deviceVersion: expected.deviceVersion,
            deviceClass: 0, locationID: 42, product: "Swift Hakchi SNES Startup", registryEntryID: 2)
    }
    func inventory()->[RecoveryProbeUSBDevice] {
        events.append("inventory")
        if fault=="inventory" {return [startupTrialFEL,startupTrialFEL]}
        if fault=="no-arrival",booted {return []}
        if fault=="attachment",reports>0 {return []}
        return [booted ? startupUSB:startupTrialFEL]
    }
    func boot(expected:RecoveryProbeUSBDevice,validateInputs:@escaping @Sendable () throws -> Void)throws {try validateInputs();events.append("boot");#expect(expected==startupTrialFEL);if fault=="boot" {throw SNESRuntimeBinding.failure()};booted=true;try validateInputs()}
    func connect(expected:RecoveryProbeUSBDevice)throws {events.append("connect");#expect(expected==startupUSB);if fault=="connect" {throw SNESRuntimeBinding.failure()}}
    func report(challenge:UUID)throws->Data {
        events.append("report");reports+=1
        if fault=="cancel" {throw CancellationError()}
        let id=(fault=="report" || (fault=="second" && reports==2)) ? UUID():challenge
        var report = String(decoding: startupTrialReportFixture(challenge:id,hwid:expected.hwid,runtime:expected.runtimeSHA256,wrapper:expected.wrapperSHA256), as: UTF8.self)
        if expected.menuEnabled {
            report = report.replacingOccurrences(of: "MOUNTS_END", with: "tmpfs /etc/init.d/S81clover-mcp tmpfs rw,nosuid,nodev 0 0\nMOUNTS_END")
        }
        if expected.requiresCleanMenuLaunch {
            report = report.replacingOccurrences(of: "MOUNTS_BEGIN\n", with: "MCP_SIGBLK=0000000000000000\nUI_SIGBLK=0000000000000000\nMOUNTS_BEGIN\n")
        }
        return Data(report.utf8)
    }
    func disconnect(){events.append("close")}
}
@Suite(.serialized)
struct SNESStartupTrialSessionTests {
    @Test(arguments: [UInt16(0x6a04), UInt16(0x6a05), UInt16(0x6a0a), UInt16(0x6a0b)])
    func fakeReportsMatchEachStartupLayout(_ version: UInt16) async throws {
        let expected = SNESStartupTrialExpectation(hwid: String(repeating: "1", count: 32),
            runtimeSHA256: String(repeating: "2", count: 64), wrapperSHA256: String(repeating: "3", count: 64),
            deviceVersion: version, menuWrapperSHA256: version == 0x6a04 ? nil : String(repeating: "4", count: 64))
        let fake = StartupTrialSessionFake(expected: expected, fault: "none")
        let challenge = UUID()
        let report = try await fake.report(challenge: challenge)
        _ = try SNESStartupTrialReport(report, expected: expected, challenge: challenge)
        let running = StartupTrialSessionFake(expected: expected, fault: "none", booted: true)
        #expect(await running.inventory().first?.deviceVersion == version)
    }
    @Test @MainActor func savedReviewInspectionRequiresAnOpenSNESGuide() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig(); config.workspacePath = root.path; config.backupDirectoryPath = root.path; config.lastConsoleType = .snesUsa
        let app = AppState(startDeviceMonitoring: false, config: config, saveConfiguration: {}, checkRecoveryHost: {
            Issue.record("A read-only review should not inspect a console")
        })
        let missing = root.appendingPathComponent("missing")
        await #expect(throws: (any Error).self) { try await app.inspectSNESFirstInstallReview(directory: missing) }
        app.isPreparingSync = true; config.lastConsoleType = .nes
        await #expect(throws: (any Error).self) { try await app.inspectSNESFirstInstallReview(directory: missing) }
    }
    @Test @MainActor func rejectsOverlappingSetupBeforeStartingSecondCheck() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig(); config.workspacePath = root.path; config.backupDirectoryPath = root.path; config.lastConsoleType = .snesUsa
        let app = AppState(startDeviceMonitoring: false, config: config, saveConfiguration: {})
        app.isPreparingSync = true
        let missing = root.appendingPathComponent("missing")
        let backup = SNESSetupRecordReceipt(kind: .backup, directory: missing, manifestSHA256: String(repeating: "0", count: 64))
        let gate = TrialHostGate()
        let first = Task { try await app.checkSNESStartup(backup: backup, recovery: missing, helpers: missing, progress: { _ in await gate.pauseFirst() }) }
        try await gate.waitUntilPaused()
        let secondMessage: String
        do {
            _ = try await app.checkSNESStartup(backup: backup, recovery: missing, helpers: missing, progress: { _ in })
            secondMessage = "accepted overlapping check"
        } catch { secondMessage = error.localizedDescription }
        await gate.release()
        _ = try? await first.value
        #expect(secondMessage.contains("Another SNES"))
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_CURRENT_DATA"] != nil))
    @MainActor func appRunsTemporaryStartupAndPostGameCheckWithoutASecondBoot() async throws {
        let candidate = try await SNESStartupPreflightFixtureCache.shared.candidate(), pinned = try PinnedFELInputs.load()
        let inputs = RecoveryBootInputs(fes1: pinned.fes1, uboot: pinned.uboot, bootImage: pinned.bootImage)
        let preflightIO = try SNESStartupPreflightFakeIO(candidate: candidate, fault: "none")
        let preflight = try await SNESStartupPreflightService(wait: {}).capture(candidate: candidate, inputs: inputs, io: preflightIO)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryBootSnapshotStore(root: root)
        let candidateReceipt = try await store.saveSNESStartupCandidateWithReceipt(candidate)
        let preflightReceipt = try await store.saveSNESStartupPreflightWithReceipt(preflight)
        let trial = try PreparedSNESStartupTrial.prepare(candidate: candidate, receipt: preflightReceipt, recovery: inputs)
        let io = StartupTrialSessionFake(expected: try .checked(trial), fault: "none"), calls = ConnectionCallCounter(), gate = TrialHostGate()
        let source = try SNESPreparationSource.load(candidate.material.support.setup)
        let activeIO = SNESActiveBoot2FakeIO(source: source, fault: "none")
        let dataIO = try SNESDataSnapshotFakeIO(source: source, fault: "none")
        let helpers = try await store.saveSNESPortableHelpers()
        let config = AppConfig(); config.workspacePath = root.path; config.backupDirectoryPath = root.path; config.lastConsoleType = .snesUsa
        let app = AppState(startDeviceMonitoring: false, config: config, saveConfiguration: {},
            checkRecoveryHost: { await calls.record(1); await gate.pauseFirst() }, makeSNESDataSnapshotIO: { _ in dataIO },
            makeSNESStartupTrialIO: { _ in io }, makeSNESActiveBoot2IO: { _,_ in activeIO })
        app.isPreparingSync = true
        let stale = SNESStartupPreflightReceipt(record: preflightReceipt.record, backupMatches: false)
        await #expect(throws: (any Error).self) { try await app.runSNESStartupTrial(candidate: candidateReceipt, preflight: stale, progress: { _ in }) }
        #expect(await calls.ids.isEmpty); #expect(await io.events.isEmpty)
        let first = Task { try await app.runSNESStartupTrial(candidate: candidateReceipt, preflight: preflightReceipt, progress: { _ in }) }
        try await gate.waitUntilPaused()
        await #expect(throws: (any Error).self) { try await app.runSNESStartupTrial(candidate: candidateReceipt, preflight: preflightReceipt, progress: { _ in }) }
        let selectedBackup=SNESSetupRecordReceipt(kind:.backup,directory:source.source.directoryURL,manifestSHA256:source.source.manifestSHA256)
        let overlapMessage:String
        do {
            _=try await app.checkSNESStartup(backup:selectedBackup,recovery:root.appendingPathComponent("missing"),helpers:helpers,progress:{_ in})
            overlapMessage = "overlapping setup check was accepted"
        } catch {
            overlapMessage = error.localizedDescription
        }
        #expect(await calls.ids.count == 1); #expect(await io.events.isEmpty)
        await gate.release()
        try #require(overlapMessage.contains("Another SNES"))
        let started = try await first.value
        #expect(started.kind == .trialStarted)
        let played = try await app.runSNESStartupTrial(candidate: candidateReceipt, preflight: preflightReceipt, started: started, progress: { _ in })
        #expect(played.kind == .trialPlayed)
        _ = try SNESFirmwareTrialProof.load(started: started.directory, played: played.directory, trial: trial,
            expectedStartedSHA256: started.manifestSHA256, expectedPlayedSHA256: played.manifestSHA256)
        #expect(await io.events.filter { $0 == "boot" }.count == 1)
        #expect(await io.events.filter { $0 == "close" }.count == 2)
        let backup = SNESSetupRecordReceipt(kind: .backup, directory: source.source.directoryURL, manifestSHA256: source.source.manifestSHA256)
        let wrongPlayed = SNESSetupRecordReceipt(kind: .trialPlayed, directory: played.directory, manifestSHA256: String(repeating: "0", count: 64))
        await #expect(throws: (any Error).self) {
            try await app.captureSNESActiveStartup(backup: backup, helpers: helpers, candidate: candidateReceipt,
                preflight: preflightReceipt, started: started, played: wrongPlayed, progress: { _ in })
        }
        #expect(await activeIO.base.events.isEmpty)
        let active = try await app.captureSNESActiveStartup(backup: backup, helpers: helpers, candidate: candidateReceipt,
            preflight: preflightReceipt, started: started, played: played, progress: { _ in })
        #expect(active.kind == .activeBoot2)
        let saved = try SNESActiveBoot2Package.load(directory: active.directory, source: source)
        #expect(saved.manifestSHA256 == active.manifestSHA256 && saved.byteCount == 7340032)
        #expect(await activeIO.reads == 2); #expect(await activeIO.base.events.filter { $0 == "disconnect" }.count == 1)
        let support = candidate.material.support, components = candidate.material.components
        let chain = SNESSetupRecordChain(
            startup: SNESSetupRecordReceipt(kind: .startup, directory: support.source.directoryURL, manifestSHA256: support.source.manifestSHA256),
            support: SNESSetupRecordReceipt(kind: .menuSupport, directory: support.directoryURL, manifestSHA256: support.manifestSHA256),
            components: SNESSetupRecordReceipt(kind: .components, directory: components.directoryURL, manifestSHA256: components.manifestSHA256))
        let recovery = try await store.saveSNESRecoveryMaterial(SNESRecoveryMaterial.load(setup: backup.directory))
        let latestData = try await app.backupSNESData(backup: backup, recovery: recovery, helpers: helpers, chain: chain, progress: { _ in }, detail: { _ in })
        let latestPackage = try SNESDataSnapshotPackage.load(receipt: latestData, source: source)
        #expect(latestPackage.sha256 != candidate.backup.sha256); #expect(await dataIO.hashes == 3)
        let filesBeforeReview = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        let currentData = SNESDataSnapshotReceipt(directory: candidate.backup.directory, manifestSHA256: candidate.backup.manifestSHA256)
        let wrongData = SNESDataSnapshotReceipt(directory: currentData.directory, manifestSHA256: String(repeating: "0", count: 64))
        let wrongActive = SNESSetupRecordReceipt(kind: .activeBoot2, directory: active.directory, manifestSHA256: String(repeating: "0", count: 64))
        await #expect(throws: (any Error).self) {
            try await app.prepareSNESFirmwarePlan(backup: backup, helpers: helpers, candidate: candidateReceipt, preflight: preflightReceipt,
                started: started, played: played, active: wrongActive, currentData: currentData)
        }
        await #expect(throws: (any Error).self) {
            try await app.prepareSNESFirmwarePlan(backup: backup, helpers: helpers, candidate: candidateReceipt, preflight: preflightReceipt,
                started: started, played: played, active: active, currentData: wrongData)
        }
        let plan = try await app.prepareSNESFirmwarePlan(backup: backup, helpers: helpers, candidate: candidateReceipt, preflight: preflightReceipt,
            started: started, played: played, active: active, currentData: latestData)
        #expect((1...56).contains(plan.changedUnits)); #expect(await calls.ids.count == 4)
        let savedReview = try #require(plan.savedReview)
        #expect(savedReview.sha256 == plan.offlineReviewSHA256)
        let reopened = try SNESFirstInstallReviewReceipt.open(savedReview)
        #expect(reopened.dataManifestSHA256 == latestData.manifestSHA256)
        #expect(reopened.dataSHA256 == latestPackage.sha256)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == (filesBeforeReview + [savedReview.directory.lastPathComponent]).sorted())
        let inspected = try await app.inspectSNESFirstInstallReview(directory: savedReview.directory)
        #expect(inspected.changedUnits == plan.changedUnits)
        #expect(inspected.dataDirectory == latestData.directory)
        #expect(inspected.reviewSHA256 == savedReview.sha256)
        #expect(await calls.ids.count == 4)
        // A Mac-only preparation must use the exact selected review and keep
        // its resulting operation ID and digest for all later attempts.
        let journalRoot=root.appendingPathComponent("app-firmware-journals")
        try FileManager.default.createDirectory(at:journalRoot,withIntermediateDirectories:false)
        let shellBox=OSAllocatedUnfairLock(initialState:Optional<SNESFirmwareShellFake>.none)
        let checkApp=AppState(startDeviceMonitoring:false,config:config,saveConfiguration:{},checkRecoveryHost:{},firmwareJournalRoot:{journalRoot},
            makeSNESFirmwareIO:{material,guardValue in
                let base=SNESFirmwareFakeIO(material:material,fault:"none")
                let shell=SNESFirmwareShellFake(material:material,fault:"none",reviewedHash:material.firstInstall?.dataSHA256)
                shellBox.withLock {$0=shell}
                return try NativeSNESFirmwareIO(material:material,guard:guardValue,base:base,shell:shell,testLibraryRoot:root)
            })
        checkApp.isPreparingSync=true
        let wrongReview=SNESFirstInstallReviewReceipt(directory:savedReview.directory,sha256:String(repeating:"0",count:64))
        await #expect(throws:(any Error).self) {try await checkApp.prepareSNESReviewedConsoleCheck(review:wrongReview)}
        #expect(try FileManager.default.contentsOfDirectory(atPath:journalRoot.path).isEmpty)
        let prepared=try await checkApp.prepareSNESReviewedConsoleCheck(review:savedReview)
        #expect(prepared.review.sha256 == savedReview.sha256 && prepared.review.directory == savedReview.directory)
        #expect(prepared.operation.deletingLastPathComponent().path == journalRoot.path)
        let journal=try await SNESFirmwareJournal.reopen(operation:prepared.operation,reviewSHA256:prepared.planSHA256,recovery:inputs)
        let preparedMaterial=try await journal.verifiedMaterial()
        #expect(try await journal.phase() == .prepared)
        #expect(preparedMaterial.firstInstall?.reviewSHA256 == savedReview.sha256)
        #expect(preparedMaterial.firstInstall?.reviewDirectory == savedReview.directory.path)
        try await journal.close()
        let recovered=try await checkApp.reopenSNESReviewedConsoleCheck(operation:prepared.operation,review:savedReview)
        #expect(recovered.operation == prepared.operation && recovered.planSHA256 == prepared.planSHA256)
        await #expect(throws:(any Error).self) {try await checkApp.reopenSNESReviewedConsoleCheck(operation:prepared.operation,review:wrongReview)}
        await #expect(throws:(any Error).self) {try await checkApp.runSNESReviewedConsoleCheck(prepared,ready:false,progress:{_ in})}
        #expect(shellBox.withLock {$0 == nil})
        try await checkApp.runSNESReviewedConsoleCheck(prepared,ready:true,progress:{_ in})
        let appShell=try #require(shellBox.withLock {$0})
        #expect(await appShell.writeCalls == 0)
        #expect(await appShell.hashLimits != nil)
        let after=try await SNESFirmwareJournal.reopen(operation:prepared.operation,reviewSHA256:prepared.planSHA256,recovery:inputs)
        #expect(try await after.phase() == .prepared)
        try await after.close()
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_STARTUP_PREFLIGHT"] != nil))
    func playedTrialRejectsChangedFinalRecordAndRemovesCompletionMarker() async throws {
        let trial = try await SNESStartupTrialFixtureCache.shared.trial(), expected = try SNESStartupTrialExpectation.checked(trial)
        let io = StartupTrialSessionFake(expected: expected, fault: "none")
        let service = SNESStartupTrialService(wait: {})
        let startedResult = try await service.capture(trial: trial, io: io)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryBootSnapshotStore(root: root)
        let started = try await store.saveSNESStartupTrialStartedWithReceipt(startedResult, trial: trial)
        let playedResult = try await service.capture(trial: trial, started: startedResult, io: io)
        let wrong = SNESSetupRecordReceipt(kind: .trialStarted, directory: started.directory, manifestSHA256: String(repeating: "0", count: 64))
        await #expect(throws: (any Error).self) { try await store.saveSNESStartupTrialPlayedWithReceipt(playedResult, trial: trial, started: wrong) }
        await #expect(throws: (any Error).self) {
            try await store.saveSNESStartupTrialPlayedWithReceipt(playedResult, trial: trial, started: started, verify: { directory in
                let file = directory.appendingPathComponent("report-0.txt")
                var bytes = try Data(contentsOf: file); bytes.append(32); try bytes.write(to: file)
            })
        }
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(directories.count == 2)
        let incomplete = try #require(directories.first { $0 != started.directory })
        #expect(!FileManager.default.fileExists(atPath: incomplete.appendingPathComponent("manifest.json").path))
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_STARTUP_PREFLIGHT"] != nil))
    func savedStartedTrialReturnsPinnedReceiptAndRejectsFinalMutation() async throws {
        let trial = try await SNESStartupTrialFixtureCache.shared.trial()
        let io = StartupTrialSessionFake(expected: try .checked(trial), fault: "none")
        let result = try await SNESStartupTrialService(wait: {}).capture(trial: trial, io: io)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryBootSnapshotStore(root: root)
        let receipt = try await store.saveSNESStartupTrialStartedWithReceipt(result, trial: trial)
        #expect(receipt.kind == .trialStarted)
        let raw = try Data(contentsOf: receipt.directory.appendingPathComponent("manifest.json"))
        #expect(receipt.manifestSHA256 == BackupManifest.digest(raw))
        let loaded = try SNESStartupTrialResult.loadStarted(receipt: receipt, trial: trial)
        try loaded.requireSavedReceipt(receipt)
        let wrong = SNESSetupRecordReceipt(kind: .trialStarted, directory: receipt.directory, manifestSHA256: String(repeating: "0", count: 64))
        #expect(throws: (any Error).self) { try SNESStartupTrialResult.loadStarted(receipt: wrong, trial: trial) }
        #expect(throws: (any Error).self) { try loaded.requireSavedReceipt(wrong) }
        let report = receipt.directory.appendingPathComponent("report-0.txt"), originalReport = try Data(contentsOf: report)
        var changedReport = originalReport; changedReport.append(32); try changedReport.write(to: report)
        #expect(throws: (any Error).self) { try loaded.requireSavedReceipt(receipt) }
        try originalReport.write(to: report)
        await #expect(throws: (any Error).self) {
            try await store.saveSNESStartupTrialStartedWithReceipt(result, trial: trial, verify: { directory in
                let file = directory.appendingPathComponent("report-0.txt")
                var bytes = try Data(contentsOf: file); bytes.append(32); try bytes.write(to: file)
            })
        }
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let incomplete = try #require(directories.first { $0 != receipt.directory })
        #expect(!FileManager.default.fileExists(atPath: incomplete.appendingPathComponent("manifest.json").path))
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_STARTUP_PREFLIGHT"] != nil),arguments:[0,20000])
    func retainsBoundedFailureEvidenceEvenWhenSourceReceiptChanges(_ count:Int) async throws {
        let original=try await SNESStartupTrialFixtureCache.shared.trial(),root=try testDirectory()
        defer {try? FileManager.default.removeItem(at:root)}
        let receipt=root.appendingPathComponent(original.evidence.directory.lastPathComponent)
        try FileManager.default.copyItem(at:original.evidence.directory,to:receipt)
        let pins=try PinnedFELInputs.load()
        let trial=try PreparedSNESStartupTrial.prepare(candidate:original.candidate,evidence:receipt,recovery:.init(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage))
        let manifest=receipt.appendingPathComponent("manifest.json")
        var raw=try Data(contentsOf:manifest);raw.append(32);try raw.write(to:manifest)
        #expect(throws:(any Error).self) {try trial.validateCurrent()}
        let backups=root.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at:backups,withIntermediateDirectories:false)
        let store=try RecoveryBootSnapshotStore(root:backups)
        let saved=try await store.saveSNESStartupTrialFailure(.init(stage:"checking-menu-and-startup",report:Data(repeating:65,count:count)),trial:trial)
        let evidence=count==0 ? Data():try Data(contentsOf:saved.appendingPathComponent("partial-report.bin"))
        let m=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:saved.appendingPathComponent("manifest.json"))) as? [String:Any])
        #expect(evidence.count==min(count,16384) && m["complete"] as? Bool==false && m["firmwareInstallEligible"] as? Bool==false)
        #expect(m["stage"] as? String=="checking-menu-and-startup")
        if count==0 {#expect(try FileManager.default.contentsOfDirectory(atPath:saved.path)==["manifest.json"])}
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_STARTUP_PREFLIGHT"] != nil))
    func recordsUnderlyingFailureBeforeAnyReportArrives() async throws {
        let trial=try await SNESStartupTrialFixtureCache.shared.trial(),io=StartupTrialSessionFake(expected:try .checked(trial),fault:"boot")
        do {_=try await SNESStartupTrialService(wait:{}).capture(trial:trial,io:io);Issue.record("Expected fake boot failure")}
        catch let failure as SNESStartupTrialFailure {
            let e=try failure.checkedExport(trial:trial),m=try #require(JSONSerialization.jsonObject(with:e.manifest) as? [String:Any])
            #expect(m["stage"] as? String=="temporary-startup")
            #expect((m["reason"] as? String)?.isEmpty==false)
            #expect(e.files.isEmpty)
        }
    }
    @Test func recognizesOnlyExpectedNewUSBDevice()throws {
        #expect(try SNESStartupTrialUSBPolicy.after([startupTrialUSB],original:startupTrialFEL)==startupTrialUSB)
        #expect(try SNESStartupTrialUSBPolicy.after([startupTrialFEL],original:startupTrialFEL)==nil)
        #expect(try SNESStartupTrialUSBPolicy.after([],original:startupTrialFEL)==nil)
        let wrong=RecoveryProbeUSBDevice(vendorID:0x1f3a,productID:0xefe8,deviceVersion:0x6a03,deviceClass:0,locationID:42,product:"Swift Hakchi SNES Original Menu Test",registryEntryID:3)
        #expect(throws:(any Error).self) {try SNESStartupTrialUSBPolicy.after([wrong],original:startupTrialFEL)}
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_STARTUP_PREFLIGHT"] != nil),arguments:["none","inventory","boot","connect","report","second","attachment","cancel","no-arrival"])
    func runsOnceAndClosesOnEveryOutcome(_ fault:String) async throws {
        let trial=try await SNESStartupTrialFixtureCache.shared.trial(),io=StartupTrialSessionFake(expected:try .checked(trial),fault:fault)
        let service=SNESStartupTrialService(wait:{},attempts:2)
        if fault=="none" {
            let result=try await service.capture(trial:trial,io:io),e=try result.checkedExport(trial:trial)
            let m=try #require(JSONSerialization.jsonObject(with:e.manifest) as? [String:Any])
            #expect(result.phase=="started" && result.reports.count==2)
            #expect(m["firmwareWritten"] as? Bool==false && m["firmwareInstallEligible"] as? Bool==false && m["profileWritesPossible"] as? Bool==true)
        } else {await #expect(throws:(any Error).self) {try await service.capture(trial:trial,io:io)}}
        let events=await io.events
        #expect(events.filter{$0=="close"}.count==1)
        #expect(events.filter{$0=="boot"}.count==(fault=="inventory" ? 0:1))
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_STARTUP_PREFLIGHT"] != nil))
    func afterGameCheckNeverRequestsAnotherBoot() async throws {
        let trial=try await SNESStartupTrialFixtureCache.shared.trial(),expected=try SNESStartupTrialExpectation.checked(trial)
        let first=StartupTrialSessionFake(expected:expected,fault:"none")
        let started=try await SNESStartupTrialService(wait:{}).capture(trial:trial,io:first)
        let io=StartupTrialSessionFake(expected:expected,fault:"none",booted:true)
        let result=try await SNESStartupTrialService(wait:{}).capture(trial:trial,started:started,io:io)
        #expect(result.phase=="after-gameplay")
        #expect(await io.events.contains("boot")==false)
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_STARTUP_PREFLIGHT"] != nil))
    func exportsExactReadOnlyReportForExecutionFixture() async throws {
        let trial=try await SNESStartupTrialFixtureCache.shared.trial()
        let script=try SNESStartupTrialCommands.script(trial:trial,challenge:UUID(uuidString:"11111111-1111-1111-1111-111111111111")!)
        #expect(script.isEmpty==false)
        if let p=ProcessInfo.processInfo.environment["SWIFTHAKCHI_STARTUP_TRIAL_EXPORT"] {try Data(script.utf8).write(to:URL(fileURLWithPath:p).appendingPathComponent("report.sh"),options:.withoutOverwriting)}
    }
}
private actor TrialHostGate {
    private var reached = false
    private var paused: CheckedContinuation<Void, Never>?
    func pauseFirst() async {
        guard !reached else { return }
        reached = true
        await withCheckedContinuation { paused = $0 }
    }
    func waitUntilPaused() async throws {
        for _ in 0..<1500 {
            if reached { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw SNESRuntimeBinding.failure()
    }
    func release() { paused?.resume(); paused = nil }
}
