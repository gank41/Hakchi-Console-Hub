import Foundation
import Testing
import os
import Darwin
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryRollbackJournalTests {
    @Test(arguments:["saved","lost-response"])
    func rollbackIsDurableUnacceptedAndNeedsAColdReturnBeforeDiscard(_ fault:String) async throws {
        let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let (plan,journal,operation)=try await SNESLibraryColdCheckTests().saved(root)
        let current=try SNESLibrarySelectionTransactionTests().active(plan,fault:"changed-save")
        let attachment=SNESLibraryContextTests.device()
        let permit=try await journal.beginRollback(current:current,attachment:attachment)
        try permit.require(plan,attachment:attachment)
        try permit.claimDispatch()
        #expect(throws:(any Error).self) {try permit.claimDispatch()}
        #expect(throws:(any Error).self) {try permit.require(plan,attachment:SNESLibraryContextTests.device(id:46))}
        #expect(try await journal.phase() == .rollbackIntent)
        let raw=try String(contentsOf:operation.appendingPathComponent("0005.json"),encoding:.utf8)
        #expect(raw.contains("rollbackIntent"))
        await #expect(throws:(any Error).self) {try await journal.beginRollback(current:current,attachment:attachment)}
        let request=try SNESLibraryRollbackCommands.prepare(menu:plan.material.menu,previous:plan.before.selection,current:current,runtimeSHA256:String(repeating:"b",count:64),challenge:permit.challenge)
        if fault == "saved" {try await journal.noteRollbackSaved(SNESLibraryRollbackReceipt(request.receipt,request:request))}
        else {try await journal.rollbackUncertain()}
        #expect(throws:(any Error).self) {try permit.require(plan,attachment:attachment)}
        try await journal.close()
        let reopened=try SNESLibraryJournal(operation:operation,reviewSHA256:plan.reviewSHA256,plan:plan)
        #expect(try await reopened.phase() == (fault == "saved" ? .rollbackAwaitingRestart:.rollbackUncertain))
        #expect(try await reopened.rollbackAttachment()==attachment)
        let old=try SNESLibraryCopyTransactionTests().after(plan,fault:"changed-save")
        let scope=try SNESLibraryDiscardPlan.prepare(plan:plan,current:old,upload:nil)
        let preview=try SNESLibraryDiscardJournalTests().preview(scope,context:old.contextSHA256)
        await #expect(throws:(any Error).self) {try await reopened.beginDiscard(scope:scope,preview:preview,attachment:attachment)}
        let cold=try SNESLibraryColdCheckTests().evidence(plan,suppliedInventory:old,destination:.previous)
        try await reopened.noteRolledBack(cold)
        #expect(try await reopened.phase() == .rolledBack)
        await #expect(throws:(any Error).self) {try await reopened.beginShow(attachment:attachment)}
        try await reopened.close()
        #expect(throws:(any Error).self) {try SNESLibraryJournal.firmwareLease(hwid:plan.before.hwid,root:operation.deletingLastPathComponent())}
        let final=try SNESLibraryJournal(operation:operation,reviewSHA256:plan.reviewSHA256,plan:plan)
        let reconcile=try await final.reconciliation();#expect(reconcile.excludedMenuID==plan.material.menu.id)
        let gone=try SNESLibraryDiscardJournalTests().preview(scope,context:old.contextSHA256,gone:true)
        let device=SyntheticSNESDiscardDevice(inventory:plan.before,gone:gone,fault:"success")
        _=try await SNESLibraryDiscardTransaction.run(plan:plan,journal:final,scope:scope,preview:preview,device:device)
        #expect(try await final.phase() == .discarded)
        try await final.close()
        let lease=try SNESLibraryJournal.firmwareLease(hwid:plan.before.hwid,root:operation.deletingLastPathComponent());try lease.closeLease()
    }
    @Test func onlyAFreshExplicitAttemptCanResumeAnUncertainReturn() async throws {
        let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let (plan,journal,_)=try await SNESLibraryColdCheckTests().saved(root)
        let active=try SNESLibrarySelectionTransactionTests().active(plan),attachment=SNESLibraryContextTests.device()
        let old=try await journal.beginRollback(current:active,attachment:attachment)
        #expect(!old.allowsPendingRecovery);try await journal.rollbackUncertain()
        await #expect(throws:(any Error).self) {try await journal.beginRollback(current:active,attachment:attachment,now:active.capacity.measuredAt.addingTimeInterval(61))}
        #expect(try await journal.phase() == .rollbackUncertain)
        let fresh=try await journal.beginRollback(current:active,attachment:attachment)
        #expect(fresh.allowsPendingRecovery && fresh.challenge != old.challenge)
        #expect(throws:(any Error).self) {try old.require(plan,attachment:attachment)}
        let request=try SNESLibraryRollbackCommands.prepare(menu:plan.material.menu,previous:plan.before.selection,current:active,runtimeSHA256:String(repeating:"b",count:64),challenge:old.challenge)
        await #expect(throws:(any Error).self) {try await journal.noteRollbackSaved(SNESLibraryRollbackReceipt(request.receipt,request:request))}
        #expect(try await journal.phase() == .rollbackIntent)
        try await journal.rollbackUncertain();try await journal.close()
    }
    @Test func coldReturnNeedsItsOwnPendingFileAbsenceProof() async throws {
        let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let plan=try await SNESLibraryJournalTests().plan(root.appendingPathComponent("inputs"))
        let old=try SNESLibraryCopyTransactionTests().after(plan)
        #expect(throws:(any Error).self) {try SNESLibraryColdCheckTests().evidence(plan,suppliedInventory:old,destination:.previous,pendingProof:false)}
        #expect(throws:(any Error).self) {try SNESLibraryColdCheckTests().evidence(plan,suppliedInventory:old,destination:.previous,pendingContext:String(repeating:"c",count:64))}
    }
    @Test func wrongCurrentMenuOrWrongConsoleVersionCannotBeginRollback() async throws {
        let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let (plan,journal,_)=try await SNESLibraryColdCheckTests().saved(root)
        await #expect(throws:(any Error).self) {try await journal.beginRollback(current:plan.before,attachment:SNESLibraryContextTests.device())}
        let active=try SNESLibrarySelectionTransactionTests().active(plan)
        await #expect(throws:(any Error).self) {try await journal.beginRollback(current:active,attachment:SNESLibraryContextTests.device(version:0x6a0b))}
        #expect(try await journal.phase() == .awaitingRestart);try await journal.close()
    }
    @Test func frozenRecoveryCanReturnAfterTheLocalLibraryHasChanged() async throws {
        let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let (plan,journal,operation)=try await SNESLibraryColdCheckTests().saved(root);try await journal.close()
        let source=try #require(plan.material.menu.sources.first)
        try Data("changed local library".utf8).write(to:URL(fileURLWithPath:source.directory).appendingPathComponent(source.name))
        let recovered=try SNESLibrarySyncPlan.load(data:plan.data,expectedReviewSHA256:plan.reviewSHA256,originals:SNESLibraryCompatibilityTests().originals(),purpose:.recovery)
        let next=try SNESLibraryJournal(operation:operation,reviewSHA256:recovered.reviewSHA256,plan:recovered)
        let permit=try await next.beginRollback(current:SNESLibrarySelectionTransactionTests().active(recovered),attachment:SNESLibraryContextTests.device())
        try permit.require(recovered,attachment:SNESLibraryContextTests.device());try await next.rollbackUncertain();try await next.close()
    }
    @Test func failedDurableRollbackIntentCannotIssueAPermit() async throws {
        let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let (plan,journal,operation)=try await SNESLibraryColdCheckTests().saved(root);try await journal.close()
        let fail=OSAllocatedUnfairLock(initialState:false)
        let next=try SNESLibraryJournal(operation:operation,reviewSHA256:plan.reviewSHA256,plan:plan,synchronize:{fd in fail.withLock {$0} ? -1:Darwin.fsync(fd)})
        fail.withLock {$0=true}
        await #expect(throws:(any Error).self) {try await next.beginRollback(current:SNESLibrarySelectionTransactionTests().active(plan),attachment:SNESLibraryContextTests.device())}
        fail.withLock {$0=false};try await next.close()
        #expect(throws:(any Error).self) {try SNESLibraryJournal.firmwareLease(hwid:plan.before.hwid,root:operation.deletingLastPathComponent())}
    }
    @Test func returningToPreviousSelectionKeepsNewSavesButRejectsForeignPoolState() async throws {
        let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let plan=try await SNESLibraryJournalTests().plan(root.appendingPathComponent("inputs"))
        let restored=try SNESLibraryCopyTransactionTests().after(plan,fault:"changed-save")
        try SNESLibraryPreviousCheck.require(plan,inventory:restored)
        #expect(throws:(any Error).self) {try SNESLibraryPreviousCheck.require(plan,inventory:SNESLibraryCopyTransactionTests().after(plan,fault:"extra-object"))}
        #expect(throws:(any Error).self) {try SNESLibraryPreviousCheck.require(plan,inventory:SNESLibrarySelectionTransactionTests().active(plan))}
        #expect(throws:(any Error).self) {try SNESLibraryColdCheckTests().evidence(plan,fault:"same-attachment",suppliedInventory:restored,destination:.previous)}
    }
    @Test(arguments: ["builtin", "library"])
    func restoredSelectorCanFinishDiscardWithFreshIdentity(_ kind: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let plan: SNESLibrarySyncPlan
        var retainedLibraryActive: SNESLibraryInventory?
        if kind == "library" { let fixture = try await SNESLibraryCleanupPlanTests().fixture(root, changedROM: true); plan = fixture.0; retainedLibraryActive = fixture.1 }
        else {
            let (material, _, originals, reference) = try await SNESLibrarySyncPlanTests().fixture(root)
            let backup = try await SNESLibraryRestoreTests().backup(root, originals: originals, builtinSelectorMode: 420)
            plan = try .prepare(material: material, backup: backup, before: backup.inventory, capacity: backup.inventory.capacity, installation: reference, originals: originals)
        }
        let copied = try SNESLibraryCopyTransactionTests().after(plan)
        var lines = String(decoding: copied.rawFrame, as: UTF8.self).components(separatedBy: "\n")
        let key = SNESLibraryInventoryTests().hex("active-menu")
        lines = lines.map { line in
            var f = line.split(separator: " ").map(String.init)
            if f.count == 9 && f[0] == "FILE" && f[1] == key { f[4] = "384"; f[5] = "99"; f[7] = "99999"; f[8] = "100"; return f.joined(separator: " ") }
            return line
        }
        let restored = try SNESLibraryInventory(raw: Data(lines.joined(separator: "\n").utf8), challenge: copied.challenge, contextSHA256: copied.contextSHA256, hwid: copied.hwid, catalogSHA256: copied.catalogSHA256)
        try SNESLibraryPreviousCheck.require(plan, inventory: restored)
        let scope = try SNESLibraryDiscardPlan.prepare(plan: plan, current: restored, upload: nil)
        let transactions = root.appendingPathComponent("transactions"); try FileManager.default.createDirectory(at: transactions, withIntermediateDirectories: false)
        let prepared = try SNESLibraryJournal.prepare(plan: plan, root: transactions)
        let journal = try SNESLibraryJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, plan: plan)
        _ = try await SNESLibraryCopyTransaction.run(plan: plan, journal: journal, device: SyntheticSNESCopyDevice(plan: plan, after: copied, fault: "success"))
        let active = try retainedLibraryActive ?? SNESLibrarySelectionTransactionTests().active(plan)
        _ = try await SNESLibrarySelectionTransaction.run(plan: plan, journal: journal, device: SyntheticSNESSelectionDevice(plan: plan, before: copied, after: active, fault: "success"))
        let permit = try await journal.beginRollback(current: active, attachment: SNESLibraryContextTests.device())
        let request = try SNESLibraryRollbackCommands.prepare(menu: plan.material.menu, previous: plan.before.selection, current: active, runtimeSHA256: String(repeating: "b", count: 64), challenge: permit.challenge)
        try await journal.noteRollbackSaved(SNESLibraryRollbackReceipt(request.receipt, request: request))
        try await journal.noteRolledBack(SNESLibraryColdCheckTests().evidence(plan, suppliedInventory: restored, destination: .previous))
        let preview = try SNESLibraryDiscardJournalTests().preview(scope, context: restored.contextSHA256)
        let gone = try SNESLibraryDiscardJournalTests().preview(scope, context: restored.contextSHA256, gone: true)
        let restoredSelectorFile = try #require(lines.first { $0.hasPrefix("FILE " + key + " ") })
        let cleanLines = String(decoding: plan.before.rawFrame, as: UTF8.self).components(separatedBy: "\n").map { $0.hasPrefix("FILE " + key + " ") ? restoredSelectorFile : $0 }
        let clean = try SNESLibraryInventory(raw: Data(cleanLines.joined(separator: "\n").utf8), challenge: copied.challenge, contextSHA256: copied.contextSHA256, hwid: copied.hwid, catalogSHA256: copied.catalogSHA256)
        _ = try await SNESLibraryDiscardTransaction.run(plan: plan, journal: journal, scope: scope, preview: preview, device: SyntheticSNESDiscardDevice(inventory: clean, gone: gone, fault: "success"))
        #expect(try await journal.phase() == .discarded); try await journal.close()
        let lease = try SNESLibraryJournal.firmwareLease(hwid: plan.before.hwid, root: transactions); try lease.closeLease()
        if kind == "builtin" { return }
        let protected = try #require(restored.files.first { $0.path != "active-menu" && !$0.path.hasPrefix("clover/") })
        var changed = lines
        changed = changed.map { line in
            var f = line.split(separator: " ").map(String.init)
            if f.count == 9 && f[0] == "FILE" && f[1] == SNESLibraryInventoryTests().hex(protected.path) { f[7] = "99998"; return f.joined(separator: " ") }; return line
        }
        let foreign = try SNESLibraryInventory(raw: Data(changed.joined(separator: "\n").utf8), challenge: copied.challenge, contextSHA256: copied.contextSHA256, hwid: copied.hwid, catalogSHA256: copied.catalogSHA256)
        #expect(throws: (any Error).self) { try scope.requireCurrent(plan, inventory: foreign) }
    }

}
