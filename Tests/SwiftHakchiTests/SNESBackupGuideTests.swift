import Foundation
import Testing
@testable import SwiftHakchi

private actor RecoveryCancellationProbe {
    var started = false
    var cancelled = false
    func wait() async throws -> URL {
        started = true
        do { try await Task.sleep(for: .seconds(30)) }
        catch { cancelled = true; throw error }
        return URL(fileURLWithPath: "/tmp/unexpected")
    }
}
private actor StartupTestCompletion {
    var finished = false
    func markFinished() { finished = true }
}

private func setupReceipt(_ kind: SNESSetupRecordReceipt.Kind, _ url: URL, hash: String = String(repeating: "a", count: 64)) -> SNESSetupRecordReceipt {
    SNESSetupRecordReceipt(kind: kind, directory: url, manifestSHA256: hash)
}

@Suite(.serialized) @MainActor struct SNESBackupGuideTests {
    @Test(arguments: ["success", "save-fails", "save-fails-normal", "refresh-fails", "refresh-fails-normal"]) func latestDataBackupIsIndependentAndRequiresPowerOff(_ scenario: String) async {
        let fail = scenario == "save-fails" || scenario == "save-fails-normal"
        let old = URL(fileURLWithPath: "/tmp/earlier"), latest = URL(fileURLWithPath: "/tmp/latest"), calls = ConnectionCallCounter()
        let oldData = SNESDataSnapshotReceipt(directory: old, manifestSHA256: String(repeating: "b", count: 64))
        let latestData = SNESDataSnapshotReceipt(directory: latest, manifestSHA256: String(repeating: "c", count: 64))
        let guide = SNESBackupGuide(execute: { _ in setupReceipt(.backup, old) }, prepareRecovery: { _ in old }, prepareHelpers: { old },
            prepareStartup: { _,_,_,_ in setupReceipt(.startup, old) }, captureMenuSupport: { _,_,_,_,_ in setupReceipt(.menuSupport, old) },
            captureComponents: { _,_,_,_,_,_ in setupReceipt(.components, old) }, captureData: { _,_,_,_,_,_ in
                await calls.record(1)
                let count = await calls.ids.count
                if count == 1 { return oldData }
                if fail || (scenario.hasPrefix("refresh-fails") && count == 3) { throw SNESDataSnapshotPostSaveError(location: latest, backupVerified: true) }
                return latestData
            }, captureRuntime: { _,_,_,_,_,_ in setupReceipt(.runtime, old) },
            prepareCandidate: { _,_,_,_,_,_,_ in setupReceipt(.candidate, old) },
            preflight: { _,_ in SNESStartupPreflightReceipt(record: setupReceipt(.preflight, old), backupMatches: true) },
            startTrial: { _,_,_ in setupReceipt(.trialStarted, old) }, checkTrial: { _,_,_,_ in setupReceipt(.trialPlayed, old) },
            captureActive: { _,_,_,_,_,_,_ in setupReceipt(.activeBoot2, old) },
            prepareFirmwarePlan: { _,_,_,_,_,_,_,data in
                #expect(data.directory == latest && data.manifestSHA256 == latestData.manifestSHA256)
                await calls.record(2)
                return SNESFirmwarePreparationReceipt(offlineReviewSHA256: String(repeating: "d", count: 64), changedUnits: 1)
            })
        await guide.start(ready: true); guide.confirmNormalBoot(); guide.reviewStartupCheck(); await guide.startStartupCheck(ready: true)
        guide.confirmStartupNormalBoot(); guide.reviewMenuSupport(); await guide.startMenuSupport(ready: true)
        guide.confirmMenuSupportNormalBoot(); guide.reviewComponents(); await guide.startComponents(ready: true)
        guide.confirmComponentsNormalBoot(); guide.reviewDataBackup(); await guide.startDataBackup(ready: true)
        guide.confirmDataNormalBoot(); guide.reviewRuntime(); await guide.startRuntime(ready: true); guide.confirmRuntimeNormalBoot()
        await guide.startCandidate(); guide.reviewPreflight(); await guide.startPreflight(ready: true); guide.confirmPreflightNormalBoot()
        guide.reviewTrial(); await guide.startTrial(ready: true); await guide.checkTrial(gameWorks: true); guide.confirmTrialNormalBoot()
        guide.reviewActiveBackup(); await guide.startActiveBackup(ready: true); guide.confirmActiveNormalBoot()
        guide.reviewFreshDataBackup(); await guide.startFreshDataBackup(ready: false)
        #expect(await calls.ids.count == 1)
        await guide.startFreshDataBackup(ready: true)
        #expect(guide.phase == .freshDataPowerOff && !guide.canPreparePlan)
        guide.confirmFreshDataPowerOff()
        if fail {
            #expect(guide.phase == .freshDataReturnToNormal && guide.freshDataDiagnosticDirectory == latest && !guide.canPreparePlan)
            guide.retryFreshDataBackup(); #expect(guide.phase == .freshDataReturnToNormal)
            if scenario == "save-fails-normal" {
                guide.reportNormalBootProblem()
                #expect(guide.phase == .normalBootNeedsHelp && guide.freshDataDiagnosticDirectory == latest && guide.freshDataError != nil)
            } else {
                guide.confirmFreshDataNormalBoot(); #expect(guide.phase == .freshDataFailed)
                guide.retryFreshDataBackup(); #expect(guide.phase == .freshDataInstructions)
            }
        } else {
            #expect(guide.phase == .freshDataComplete && guide.freshDataDirectory == latest && guide.canPreparePlan)
            guide.reviewFreshDataBackup(); #expect(guide.phase == .freshDataInstructions)
            if scenario.hasPrefix("refresh-fails") {
                await guide.startFreshDataBackup(ready: true); guide.confirmFreshDataPowerOff()
                if scenario == "refresh-fails-normal" {
                    guide.reportNormalBootProblem()
                    #expect(guide.phase == .normalBootNeedsHelp && guide.freshDataDirectory == latest && !guide.canPreparePlan)
                    return
                }
                guide.confirmFreshDataNormalBoot()
                #expect(guide.phase == .freshDataFailed && guide.freshDataDirectory == latest)
                guide.retryFreshDataBackup()
            }
            guide.cancelFreshDataBackup(); #expect(guide.phase == .freshDataComplete && guide.freshDataDirectory == latest)
            await guide.preparePlan(); #expect(guide.phase == .planComplete)
            #expect(await calls.ids == (scenario == "refresh-fails" ? [1, 1, 1, 2] : [1, 1, 2]))
        }
    }
    @Test(arguments: [true, false]) func postSaveFailureKeepsVerifiedBackupVisibleWithoutContinuing(_ verified: Bool) async {
        let url = URL(fileURLWithPath: "/tmp/evidence")
        let guide = SNESBackupGuide(execute: { _ in setupReceipt(.backup, url) }, prepareRecovery: { _ in url }, prepareHelpers: { url },
            prepareStartup: { _,_,_,_ in setupReceipt(.startup, url) }, captureMenuSupport: { _,_,_,_,_ in setupReceipt(.menuSupport, url) },
            captureComponents: { _,_,_,_,_,_ in setupReceipt(.components, url) },
            captureData: { _,_,_,_,_,_ in throw SNESDataSnapshotPostSaveError(location: url, backupVerified: verified) })
        await guide.start(ready: true); guide.confirmNormalBoot(); guide.reviewStartupCheck(); await guide.startStartupCheck(ready: true)
        guide.confirmStartupNormalBoot(); guide.reviewMenuSupport(); await guide.startMenuSupport(ready: true)
        guide.confirmMenuSupportNormalBoot(); guide.reviewComponents(); await guide.startComponents(ready: true)
        guide.confirmComponentsNormalBoot(); guide.reviewDataBackup(); await guide.startDataBackup(ready: true)
        #expect(guide.phase == .dataReturnToNormal && guide.dataDirectory == nil)
        #expect(guide.dataDiagnosticDirectory == (verified ? url : nil))
        guide.confirmDataNormalBoot(); #expect(guide.phase == .dataFailed && !guide.canReviewRuntime)
    }
    @Test(arguments: ["success", "game-failure", "active-failure", "plan-failure"]) func temporaryTrialRequiresPreflightReadinessGameplayAndNormalBoot(_ scenario: String) async {
        let gameWorks = scenario != "game-failure"
        let url = URL(fileURLWithPath: "/tmp/evidence"), calls = ConnectionCallCounter()
        let data = SNESDataSnapshotReceipt(directory: url, manifestSHA256: String(repeating: "b", count: 64))
        let guide = SNESBackupGuide(execute: { _ in setupReceipt(.backup, url) }, prepareRecovery: { _ in url }, prepareHelpers: { url },
            prepareStartup: { _,_,_,_ in setupReceipt(.startup, url) }, captureMenuSupport: { _,_,_,_,_ in setupReceipt(.menuSupport, url) },
            captureComponents: { _,_,_,_,_,_ in setupReceipt(.components, url) }, captureData: { _,_,_,_,_,_ in data },
            captureRuntime: { _,_,_,_,_,_ in setupReceipt(.runtime, url) }, prepareCandidate: { _,_,_,_,_,_,_ in setupReceipt(.candidate, url) },
            preflight: { _,_ in SNESStartupPreflightReceipt(record: setupReceipt(.preflight, url), backupMatches: true) },
            startTrial: { candidate, preflight, _ in
                #expect(candidate.kind == .candidate && preflight.backupMatches); await calls.record(1)
                return setupReceipt(.trialStarted, url)
            }, checkTrial: { _,_,started,_ in
                #expect(started.kind == .trialStarted); await calls.record(2); return setupReceipt(.trialPlayed, url)
            }, captureActive: { backup,helpers,candidate,preflight,started,played,_ in
                #expect(backup.kind == .backup && helpers == url && candidate.kind == .candidate && preflight.backupMatches && started.kind == .trialStarted && played.kind == .trialPlayed)
                await calls.record(3)
                if scenario == "active-failure" {
                    if await calls.ids.count == 3 { throw SNESPreparationDiagnosticSavedError(directory: url) }
                    throw SNESRuntimeBinding.failure()
                }
                return setupReceipt(.activeBoot2, url)
            }, prepareFirmwarePlan: { backup,helpers,candidate,preflight,started,played,active,currentData in
                #expect(backup.kind == .backup && helpers == url && candidate.kind == .candidate && preflight.backupMatches && started.kind == .trialStarted && played.kind == .trialPlayed && active.kind == .activeBoot2)
                #expect(currentData.directory == data.directory && currentData.manifestSHA256 == data.manifestSHA256)
                await calls.record(4)
                if scenario == "plan-failure" { throw SNESRuntimeBinding.failure() }
                return SNESFirmwarePreparationReceipt(offlineReviewSHA256: String(repeating: "c", count: 64), changedUnits: 3)
            })
        await guide.start(ready: true); guide.confirmNormalBoot(); guide.reviewStartupCheck(); await guide.startStartupCheck(ready: true)
        guide.confirmStartupNormalBoot(); guide.reviewMenuSupport(); await guide.startMenuSupport(ready: true)
        guide.confirmMenuSupportNormalBoot(); guide.reviewComponents(); await guide.startComponents(ready: true)
        guide.confirmComponentsNormalBoot(); guide.reviewDataBackup(); await guide.startDataBackup(ready: true)
        guide.confirmDataNormalBoot(); guide.reviewRuntime(); await guide.startRuntime(ready: true); guide.confirmRuntimeNormalBoot()
        await guide.startCandidate(); guide.reviewPreflight(); await guide.startPreflight(ready: true)
        guide.reviewTrial(); #expect(guide.phase == .preflightReturnToNormal)
        guide.confirmPreflightNormalBoot(); guide.reviewTrial(); await guide.startTrial(ready: false)
        #expect(await calls.ids.isEmpty); await guide.startTrial(ready: true)
        #expect(guide.phase == .trialPlaying); #expect(await calls.ids == [1])
        await guide.checkTrial(gameWorks: gameWorks); #expect(guide.phase == .trialReturnToNormal)
        #expect(await calls.ids == (gameWorks ? [1, 2] : [1]))
        guide.confirmTrialNormalBoot(); #expect(guide.phase == (gameWorks ? .trialComplete : .trialFailed))
        guide.reviewActiveBackup()
        if gameWorks {
            #expect(guide.phase == .activeInstructions); await guide.startActiveBackup(ready: false); #expect(await calls.ids == [1, 2])
            await guide.startActiveBackup(ready: true); #expect(guide.phase == .activeReturnToNormal); #expect(await calls.ids == [1, 2, 3])
            guide.retryActiveBackup(); #expect(guide.phase == .activeReturnToNormal)
            guide.confirmActiveNormalBoot(); #expect(guide.phase == (scenario == "active-failure" ? .activeFailed : .activeComplete))
            if scenario == "success" {
                #expect(await calls.ids == [1, 2, 3]); await guide.preparePlan()
                #expect(guide.phase == .planComplete && guide.firmwarePlan?.changedUnits == 3); #expect(await calls.ids == [1, 2, 3, 4])
            }
            if scenario == "plan-failure" {
                await guide.preparePlan(); #expect(guide.phase == .planFailed)
                guide.retryPlan(); #expect(guide.phase == .activeComplete)
            }
            if scenario == "active-failure" {
                #expect(guide.activeDiagnosticDirectory == url)
                guide.retryActiveBackup(); #expect(guide.phase == .trialComplete && guide.activeError == nil)
                guide.reviewActiveBackup(); await guide.startActiveBackup(ready: true)
                #expect(guide.phase == .activeReturnToNormal && guide.activeDiagnosticDirectory == url)
            }
        } else { #expect(guide.phase == .trialFailed) }
    }
    @Test(arguments: [true, false]) func preflightRequiresReadinessAndNormalBoot(_ backupMatches: Bool) async {
        let url = URL(fileURLWithPath: "/tmp/evidence"), calls = ConnectionCallCounter(), backups = ConnectionCallCounter()
        let data = SNESDataSnapshotReceipt(directory: url, manifestSHA256: String(repeating: "b", count: 64))
        let replacement = SNESDataSnapshotReceipt(directory: url.appendingPathComponent("replacement"), manifestSHA256: String(repeating: "c", count: 64))
        let guide = SNESBackupGuide(execute: { _ in setupReceipt(.backup, url) }, prepareRecovery: { _ in url }, prepareHelpers: { url },
            prepareStartup: { _,_,_,_ in setupReceipt(.startup, url) }, captureMenuSupport: { _,_,_,_,_ in setupReceipt(.menuSupport, url) },
            captureComponents: { _,_,_,_,_,_ in setupReceipt(.components, url) }, captureData: { _,_,_,_,_,_ in
                await backups.record(1); return await backups.ids.count == 1 ? data : replacement
            },
            captureRuntime: { _,_,_,_,selected,_ in
                let count = await backups.ids.count
                let expected = count == 1 ? data : replacement
                #expect(selected.directory == expected.directory && selected.manifestSHA256 == expected.manifestSHA256)
                return setupReceipt(.runtime, url)
            }, prepareCandidate: { _,_,_,_,selected,_,_ in
                let count = await backups.ids.count
                let expected = count == 1 ? data : replacement
                #expect(selected.directory == expected.directory && selected.manifestSHA256 == expected.manifestSHA256)
                return setupReceipt(.candidate, url)
            },
            preflight: { candidate, _ in
                #expect(candidate.kind == .candidate); await calls.record(1)
                let count = await calls.ids.count
                return SNESStartupPreflightReceipt(record: setupReceipt(.preflight, url), backupMatches: backupMatches || count > 1)
            })
        await guide.start(ready: true); guide.confirmNormalBoot(); guide.reviewStartupCheck(); await guide.startStartupCheck(ready: true)
        guide.confirmStartupNormalBoot(); guide.reviewMenuSupport(); await guide.startMenuSupport(ready: true)
        guide.confirmMenuSupportNormalBoot(); guide.reviewComponents(); await guide.startComponents(ready: true)
        guide.confirmComponentsNormalBoot(); guide.reviewDataBackup(); await guide.startDataBackup(ready: true)
        guide.confirmDataNormalBoot(); guide.reviewRuntime(); await guide.startRuntime(ready: true); guide.confirmRuntimeNormalBoot()
        await guide.startCandidate(); await guide.startPreflight(ready: true); #expect(await calls.ids.isEmpty)
        guide.reviewPreflight(); await guide.startPreflight(ready: false); #expect(await calls.ids.isEmpty)
        await guide.startPreflight(ready: true)
        #expect(guide.phase == .preflightReturnToNormal && guide.preflightBackupMatches == backupMatches)
        await guide.startPreflight(ready: true); #expect(await calls.ids.count == 1)
        guide.confirmPreflightNormalBoot()
        #expect(guide.phase == (backupMatches ? .preflightComplete : .preflightBackupChanged))
        if !backupMatches {
            guide.reviewTrial(); #expect(guide.phase == .preflightBackupChanged)
            guide.reviewDataBackup()
            #expect(guide.phase == .dataInstructions)
            #expect(guide.preflightDirectory == nil && guide.candidateDirectory == nil && guide.runtimeDirectory == nil)
            await guide.startDataBackup(ready: false)
            #expect(guide.phase == .dataInstructions)
            await guide.startDataBackup(ready: true); guide.confirmDataNormalBoot()
            #expect(guide.phase == .dataComplete && guide.canReviewRuntime)
            #expect(guide.dataDirectory == replacement.directory)
            guide.reviewTrial(); #expect(guide.phase == .dataComplete)
            guide.reviewRuntime(); await guide.startRuntime(ready: true); guide.confirmRuntimeNormalBoot()
            await guide.startCandidate(); guide.reviewPreflight(); await guide.startPreflight(ready: true)
            guide.confirmPreflightNormalBoot()
            let count = await calls.ids.count
            #expect(guide.phase == .preflightComplete && count == 2)
        }
    }
    @Test func failedPreflightRequiresNormalBootAndDoesNotRetry() async {
        let url = URL(fileURLWithPath: "/tmp/evidence"), calls = ConnectionCallCounter()
        let data = SNESDataSnapshotReceipt(directory: url, manifestSHA256: String(repeating: "b", count: 64))
        let guide = SNESBackupGuide(execute: { _ in setupReceipt(.backup, url) }, prepareRecovery: { _ in url }, prepareHelpers: { url },
            prepareStartup: { _,_,_,_ in setupReceipt(.startup, url) }, captureMenuSupport: { _,_,_,_,_ in setupReceipt(.menuSupport, url) },
            captureComponents: { _,_,_,_,_,_ in setupReceipt(.components, url) }, captureData: { _,_,_,_,_,_ in data },
            captureRuntime: { _,_,_,_,_,_ in setupReceipt(.runtime, url) }, prepareCandidate: { _,_,_,_,_,_,_ in setupReceipt(.candidate, url) },
            preflight: { _, _ in await calls.record(1); throw SNESRuntimeBinding.failure() })
        await guide.start(ready: true); guide.confirmNormalBoot(); guide.reviewStartupCheck(); await guide.startStartupCheck(ready: true)
        guide.confirmStartupNormalBoot(); guide.reviewMenuSupport(); await guide.startMenuSupport(ready: true)
        guide.confirmMenuSupportNormalBoot(); guide.reviewComponents(); await guide.startComponents(ready: true)
        guide.confirmComponentsNormalBoot(); guide.reviewDataBackup(); await guide.startDataBackup(ready: true)
        guide.confirmDataNormalBoot(); guide.reviewRuntime(); await guide.startRuntime(ready: true); guide.confirmRuntimeNormalBoot()
        await guide.startCandidate(); guide.reviewPreflight(); await guide.startPreflight(ready: true)
        #expect(guide.phase == .preflightReturnToNormal && guide.preflightError != nil)
        await guide.startPreflight(ready: true); #expect(await calls.ids.count == 1)
        guide.retryPreflight(); #expect(guide.phase == .preflightReturnToNormal)
        guide.confirmPreflightNormalBoot(); #expect(guide.phase == .preflightFailed)
        guide.retryPreflight(); #expect(guide.phase == .candidateComplete && guide.preflightError == nil)
        guide.reviewPreflight(); await guide.startPreflight(ready: false); #expect(await calls.ids.count == 1)
    }
    @Test func candidatePreparationRequiresConfirmedRuntimeAndDoesNotStartAutomatically() async {
        let url = URL(fileURLWithPath: "/tmp/evidence"), calls = ConnectionCallCounter()
        let data = SNESDataSnapshotReceipt(directory: url, manifestSHA256: String(repeating: "b", count: 64))
        let guide = SNESBackupGuide(execute: { _ in setupReceipt(.backup, url) }, prepareRecovery: { _ in url }, prepareHelpers: { url },
            prepareStartup: { _,_,_,_ in setupReceipt(.startup, url) }, captureMenuSupport: { _,_,_,_,_ in setupReceipt(.menuSupport, url) },
            captureComponents: { _,_,_,_,_,_ in setupReceipt(.components, url) }, captureData: { _,_,_,_,_,_ in data },
            captureRuntime: { _,_,_,_,_,_ in setupReceipt(.runtime, url) },
            prepareCandidate: { backup,_,_,chain,saved,runtime,_ in
                #expect(backup.kind == .backup && chain.components.kind == .components && saved.manifestSHA256 == data.manifestSHA256 && runtime.kind == .runtime)
                await calls.record(1); return setupReceipt(.candidate, url)
            })
        await guide.start(ready: true); guide.confirmNormalBoot(); guide.reviewStartupCheck(); await guide.startStartupCheck(ready: true)
        guide.confirmStartupNormalBoot(); guide.reviewMenuSupport(); await guide.startMenuSupport(ready: true)
        guide.confirmMenuSupportNormalBoot(); guide.reviewComponents(); await guide.startComponents(ready: true)
        guide.confirmComponentsNormalBoot(); guide.reviewDataBackup(); await guide.startDataBackup(ready: true)
        guide.confirmDataNormalBoot(); guide.reviewRuntime(); await guide.startRuntime(ready: true)
        await guide.startCandidate(); #expect(await calls.ids.isEmpty && guide.phase == .runtimeReturnToNormal)
        guide.confirmRuntimeNormalBoot(); await guide.startCandidate()
        #expect(await calls.ids.count == 1 && guide.phase == .candidateComplete && guide.candidateDirectory == url)
    }
    @Test func candidateDownloadFailureCanBeRetriedWithoutRepeatingConsoleChecks() async {
        let url = URL(fileURLWithPath: "/tmp/evidence"), calls = ConnectionCallCounter()
        let data = SNESDataSnapshotReceipt(directory: url, manifestSHA256: String(repeating: "b", count: 64))
        let guide = SNESBackupGuide(execute: { _ in setupReceipt(.backup, url) }, prepareRecovery: { _ in url }, prepareHelpers: { url },
            prepareStartup: { _,_,_,_ in setupReceipt(.startup, url) }, captureMenuSupport: { _,_,_,_,_ in setupReceipt(.menuSupport, url) },
            captureComponents: { _,_,_,_,_,_ in setupReceipt(.components, url) }, captureData: { _,_,_,_,_,_ in data },
            captureRuntime: { _,_,_,_,_,_ in setupReceipt(.runtime, url) }, prepareCandidate: { _,_,_,_,_,_,_ in
                await calls.record(1)
                if await calls.ids.count == 1 { throw SNESRuntimeBinding.failure() }
                return setupReceipt(.candidate, url)
            })
        await guide.start(ready: true); guide.confirmNormalBoot(); guide.reviewStartupCheck(); await guide.startStartupCheck(ready: true)
        guide.confirmStartupNormalBoot(); guide.reviewMenuSupport(); await guide.startMenuSupport(ready: true)
        guide.confirmMenuSupportNormalBoot(); guide.reviewComponents(); await guide.startComponents(ready: true)
        guide.confirmComponentsNormalBoot(); guide.reviewDataBackup(); await guide.startDataBackup(ready: true)
        guide.confirmDataNormalBoot(); guide.reviewRuntime(); await guide.startRuntime(ready: true); guide.confirmRuntimeNormalBoot()
        await guide.startCandidate(); #expect(guide.phase == .candidateFailed && guide.candidateError != nil)
        guide.retryCandidate(); #expect(guide.phase == .runtimeComplete && guide.candidateError == nil)
        await guide.startCandidate(); #expect(guide.phase == .candidateComplete); #expect(await calls.ids.count == 2)
    }
    @Test func runtimeCaptureRequiresVerifiedDataAndExplicitReadiness() async {
        let url=URL(fileURLWithPath:"/tmp/evidence"), calls=ConnectionCallCounter()
        let guide=SNESBackupGuide(execute:{_ in setupReceipt(.backup, url)},prepareRecovery:{_ in url},prepareHelpers:{url},
            prepareStartup:{_,_,_,_ in setupReceipt(.startup, url)},captureMenuSupport:{_,_,_,_,_ in setupReceipt(.menuSupport, url)},captureComponents:{_,_,_,_,_,_ in setupReceipt(.components, url)},
            captureData:{_,_,_,_,_,_ in SNESDataSnapshotReceipt(directory: url, manifestSHA256: String(repeating: "a", count: 64))},captureRuntime:{b,r,h,_,d,_ in
                #expect(b.directory == url && r == url && h == url && d.directory == url && d.manifestSHA256 == String(repeating: "a", count: 64))
                await calls.record(1);return setupReceipt(.runtime, url)
            })
        await guide.start(ready:true);guide.confirmNormalBoot();guide.reviewStartupCheck();await guide.startStartupCheck(ready:true)
        guide.confirmStartupNormalBoot();guide.reviewMenuSupport();await guide.startMenuSupport(ready:true)
        guide.confirmMenuSupportNormalBoot();guide.reviewComponents();await guide.startComponents(ready:true)
        guide.confirmComponentsNormalBoot();guide.reviewDataBackup();await guide.startDataBackup(ready:true)
        guide.reviewRuntime();#expect(guide.phase == .dataReturnToNormal)
        guide.confirmDataNormalBoot();guide.reviewRuntime();#expect(guide.phase == .runtimeInstructions)
        await guide.startRuntime(ready:false);#expect(await calls.ids.isEmpty)
        await guide.startRuntime(ready:true);#expect(guide.phase == .runtimeReturnToNormal && guide.runtimeDirectory == url)
        guide.confirmRuntimeNormalBoot();#expect(guide.phase == .runtimeComplete)
    }
    @Test func dataBackupRequiresCompletedChecksAndExplicitReadiness() async {
        let root=URL(fileURLWithPath:"/tmp"),calls=ConnectionCallCounter()
        let backup=root.appendingPathComponent("backup"),recovery=root.appendingPathComponent("recovery")
        let helpers=root.appendingPathComponent("helpers"),startup=root.appendingPathComponent("startup")
        let support=root.appendingPathComponent("support"),components=root.appendingPathComponent("components")
        let data=root.appendingPathComponent("data")
        let guide=SNESBackupGuide(execute:{_ in setupReceipt(.backup, backup)},prepareRecovery:{_ in recovery},prepareHelpers:{helpers},
            prepareStartup:{_,_,_,_ in setupReceipt(.startup, startup)},captureMenuSupport:{_,_,_,_,_ in setupReceipt(.menuSupport, support)},captureComponents:{_,_,_,_,_,_ in setupReceipt(.components, components)},
            captureData:{b,r,h,_,_,detail in
                #expect(b.directory == backup && r == recovery && h == helpers)
                await calls.record(1); await detail("Copying part 1"); return SNESDataSnapshotReceipt(directory: data, manifestSHA256: String(repeating: "a", count: 64))
            })
        guide.reviewDataBackup(); #expect(guide.phase == .instructions)
        await guide.start(ready:true);guide.confirmNormalBoot();guide.reviewStartupCheck();await guide.startStartupCheck(ready:true)
        guide.confirmStartupNormalBoot();guide.reviewMenuSupport();await guide.startMenuSupport(ready:true)
        guide.confirmMenuSupportNormalBoot();guide.reviewComponents();await guide.startComponents(ready:true)
        guide.reviewDataBackup();#expect(guide.phase == .componentsReturnToNormal)
        guide.confirmComponentsNormalBoot();guide.reviewDataBackup();#expect(guide.phase == .dataInstructions)
        await guide.startDataBackup(ready:false);#expect(await calls.ids.isEmpty)
        await guide.startDataBackup(ready:true)
        #expect(guide.phase == .dataReturnToNormal && guide.dataDirectory == data)
        #expect(guide.dataDetail == "Copying part 1")
        guide.confirmDataNormalBoot();#expect(guide.phase == .dataComplete)
    }
    @Test func failedDataBackupRequiresNormalBootAndKeepsEarlierResults() async {
        let url=URL(fileURLWithPath:"/tmp/evidence")
        let guide=SNESBackupGuide(execute:{_ in setupReceipt(.backup, url)},prepareRecovery:{_ in url},prepareHelpers:{url},
            prepareStartup:{_,_,_,_ in setupReceipt(.startup, url)},captureMenuSupport:{_,_,_,_,_ in setupReceipt(.menuSupport, url)},captureComponents:{_,_,_,_,_,_ in setupReceipt(.components, url)},
            captureData:{_,_,_,_,_,_ in throw RecoveryProbeError.refused("Backup stopped")})
        await guide.start(ready:true);guide.confirmNormalBoot();guide.reviewStartupCheck();await guide.startStartupCheck(ready:true)
        guide.confirmStartupNormalBoot();guide.reviewMenuSupport();await guide.startMenuSupport(ready:true)
        guide.confirmMenuSupportNormalBoot();guide.reviewComponents();await guide.startComponents(ready:true)
        guide.confirmComponentsNormalBoot();guide.reviewDataBackup();await guide.startDataBackup(ready:true)
        #expect(guide.phase == .dataReturnToNormal && guide.dataDirectory == nil && guide.dataError == "Backup stopped")
        #expect(guide.backupDirectory == url && guide.componentsDirectory == url)
        guide.reportNormalBootProblem();#expect(guide.phase == .normalBootNeedsHelp)
    }
    @Test func failedDataBackupCanBeRetriedAfterNormalBoot() async {
        let url = URL(fileURLWithPath: "/tmp/evidence"), calls = ConnectionCallCounter()
        let guide = SNESBackupGuide(execute: { _ in setupReceipt(.backup, url) }, prepareRecovery: { _ in url }, prepareHelpers: { url },
            prepareStartup: { _,_,_,_ in setupReceipt(.startup, url) }, captureMenuSupport: { _,_,_,_,_ in setupReceipt(.menuSupport, url) },
            captureComponents: { _,_,_,_,_,_ in setupReceipt(.components, url) }, captureData: { _,_,_,_,_,_ in
                await calls.record(1)
                if await calls.ids.count == 1 { throw RecoveryProbeError.refused("Backup stopped") }
                return SNESDataSnapshotReceipt(directory: url, manifestSHA256: String(repeating: "b", count: 64))
            })
        await guide.start(ready: true); guide.confirmNormalBoot(); guide.reviewStartupCheck(); await guide.startStartupCheck(ready: true)
        guide.confirmStartupNormalBoot(); guide.reviewMenuSupport(); await guide.startMenuSupport(ready: true)
        guide.confirmMenuSupportNormalBoot(); guide.reviewComponents(); await guide.startComponents(ready: true)
        guide.confirmComponentsNormalBoot(); guide.reviewDataBackup(); await guide.startDataBackup(ready: true)
        guide.confirmDataNormalBoot(); #expect(guide.phase == .dataFailed)
        guide.reviewDataBackup(); #expect(guide.phase == .dataInstructions && guide.dataError == nil)
        await guide.startDataBackup(ready: false); #expect(await calls.ids.count == 1)
        await guide.startDataBackup(ready: true); guide.confirmDataNormalBoot()
        let count = await calls.ids.count
        #expect(guide.phase == .dataComplete && count == 2)
    }
    @Test func originalComponentsRequireConfirmedMenuCaptureAndExplicitReadiness() async {
        let root=URL(fileURLWithPath:"/tmp"),calls=ConnectionCallCounter()
        let backup=root.appendingPathComponent("backup"),recovery=root.appendingPathComponent("recovery")
        let helpers=root.appendingPathComponent("helpers"),startup=root.appendingPathComponent("startup")
        let support=root.appendingPathComponent("support"),components=root.appendingPathComponent("components")
        let guide=SNESBackupGuide(execute:{_ in setupReceipt(.backup, backup)},prepareRecovery:{_ in recovery},prepareHelpers:{helpers},
            prepareStartup:{_,_,_,_ in setupReceipt(.startup, startup)},captureMenuSupport:{_,_,_,_,_ in setupReceipt(.menuSupport, support)},
            captureComponents:{b,r,h,s,m,progress in
                #expect(b.directory==backup && r==recovery && h==helpers && s.directory==startup && m.directory==support)
                await calls.record(1);await progress(.verifying);return setupReceipt(.components, components)
            })
        await guide.start(ready:true);guide.confirmNormalBoot();guide.reviewStartupCheck();await guide.startStartupCheck(ready:true)
        guide.confirmStartupNormalBoot();guide.reviewMenuSupport();await guide.startMenuSupport(ready:true)
        guide.reviewComponents();#expect(guide.phase == .menuSupportReturnToNormal)
        guide.confirmMenuSupportNormalBoot();guide.reviewComponents();#expect(guide.phase == .componentsInstructions)
        await guide.startComponents(ready:false);#expect(await calls.ids.isEmpty)
        await guide.startComponents(ready:true)
        #expect(guide.phase == .componentsReturnToNormal && guide.componentsDirectory == components)
        await guide.startComponents(ready:true);#expect(await calls.ids.count == 1)
        guide.confirmComponentsNormalBoot();#expect(guide.phase == .componentsComplete)
    }
    @Test func failedComponentCaptureKeepsPriorEvidenceAndAllowsHonestFailure() async {
        let support=URL(fileURLWithPath:"/tmp/support")
        let guide=SNESBackupGuide(execute:{_ in setupReceipt(.backup, URL(fileURLWithPath:"/tmp/backup"))},
            prepareRecovery:{_ in URL(fileURLWithPath:"/tmp/recovery")},prepareHelpers:{URL(fileURLWithPath:"/tmp/helpers")},
            prepareStartup:{_,_,_,_ in setupReceipt(.startup, URL(fileURLWithPath:"/tmp/startup"))},captureMenuSupport:{_,_,_,_,_ in setupReceipt(.menuSupport, support)},
            captureComponents:{_,_,_,_,_,_ in throw RecoveryProbeError.refused("components failed")})
        await guide.start(ready:true);guide.confirmNormalBoot();guide.reviewStartupCheck();await guide.startStartupCheck(ready:true)
        guide.confirmStartupNormalBoot();guide.reviewMenuSupport();await guide.startMenuSupport(ready:true);guide.confirmMenuSupportNormalBoot()
        guide.reviewComponents();await guide.startComponents(ready:true)
        #expect(guide.phase == .componentsReturnToNormal && guide.componentsError == "components failed")
        #expect(guide.menuSupportDirectory == support)
        guide.reportNormalBootProblem();#expect(guide.phase == .normalBootNeedsHelp)
    }
    @Test func menuSupportRequiresConfirmedStartupAndExplicitReadiness() async {
        let backup=URL(fileURLWithPath:"/tmp/backup"),recovery=URL(fileURLWithPath:"/tmp/recovery")
        let helpers=URL(fileURLWithPath:"/tmp/helpers"),startup=URL(fileURLWithPath:"/tmp/startup")
        let support=URL(fileURLWithPath:"/tmp/support"),calls=ConnectionCallCounter()
        let guide=SNESBackupGuide(execute:{_ in setupReceipt(.backup, backup)},prepareRecovery:{_ in recovery},prepareHelpers:{helpers},
            prepareStartup:{_,_,_,_ in setupReceipt(.startup, startup)},captureMenuSupport:{b,r,h,s,progress in
                #expect(b.directory==backup && r==recovery && h==helpers && s.directory==startup)
                await calls.record(1);await progress(.verifying);return setupReceipt(.menuSupport, support)
            })
        guide.reviewMenuSupport();#expect(guide.phase == .instructions)
        await guide.start(ready:true);guide.confirmNormalBoot();guide.reviewStartupCheck();await guide.startStartupCheck(ready:true)
        guide.reviewMenuSupport();#expect(guide.phase == .startupReturnToNormal)
        guide.confirmStartupNormalBoot();guide.reviewMenuSupport()
        #expect(guide.phase == .menuSupportInstructions)
        await guide.startMenuSupport(ready:false);#expect(await calls.ids.isEmpty)
        await guide.startMenuSupport(ready:true)
        #expect(guide.phase == .menuSupportReturnToNormal && guide.menuSupportDirectory == support)
        await guide.startMenuSupport(ready:true);#expect(await calls.ids.count == 1)
        guide.confirmMenuSupportNormalBoot();#expect(guide.phase == .menuSupportComplete)
    }

    @Test func menuSupportFailureRequiresNormalBootAndKeepsPreviousResults() async {
        let startup=URL(fileURLWithPath:"/tmp/startup")
        let guide=SNESBackupGuide(execute:{_ in setupReceipt(.backup, URL(fileURLWithPath:"/tmp/backup"))},
            prepareRecovery:{_ in URL(fileURLWithPath:"/tmp/recovery")},prepareHelpers:{URL(fileURLWithPath:"/tmp/helpers")},
            prepareStartup:{_,_,_,_ in setupReceipt(.startup, startup)},captureMenuSupport:{_,_,_,_,_ in throw RecoveryProbeError.refused("capture failed")})
        await guide.start(ready:true);guide.confirmNormalBoot();guide.reviewStartupCheck();await guide.startStartupCheck(ready:true)
        guide.confirmStartupNormalBoot();guide.reviewMenuSupport();await guide.startMenuSupport(ready:true)
        #expect(guide.phase == .menuSupportReturnToNormal && guide.menuSupportError == "capture failed")
        #expect(guide.startupDirectory == startup)
        guide.reportNormalBootProblem();#expect(guide.phase == .normalBootNeedsHelp)
    }
    @Test func nextStartupCheckRequiresCompletedBackupAndExplicitRecoveryReadiness() async {
        let backup=URL(fileURLWithPath:"/tmp/backup"),recovery=URL(fileURLWithPath:"/tmp/recovery")
        let helpers=URL(fileURLWithPath:"/tmp/helpers"),result=URL(fileURLWithPath:"/tmp/startup-check")
        let calls=ConnectionCallCounter()
        let guide=SNESBackupGuide(execute:{_ in setupReceipt(.backup, backup)},prepareRecovery:{_ in recovery},prepareHelpers:{helpers},
            prepareStartup:{b,r,h,progress in
                #expect(b.directory==backup && r==recovery && h==helpers)
                await calls.record(1);await progress(.verifying);return setupReceipt(.startup, result)
            })
        guide.reviewStartupCheck();#expect(guide.phase == .instructions)
        await guide.start(ready:true);guide.confirmNormalBoot();guide.reviewStartupCheck()
        #expect(guide.phase == .startupInstructions)
        await guide.startStartupCheck(ready:false);#expect(await calls.ids.isEmpty)
        await guide.startStartupCheck(ready:true)
        #expect(guide.phase == .startupReturnToNormal && guide.startupDirectory == result)
        await guide.startStartupCheck(ready:true);#expect(await calls.ids.count == 1)
        guide.confirmStartupNormalBoot();#expect(guide.phase == .startupComplete)
    }

    @Test func invalidStartupCheckFilesAreRejectedBeforeHostOrConsoleAccess() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let config=AppConfig();config.workspacePath=root.path;config.lastConsoleType = .snesUsa
        let manager=DeviceManager(),calls=ConnectionCallCounter()
        let app=AppState(startDeviceMonitoring:false,deviceManager:manager,
            gameManager:GameManagerService(config:config),config:config,saveConfiguration:{},
            checkRecoveryHost:{await calls.record(1)})
        app.isPreparingSync=true
        await #expect(throws:(any Error).self) {
            try await app.checkSNESStartup(backup:setupReceipt(.backup, root.appendingPathComponent("missing")),
                recovery:root.appendingPathComponent("recovery"),helpers:root.appendingPathComponent("helpers"),progress:{_ in})
        }
        #expect(await calls.ids.isEmpty && !manager.suppressAutoConnect)
    }
    @Test func invalidCandidateEvidenceIsRejectedBeforeDownloadingOrContactingConsole() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig(); config.workspacePath = root.path; config.lastConsoleType = .snesUsa
        let manager = DeviceManager(), calls = ConnectionCallCounter()
        let app = AppState(startDeviceMonitoring: false, deviceManager: manager,
            gameManager: GameManagerService(config: config), config: config, saveConfiguration: {},
            checkRecoveryHost: { await calls.record(1) })
        app.isPreparingSync = true
        let missing = root.appendingPathComponent("missing")
        let chain = SNESSetupRecordChain(startup: setupReceipt(.startup, missing), support: setupReceipt(.menuSupport, missing), components: setupReceipt(.components, missing))
        await #expect(throws: (any Error).self) {
            try await app.prepareSNESStartupCandidate(backup: setupReceipt(.backup, missing), recovery: missing, helpers: missing,
                chain: chain, data: SNESDataSnapshotReceipt(directory: missing, manifestSHA256: String(repeating: "a", count: 64)),
                runtime: setupReceipt(.runtime, missing), progress: { _ in }, loadTools: {
                    await calls.record(2); throw SNESRuntimeBinding.failure()
                })
        }
        #expect(await calls.ids.isEmpty && !manager.suppressAutoConnect)
    }
    @Test func invalidMenuCheckFilesNeverOpenConsole() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let config=AppConfig();config.workspacePath=root.path;config.lastConsoleType = .snesUsa
        let manager=DeviceManager(),calls=ConnectionCallCounter()
        let app=AppState(startDeviceMonitoring:false,deviceManager:manager,
            gameManager:GameManagerService(config:config),config:config,saveConfiguration:{},
            checkRecoveryHost:{await calls.record(1)})
        app.isPreparingSync=true
        await #expect(throws:(any Error).self) {
            try await app.captureSNESMenuSupport(backup:setupReceipt(.backup, root.appendingPathComponent("missing")),
                recovery:root.appendingPathComponent("recovery"),helpers:root.appendingPathComponent("helpers"),
                startup:setupReceipt(.startup, root.appendingPathComponent("startup")),progress:{_ in})
        }
        #expect(await calls.ids.isEmpty && !manager.suppressAutoConnect)
    }
    @Test func invalidSystemCheckFilesNeverOpenConsole() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let config=AppConfig();config.workspacePath=root.path;config.lastConsoleType = .snesUsa
        let manager=DeviceManager(),calls=ConnectionCallCounter()
        let app=AppState(startDeviceMonitoring:false,deviceManager:manager,
            gameManager:GameManagerService(config:config),config:config,saveConfiguration:{},checkRecoveryHost:{await calls.record(1)})
        app.isPreparingSync=true
        await #expect(throws:(any Error).self) {
            try await app.captureSNESOriginalComponents(backup:setupReceipt(.backup, root.appendingPathComponent("missing")),
                recovery:root.appendingPathComponent("recovery"),helpers:root.appendingPathComponent("helpers"),
                startup:setupReceipt(.startup, root.appendingPathComponent("startup")),support:setupReceipt(.menuSupport, root.appendingPathComponent("support")),progress:{_ in})
        }
        #expect(await calls.ids.isEmpty && !manager.suppressAutoConnect)
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_SETUP"] != nil),arguments:["none","truncated","task-cancel"])
    func appSystemCheckSavesVerifiedFilesOrDiagnosticAndClosesSession(fault:String) async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let source=try #require(try await originalComponentSourceFixture(root:root))
        let backup=source.material.setup.directoryURL, startup=source.material.source.directoryURL, support=source.material.directoryURL
        let config=AppConfig();config.workspacePath=root.path;config.lastConsoleType = .snesUsa
        let backups=config.workspace.backups
        try FileManager.default.createDirectory(at:backups,withIntermediateDirectories:true)
        let store=try RecoveryBootSnapshotStore(root:backups)
        let recovery=try await store.saveSNESRecoveryMaterial(SNESRecoveryMaterial.load(setup:backup))
        let helpers=try await store.saveSNESPortableHelpers()
        let io=OriginalComponentFakeIO(source:source,fault:fault),manager=DeviceManager()
        let app=AppState(startDeviceMonitoring:false,deviceManager:manager,
            gameManager:GameManagerService(config:config),config:config,saveConfiguration:{},
            checkRecoveryHost:{},makeSNESOriginalComponentIO:{_ in io})
        app.isPreparingSync=true
        if fault == "none" {
            await #expect(throws: (any Error).self) {
                try await app.captureSNESOriginalComponents(backup:setupReceipt(.backup, backup, hash: source.material.setup.manifestSHA256),recovery:recovery,helpers:helpers,
                    startup:setupReceipt(.startup, startup, hash: source.material.source.manifestSHA256),
                    support:setupReceipt(.menuSupport, support, hash: String(repeating:"0",count:64)),progress:{_ in})
            }
            #expect(await io.base.events.isEmpty && !manager.suppressAutoConnect)
        }
        let completion=StartupTestCompletion()
        let operation=Task {
            do {
                let directory=try await app.captureSNESOriginalComponents(backup:setupReceipt(.backup, backup, hash: source.material.setup.manifestSHA256),recovery:recovery,helpers:helpers,
                    startup:setupReceipt(.startup, startup, hash: source.material.source.manifestSHA256),support:setupReceipt(.menuSupport, support, hash: source.material.manifestSHA256),progress:{_ in})
                await completion.markFinished();return directory
            } catch { await completion.markFinished();throw error }
        }
        if fault == "task-cancel" {
            for _ in 0..<9000 {
                let started=await io.reads>0,finished=await completion.finished
                if started || finished { break }
                try await Task.sleep(for:.milliseconds(10))
            }
            let started=await io.reads>0
            #expect(started);operation.cancel()
            if !started { _=try? await operation.value; return }
        }
        do {
            let directory=try await operation.value
            #expect(fault == "none")
            _=try SNESOriginalComponentMaterial.load(source:source,directory:directory.directory)
        } catch {
            #expect(fault != "none")
            if fault == "truncated" { #expect(error is SNESPreparationDiagnosticSavedError) }
            if fault == "task-cancel" { #expect(error is CancellationError) }
        }
        #expect(await io.base.events.filter{$0 == "disconnect"}.count == 1)
        #expect(manager.suppressAutoConnect)
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_SETUP"] != nil),arguments:["none","truncated","task-cancel"])
    func appMenuCheckSavesVerifiedFilesOrDiagnosticAndClosesSession(fault:String) async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let source=try #require(try await menuSupportSourceFixture(root:root))
        let backup=source.preparation.source.source.directoryURL
        let config=AppConfig();config.workspacePath=root.path;config.lastConsoleType = .snesUsa
        let backups=config.workspace.backups
        try FileManager.default.createDirectory(at:backups,withIntermediateDirectories:true)
        let store=try RecoveryBootSnapshotStore(root:backups)
        let recovery=try await store.saveSNESRecoveryMaterial(SNESRecoveryMaterial.load(setup:backup))
        let helpers=try await store.saveSNESPortableHelpers()
        let io=MenuSupportFakeIO(source:source,fault:fault),manager=DeviceManager()
        let app=AppState(startDeviceMonitoring:false,deviceManager:manager,
            gameManager:GameManagerService(config:config),config:config,saveConfiguration:{},
            checkRecoveryHost:{},makeSNESMenuSupportIO:{_ in io})
        app.isPreparingSync=true
        if fault == "none" {
            await #expect(throws: (any Error).self) {
                try await app.captureSNESMenuSupport(backup:setupReceipt(.backup, backup, hash: source.preparation.source.source.manifestSHA256),recovery:recovery,helpers:helpers,
                    startup:setupReceipt(.startup, source.directoryURL, hash: String(repeating:"0",count:64)),progress:{_ in})
            }
            #expect(await io.base.events.isEmpty && !manager.suppressAutoConnect)
        }
        let completion=StartupTestCompletion()
        let operation=Task {
            do {
                let directory=try await app.captureSNESMenuSupport(backup:setupReceipt(.backup, backup, hash: source.preparation.source.source.manifestSHA256),recovery:recovery,helpers:helpers,
                    startup:setupReceipt(.startup, source.directoryURL, hash: source.manifestSHA256),progress:{_ in})
                await completion.markFinished();return directory
            } catch { await completion.markFinished();throw error }
        }
        if fault == "task-cancel" {
            for _ in 0..<9000 {
                let started=await io.captures>0,finished=await completion.finished
                if started || finished { break }
                try await Task.sleep(for:.milliseconds(10))
            }
            let started=await io.captures>0
            #expect(started)
            operation.cancel()
            if !started { _=try? await operation.value; return }
        }
        do {
            let directory=try await operation.value
            #expect(fault == "none")
            _=try SNESMenuSupportMaterial.load(source:source,directory:directory.directory)
        } catch {
            #expect(fault != "none")
            if fault == "truncated" { #expect(error is SNESPreparationDiagnosticSavedError) }
            if fault == "task-cancel" { #expect(error is CancellationError) }
        }
        #expect(await io.base.events.filter{$0 == "disconnect"}.count == 1)
        #expect(manager.suppressAutoConnect)
    }

    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_SETUP"] != nil),arguments:["none","startup","cancel","task-cancel"])
    func appStartupCheckUsesTheSavedConsoleAndAlwaysClosesTheTemporarySession(fault:String) async throws {
        let original=try #require(try snesPreparationFixture()),root=try testDirectory()
        defer{try? FileManager.default.removeItem(at:root)}
        let backup=root.appendingPathComponent(original.source.snapshotName)
        try FileManager.default.copyItem(at:original.source.directoryURL,to:backup)
        let source=try SNESPreparationSource.load(SNESOfflineSource.load(snapshot:backup))
        let config=AppConfig();config.workspacePath=root.path;config.lastConsoleType = .snesUsa
        let backups=config.workspace.backups
        try FileManager.default.createDirectory(at:backups,withIntermediateDirectories:true)
        let store=try RecoveryBootSnapshotStore(root:backups)
        let recovery=try await store.saveSNESRecoveryMaterial(SNESRecoveryMaterial.load(setup:backup))
        let helpers=try await store.saveSNESPortableHelpers()
        let io=SNESPreparationFakeIO(source:source,fault:fault),manager=DeviceManager()
        let app=AppState(startDeviceMonitoring:false,deviceManager:manager,
            gameManager:GameManagerService(config:config),config:config,saveConfiguration:{},
            checkRecoveryHost:{},makeSNESPreparationIO:{_ in io})
        app.isPreparingSync=true
        let completion=StartupTestCompletion()
        let operation=Task {
            do {
                let result=try await app.checkSNESStartup(backup:setupReceipt(.backup, backup, hash: source.source.manifestSHA256),recovery:recovery,helpers:helpers,progress:{_ in})
                await completion.markFinished();return result
            } catch { await completion.markFinished();throw error }
        }
        if fault == "task-cancel" {
            for _ in 0..<9000 {
                let started=await io.events.contains("startup"), finished=await completion.finished
                if started || finished { break }
                try await Task.sleep(for:.milliseconds(10))
            }
            let started=await io.events.contains("startup")
            #expect(started)
            operation.cancel()
            if !started { _ = try? await operation.value; return }
        }
        do {
            let directory=try await operation.value
            #expect(fault == "none")
            #expect(FileManager.default.fileExists(atPath:directory.directory.appendingPathComponent("manifest.json").path))
        } catch {
            #expect(fault != "none")
            if fault == "startup" { #expect(error is SNESPreparationDiagnosticSavedError) }
        }
        #expect(await io.events.filter{$0 == "disconnect"}.count == 1)
        #expect(manager.suppressAutoConnect)
    }

    @Test func failedRecoveryPackageBlocksNextStartupCheck() async {
        let guide=SNESBackupGuide(execute:{_ in setupReceipt(.backup, URL(fileURLWithPath:"/tmp/backup"))},
            prepareRecovery:{_ in throw RecoveryProbeError.refused("no recovery")},
            prepareHelpers:{URL(fileURLWithPath:"/tmp/helpers")},
            prepareStartup:{_,_,_,_ in Issue.record("Unexpected startup check");throw RecoveryProbeError.refused("unexpected")})
        await guide.start(ready:true);guide.confirmNormalBoot();guide.reviewStartupCheck()
        #expect(guide.phase == .complete)
    }

    @Test func startupFailureStillRequiresNormalBoot() async {
        let guide=SNESBackupGuide(execute:{_ in setupReceipt(.backup, URL(fileURLWithPath:"/tmp/backup"))},
            prepareRecovery:{_ in URL(fileURLWithPath:"/tmp/recovery")},prepareHelpers:{URL(fileURLWithPath:"/tmp/helpers")},
            prepareStartup:{_,_,_,_ in throw RecoveryProbeError.refused("startup stopped")})
        await guide.start(ready:true);guide.confirmNormalBoot();guide.reviewStartupCheck();await guide.startStartupCheck(ready:true)
        #expect(guide.phase == .startupReturnToNormal && guide.startupError == "startup stopped")
        guide.confirmStartupNormalBoot();#expect(guide.phase == .startupFailed)
    }

    @Test func savedReviewNormalBootFailureOpensHelpFromInstructions() {
        let guide = SNESBackupGuide(execute: { _ in setupReceipt(.backup, URL(fileURLWithPath: "/tmp/backup")) })
        #expect(guide.phase == .instructions)
        guide.reportNormalBootProblem()
        #expect(guide.phase == .normalBootNeedsHelp)
    }

    @Test func unsuccessfulNormalBootNeverClaimsConsoleIsWorking() async {
        let guide=SNESBackupGuide(execute:{_ in setupReceipt(.backup, URL(fileURLWithPath:"/tmp/backup"))})
        await guide.start(ready:true)
        guide.reportNormalBootProblem()
        #expect(guide.phase == .normalBootNeedsHelp && guide.backupDirectory != nil)
        guide.confirmNormalBoot()
        #expect(guide.phase == .normalBootNeedsHelp)
    }

    @Test func unsuccessfulNormalBootAfterStartupCheckKeepsTheRecord() async {
        let saved=URL(fileURLWithPath:"/tmp/check")
        let guide=SNESBackupGuide(execute:{_ in setupReceipt(.backup, URL(fileURLWithPath:"/tmp/backup"))},
            prepareRecovery:{_ in URL(fileURLWithPath:"/tmp/recovery")},prepareHelpers:{URL(fileURLWithPath:"/tmp/helpers")},
            prepareStartup:{_,_,_,_ in setupReceipt(.startup, saved)})
        await guide.start(ready:true);guide.confirmNormalBoot();guide.reviewStartupCheck();await guide.startStartupCheck(ready:true)
        guide.reportNormalBootProblem()
        #expect(guide.phase == .normalBootNeedsHelp && guide.startupDirectory == saved)
        guide.confirmStartupNormalBoot()
        #expect(guide.phase == .normalBootNeedsHelp)
    }
    @Test func appPreparesDurableCheckedHelpersInConfiguredBackupDirectory() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig(); config.workspacePath = root.path
        let backups = config.workspace.backups
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let app = AppState(startDeviceMonitoring: false, deviceManager: DeviceManager(),
                           gameManager: GameManagerService(config: config), config: config, saveConfiguration: {})
        let directory = try await app.prepareSNESSetupHelpers()
        #expect(directory.deletingLastPathComponent().resolvingSymlinksInPath() == backups.resolvingSymlinksInPath())
        let package = try SNESPortableHelperPackage.load(directory: directory)
        try package.revalidate()
        #expect(package.reader.digest == SNESPortableHelpers.Version.v1.reader.sha256)
        #expect(package.writer.digest == SNESPortableHelpers.Version.v1.writer.sha256)
    }
    @Test func preparesPortableHelpersAfterBackupWithoutAnotherConsoleOperation() async {
        let backup = URL(fileURLWithPath: "/tmp/snes-setup-backup")
        let helpers = URL(fileURLWithPath: "/tmp/snes-helper-package")
        let guide = SNESBackupGuide(execute: { _ in setupReceipt(.backup, backup) }, prepareHelpers: { helpers })
        await guide.start(ready: true)
        #expect(guide.backupDirectory == backup)
        #expect(guide.helpersDirectory == helpers && guide.helpersError == nil)
        #expect(guide.phase == .returnToNormal)
    }

    @Test func helperFailureLeavesTheSavedBackupAvailable() async {
        let backup = URL(fileURLWithPath: "/tmp/snes-setup-backup")
        let guide = SNESBackupGuide(execute: { _ in setupReceipt(.backup, backup) }, prepareHelpers: {
            throw RecoveryProbeError.refused("Helpers unavailable")
        })
        await guide.start(ready: true)
        #expect(guide.backupDirectory == backup && guide.helpersDirectory == nil)
        #expect(guide.helpersError == "Helpers unavailable")
        #expect(guide.errorMessage == nil && guide.phase == .returnToNormal)
    }

    @Test func failedBackupDoesNotPrepareHelpers() async {
        let calls = ConnectionCallCounter()
        let guide = SNESBackupGuide(execute: { _ in throw RecoveryProbeError.refused("Backup failed") }, prepareHelpers: {
            await calls.record(1)
            return URL(fileURLWithPath: "/tmp/unused")
        })
        await guide.start(ready: true)
        #expect(await calls.ids.isEmpty)
    }
    @Test func cancellingRecoveryPreparationCancelsItsBackgroundWorker() async {
        let probe = RecoveryCancellationProbe()
        let operation = Task { try await AppState.runSNESRecoveryWorker { try await probe.wait() } }
        while !(await probe.started) { await Task.yield() }
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(await probe.cancelled)
    }
    @Test func failedCheckKeepsDiagnosticSeparateFromCompletedBackup() async {
        let directory = URL(fileURLWithPath: "/private/tmp/SNES-Diagnostic")
        let guide = SNESBackupGuide { _ in throw SNESSetupDiagnosticSavedError(directory: directory) }
        await guide.start(ready: true)
        #expect(guide.phase == .returnToNormal)
        #expect(guide.backupDirectory == nil)
        #expect(guide.diagnosticDirectory == directory)
        guide.confirmNormalBoot()
        #expect(guide.phase == .failed)
    }

    @Test func anotherPreviewPreventsPreparationBeforeUSBOrBackupCreation() async throws {
        let config = AppConfig(); config.lastConsoleType = .snesUsa
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        config.workspacePath = root.path
        let manager = DeviceManager()
        let app = AppState(startDeviceMonitoring: false, deviceManager: manager,
            gameManager: GameManagerService(config: config), config: config, saveConfiguration: {},
            checkRecoveryHost: { throw RecoveryProbeError.refused("Another preview is open") })
        app.isPreparingSync = true
        await #expect(throws: RecoveryProbeError.self) { try await app.captureSNESKernel(progress: { _ in }) }
        #expect(!manager.suppressAutoConnect)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
    @Test func readinessAndNormalBootAreRequiredAndNoAutomaticRetryOccurs() async {
        let calls = ConnectionCallCounter()
        let guide = SNESBackupGuide { progress in
            await calls.record(1)
            await progress(.uploadingRecovery)
            return setupReceipt(.backup, URL(fileURLWithPath: "/tmp/SNES-US-Kernel-test"))
        }
        await guide.start(ready: false)
        #expect(await calls.ids.isEmpty)
        await guide.start(ready: true)
        #expect(guide.phase == .returnToNormal)
        #expect(guide.backupDirectory != nil)
        await guide.start(ready: true)
        #expect(await calls.ids.count == 1)
        guide.confirmNormalBoot()
        #expect(guide.phase == .complete)
    }
    @Test func failureAfterBootStillRequiresNormalBootAndPreservesError() async {
        let guide = SNESBackupGuide { progress in
            await progress(.uploadingRecovery)
            throw RecoveryProbeError.refused("Test failure")
        }
        await guide.start(ready: true)
        #expect(guide.phase == .returnToNormal && guide.errorMessage == "Test failure")
        #expect(guide.backupDirectory == nil)
        guide.confirmNormalBoot()
        #expect(guide.phase == .failed)
    }

    @Test func preparesRecoveryFilesFromTheSavedBackupWithoutMoreConsoleWork() async {
        let backup = URL(fileURLWithPath: "/tmp/snes-setup-backup")
        let package = URL(fileURLWithPath: "/tmp/snes-recovery-package")
        let guide = SNESBackupGuide(execute: { _ in setupReceipt(.backup, backup) }, prepareRecovery: { source in
            #expect(source.directory == backup)
            return package
        })
        await guide.start(ready: true)
        #expect(guide.backupDirectory == backup)
        #expect(guide.recoveryDirectory == package)
        #expect(guide.recoveryError == nil)
        #expect(guide.phase == .returnToNormal)
    }

    @Test func recoveryPreparationFailureKeepsTheOriginalBackupAvailable() async {
        let backup = URL(fileURLWithPath: "/tmp/snes-setup-backup")
        let guide = SNESBackupGuide(execute: { _ in setupReceipt(.backup, backup) }, prepareRecovery: { _ in
            throw RecoveryProbeError.refused("Recovery package unavailable")
        })
        await guide.start(ready: true)
        #expect(guide.backupDirectory == backup)
        #expect(guide.recoveryDirectory == nil)
        #expect(guide.recoveryError == "Recovery package unavailable")
        #expect(guide.errorMessage == nil)
        guide.confirmNormalBoot()
        #expect(guide.phase == .complete)
    }

    @Test func failedBackupDoesNotAttemptRecoveryPreparation() async {
        let calls = ConnectionCallCounter()
        let guide = SNESBackupGuide(execute: { _ in throw RecoveryProbeError.refused("Backup failed") }, prepareRecovery: { _ in
            await calls.record(1)
            return URL(fileURLWithPath: "/tmp/unused")
        })
        await guide.start(ready: true)
        #expect(await calls.ids.isEmpty)
        #expect(guide.backupDirectory == nil && guide.recoveryDirectory == nil)
    }
}
