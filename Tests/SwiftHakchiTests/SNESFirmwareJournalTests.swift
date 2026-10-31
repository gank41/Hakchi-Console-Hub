import Foundation
import Testing
import os
import Darwin
import SwiftHakchiCore
@testable import SwiftHakchi

@Suite(.serialized)
struct SNESFirmwareJournalTests {
    @Test func supportedUpgradeHistoryCanIncludeItsRestoreChildButCyclesAndUnboundedHistoryRefuse() throws {
        // Eight supported sequential installations (recipes 3...10), then their restore.
        var visited=Set<UUID>()
        for _ in 0..<9 {
            let id=UUID()
            try SNESFirmwareJournal.requireRebuildAncestry(id:id,visited:visited)
            visited.insert(id)
        }
        #expect(throws:(any Error).self) {try SNESFirmwareJournal.requireRebuildAncestry(id:visited.first!,visited:visited)}
        // Discovery itself admits at most 64 journal directories. Reconstruction uses the same bound.
        while visited.count<64 {visited.insert(UUID())}
        #expect(throws:(any Error).self) {try SNESFirmwareJournal.requireRebuildAncestry(id:UUID(),visited:visited)}
    }

    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_XZ_CANDIDATE"] != nil))
    func historicalXZInstallAndRestoreChildReopenWithoutBootingUnsupportedBytes() async throws {
        let env=ProcessInfo.processInfo.environment,m=try await SNESFirmwareFixtureCache.shared.value(),root=try testDirectory()
        defer {try? FileManager.default.removeItem(at:root)}
        let candidate=try #require(env["SWIFTHAKCHI_SNES_XZ_CANDIDATE"]),preflight=try #require(env["SWIFTHAKCHI_SNES_XZ_PREFLIGHT"])
        let c=try SNESStartupAdapterCandidate.load(directory:URL(fileURLWithPath:candidate))
        // Synthetic historical lineage only: copied runtime reports are compatible because
        // v1/v2 have identical runtime bytes. These temporary manifests never attest hardware.
        var reports:[String]=[]
        for old in [m.paths.started,m.paths.played] {
            let folder=root.appendingPathComponent("SNES-Startup-Trial-Result-"+UUID().uuidString)
            try FileManager.default.copyItem(at:URL(fileURLWithPath:old),to:folder)
            let manifest=folder.appendingPathComponent("manifest.json")
            var object=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as? [String:Any])
            object["imageSHA256"]=BackupManifest.digest(c.image)
            object["preflightSHA256"]=BackupManifest.digest(try Data(contentsOf:URL(fileURLWithPath:preflight).appendingPathComponent("manifest.json")))
            try JSONSerialization.data(withJSONObject:object).write(to:manifest)
            reports.append(folder.path)
        }
        let pins=try PinnedFELInputs.load(),recovery=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage)
        let paths=SNESFirmwarePaths(candidate:candidate,preflight:preflight,started:reports[0],played:reports[1],original:m.paths.original,reader:m.paths.reader,writer:m.paths.writer)
        let historical=try SNESFirmwareMaterial.install(paths:paths,recovery:recovery),guardValue=try SNESFirmwareGuard.prepare(historical)
        let journals=root.appendingPathComponent("journals");try FileManager.default.createDirectory(at:journals,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let p=try SNESFirmwareJournal.prepare(material:historical,root:journals,guard:guardValue)
        let initial=try SNESFirmwareJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:historical,guard:guardValue)
        try await initial.preflightVerified();_=try await initial.beginWrite();try await initial.readbackVerified();try await initial.close()
        let parent=try await SNESFirmwareJournal.reopen(operation:p.operation,reviewSHA256:p.reviewSHA256,recovery:recovery)
        #expect(try await parent.phase() == .readbackVerified)
        let restore=try SNESFirmwareMaterial.restore(installed:await parent.restorableInstall())
        try await parent.close()
        let prepared=try SNESFirmwareJournal.prepare(material:restore,root:journals)
        let child=try await SNESFirmwareJournal.reopen(operation:prepared.operation,reviewSHA256:prepared.reviewSHA256,recovery:recovery)
        let loaded=try await child.verifiedMaterial(),seal=try SNESFirmwareGuard.prepare(loaded)
        #expect(loaded.direction == .restore && loaded.target==m.original.active)
        let base=SNESFirmwareFakeIO(material:loaded,fault:"none"),shell=SNESFirmwareShellFake(material:loaded,fault:"none")
        _=try NativeSNESFirmwareIO(material:loaded,guard:seal,base:base,shell:shell)
        #expect(await base.base.events.isEmpty)
        #expect(throws:(any Error).self) {_=try NativeSNESFirmwareIO(material:historical,guard:guardValue,base:base,shell:shell)}
        try await child.close()
    }

    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
    func failedStartupCanRestoreWithoutFalseAcceptanceAndOnlyAcceptedRestoreUnblocksUpdates() async throws {
        let m=try await SNESFirmwareFixtureCache.shared.value(),g=try await SNESFirmwareGuardFixtureCache.shared.value(),root=try testDirectory()
        defer{try? FileManager.default.removeItem(at:root)}
        let p=try SNESFirmwareJournal.prepare(material:m,root:root,guard:g),parent=try SNESFirmwareJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,guard:g)
        try await parent.preflightVerified();_=try await parent.beginWrite();try await parent.readbackVerified()
        await #expect(throws:(any Error).self){try await parent.acceptedInstall()}
        let installed=try await parent.restorableInstall(),restore=try SNESFirmwareMaterial.restore(installed:installed),seal=try SNESFirmwareGuard.prepare(restore)
        #expect(try await parent.phase() == .readbackVerified);try await parent.close()
        let child=try SNESFirmwareJournal.prepare(material:restore,root:root,guard:seal)
        let pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage)
        let j=try await SNESFirmwareJournal.reopen(operation:child.operation,reviewSHA256:child.reviewSHA256,recovery:inputs)
        try await j.preflightVerified();_=try await j.beginWrite();try await j.close()
        #expect(throws:SNESFirmwareJournalError.unresolved){try SNESFirmwareJournal.prepare(material:restore,root:root,guard:seal)}
        let readback=try await SNESFirmwareJournal.reopen(operation:child.operation,reviewSHA256:child.reviewSHA256,recovery:inputs)
        try await readback.readbackVerified();try await readback.close()
        let next=try SNESFirmwareMaterial.install(paths:m.paths,recovery:inputs),nextSeal=try SNESFirmwareGuard.prepare(next)
        #expect(throws:SNESFirmwareJournalError.unresolved){try SNESFirmwareJournal.prepare(material:next,root:root,guard:nextSeal)}
        let accepted=try await SNESFirmwareJournal.reopen(operation:child.operation,reviewSHA256:child.reviewSHA256,recovery:inputs)
        try await accepted.acceptMenu();try await accepted.close()
        _=try SNESFirmwareJournal.prepare(material:next,root:root,guard:nextSeal)
        let old=try SNESFirmwareJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,guard:g)
        #expect(try await old.phase() == .readbackVerified)
        await #expect(throws:(any Error).self){try await old.acceptedInstall()}
        try await old.close()
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
    func reconstructsSavedMaterialAndRefusesEditedPlanBeforeUse() async throws {
        let m=try await SNESFirmwareFixtureCache.shared.value(),g=try await SNESFirmwareGuardFixtureCache.shared.value()
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let prepared=try SNESFirmwareJournal.prepare(material:m,root:root,guard:g)
        let pins=try PinnedFELInputs.load(),recovery=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage)
        let reopened=try await SNESFirmwareJournal.reopen(operation:prepared.operation,reviewSHA256:prepared.reviewSHA256,recovery:recovery)
        #expect(try await reopened.phase() == .prepared)
        let loaded=try await reopened.verifiedMaterial(guard:g)
        #expect(loaded.target==m.target && loaded.id==m.id)
        try await reopened.close()
        var raw=try Data(contentsOf:prepared.operation.appendingPathComponent("plan.json"));raw.append(32)
        try raw.write(to:prepared.operation.appendingPathComponent("plan.json"))
        await #expect(throws:(any Error).self){try await SNESFirmwareJournal.reopen(operation:prepared.operation,reviewSHA256:prepared.reviewSHA256,recovery:recovery)}
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
    func intentIssuesOnlyOnePermitAndUnresolvedOperationSurvivesReopen() async throws {
        let m=try await SNESFirmwareFixtureCache.shared.value(),root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let p=try SNESFirmwareJournal.prepare(material:m,root:root),j=try SNESFirmwareJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m)
        #expect(try await j.phase() == .prepared)
        await #expect(throws:(any Error).self){try await j.beginWrite()}
        try await j.preflightVerified();let permit=try await j.beginWrite()
        #expect(permit.id==m.id && permit.reviewSHA256==p.reviewSHA256)
        await #expect(throws:(any Error).self){try await j.beginWrite()}
        try await j.close()
        let reopened=try SNESFirmwareJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m)
        #expect(try await reopened.phase() == .writeIntent)
        await #expect(throws:(any Error).self){try await reopened.beginWrite()}
        try await reopened.uncertain();try await reopened.close()
        #expect(throws:SNESFirmwareJournalError.unresolved){try SNESFirmwareJournal.prepare(material:m,root:root)}
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
    func acceptanceRequiresReadbackStartupAndHumanAction() async throws {
        let m=try await SNESFirmwareFixtureCache.shared.value(),root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let p=try SNESFirmwareJournal.prepare(material:m,root:root),j=try SNESFirmwareJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m)
        await #expect(throws:(any Error).self){try await j.acceptMenu()}
        try await j.preflightVerified();_=try await j.beginWrite();try await j.readbackVerified()
        await #expect(throws:(any Error).self){try await j.acceptedInstall()}
        await #expect(throws:(any Error).self){try await j.acceptMenu()}
        try await j.startupVerified();try await j.acceptMenu();let accepted=try await j.acceptedInstall()
        #expect(accepted.reviewSHA256==p.reviewSHA256 && accepted.material.target==m.target)
        let restore=try SNESFirmwareMaterial.restore(accepted:accepted)
        #expect(restore.direction == .restore && restore.preimage==m.target && restore.target==m.original.active)
        #expect(restore.parentReviewSHA256==p.reviewSHA256)
        try await j.close()
        let wrong=try testDirectory();defer{try? FileManager.default.removeItem(at:wrong)}
        #expect(throws:(any Error).self){try SNESFirmwareJournal.prepare(material:restore,root:wrong)}
        let preparedRestore=try SNESFirmwareJournal.prepare(material:restore,root:root)
        let restored=try SNESFirmwareJournal(operation:preparedRestore.operation,reviewSHA256:preparedRestore.reviewSHA256,material:restore)
        try await restored.preflightVerified();_=try await restored.beginWrite();try await restored.readbackVerified();try await restored.acceptMenu()
        await #expect(throws:(any Error).self){try await restored.acceptedInstall()}
        try await restored.close()
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil),arguments:["input","record","extra","link"])
    func refusesEditedOrLinkedJournal(_ fault:String) async throws {
        let m=try await SNESFirmwareFixtureCache.shared.value(),root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let p=try SNESFirmwareJournal.prepare(material:m,root:root)
        switch fault {
        case "input":try Data([1]).write(to:p.operation.appendingPathComponent("input.bin"))
        case "record":let f=p.operation.appendingPathComponent("0000.json");var data=try Data(contentsOf:f);data.append(1);try data.write(to:f)
        case "extra":try Data([1]).write(to:p.operation.appendingPathComponent("0009.json"))
        default:
            let elsewhere=try testDirectory();defer{try? FileManager.default.removeItem(at:elsewhere)}
            let f=p.operation.appendingPathComponent("input.bin");try FileManager.default.linkItem(at:f,to:elsewhere.appendingPathComponent("linked"))
            #expect(throws:(any Error).self){try SNESFirmwareJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m)}
            return
        }
        #expect(throws:(any Error).self){try SNESFirmwareJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m)}
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
    func failedDurableIntentNeverIssuesPermitAndCompetingLeaseRefuses() async throws {
        let m=try await SNESFirmwareFixtureCache.shared.value(),root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let p=try SNESFirmwareJournal.prepare(material:m,root:root),fail=OSAllocatedUnfairLock(initialState:false)
        let j=try SNESFirmwareJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,synchronize:{fd in fail.withLock{$0} ? -1:Darwin.fsync(fd)})
        #expect(throws:(any Error).self){try SNESFirmwareJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m)}
        try await j.preflightVerified();fail.withLock{$0=true}
        await #expect(throws:(any Error).self){try await j.beginWrite()}
        fail.withLock{$0=false};try await j.close()
        let reopened=try SNESFirmwareJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m)
        await #expect(throws:(any Error).self){try await reopened.beginWrite()}
        try await reopened.close()
    }

}
