import Foundation
import os
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryRollbackTransactionTests {
    @Test(arguments:["success","lost-response","bad-receipt","changed-save","source-after-save","cancelled"])
    func returnDispatchesOnceAndNeverAcceptsOrRetries(_ fault:String) async throws {
        let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let (plan,journal,_)=try await SNESLibraryColdCheckTests().saved(root)
        let device=SyntheticSNESRollbackDevice(plan:plan,before:try SNESLibrarySelectionTransactionTests().active(plan),after:try SNESLibraryCopyTransactionTests().after(plan,fault:fault == "changed-save" ? "changed-save":""),fault:fault)
        if fault == "success" {
            _=try await SNESLibraryRollbackTransaction.run(plan:plan,journal:journal,device:device)
            #expect(try await journal.phase() == .rollbackAwaitingRestart)
        } else if fault == "cancelled" {
            let finished=OSAllocatedUnfairLock(initialState:false)
            let task=Task {defer {finished.withLock {$0=true}};return try await SNESLibraryRollbackTransaction.run(plan:plan,journal:journal,device:device)}
            while !(await device.isPaused) && !finished.withLock({$0}) {await Task.yield()}
            #expect(await device.isPaused)
            task.cancel();await device.release()
            await #expect(throws:(any Error).self) {try await task.value}
            #expect(try await journal.phase() == .rollbackUncertain)
        } else {
            await #expect(throws:(any Error).self) {try await SNESLibraryRollbackTransaction.run(plan:plan,journal:journal,device:device)}
            #expect(try await journal.phase() == .rollbackUncertain)
        }
        #expect(await device.counts()==[1,1]);try await journal.close()
    }
    @Test func saveProgressAfterReviewIsPreservedWhileReturningTheSameReviewedMenu() async throws {
        let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let (plan,journal,_)=try await SNESLibraryColdCheckTests().saved(root)
        let review=try SNESLibrarySelectionTransactionTests().active(plan)
        let live=try SNESLibrarySelectionTransactionTests().active(plan,fault:"changed-save")
        let previous=try SNESLibraryCopyTransactionTests().after(plan,fault:"changed-save")
        let device=SyntheticSNESRollbackDevice(plan:plan,before:live,after:previous,fault:"success")
        _=try await SNESLibraryRollbackTransaction.run(plan:plan,journal:journal,device:device,review:review)
        #expect(await device.counts()==[1,1]);#expect(try await journal.phase() == .rollbackAwaitingRestart)
        try await journal.close()
    }
    @Test func changedReviewStopsBeforeCreatingAnyMutationPermit() async throws {
        let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let (plan,journal,_)=try await SNESLibraryColdCheckTests().saved(root)
        let device=SyntheticSNESRollbackDevice(plan:plan,before:try SNESLibrarySelectionTransactionTests().active(plan),after:try SNESLibraryCopyTransactionTests().after(plan),fault:"success")
        await #expect(throws:(any Error).self) {try await SNESLibraryRollbackTransaction.run(plan:plan,journal:journal,device:device,review:plan.before)}
        #expect(await device.counts()==[0,1]);#expect(try await journal.phase() == .awaitingRestart);try await journal.close()
    }
}
actor SyntheticSNESRollbackDevice:SNESLibraryRollbackDevice {
    let plan:SNESLibrarySyncPlan,before:SNESLibraryInventory,after:SNESLibraryInventory,fault:String
    private var writes=0,closes=0,paused:CheckedContinuation<Void,Never>?
    var isPaused:Bool {paused != nil}
    func release() {paused?.resume();paused=nil}
    init(plan:SNESLibrarySyncPlan,before:SNESLibraryInventory,after:SNESLibraryInventory,fault:String) {self.plan=plan;self.before=before;self.after=after;self.fault=fault}
    func rollbackReady(plan:SNESLibrarySyncPlan)->(RecoveryProbeUSBDevice,SNESLibraryInventory) {(SNESLibraryContextTests.device(version:plan.requiredUSBVersion),before)}
    func restorePrevious(plan:SNESLibrarySyncPlan,permit:SNESLibraryRollbackPermit) async throws->SNESLibraryRollbackResult {
        writes+=1;try permit.require(plan,attachment:SNESLibraryContextTests.device(version:plan.requiredUSBVersion));try permit.claimDispatch()
        #expect(throws:(any Error).self) {try permit.claimDispatch()}
        let records=try FileManager.default.contentsOfDirectory(atPath:permit.operation.path).filter {$0.range(of:#"^[0-9]{4}\.json$"#,options:.regularExpression) != nil}.sorted()
        #expect(try String(contentsOf:permit.operation.appendingPathComponent(#require(records.last)),encoding:.utf8).contains("rollbackIntent"))
        if fault == "cancelled" {await withCheckedContinuation {paused=$0}}
        if fault == "lost-response" {throw LegacyInspectionError.timeout}
        let request=try SNESLibraryRollbackCommands.prepare(menu:plan.material.menu,previous:plan.before.selection,current:before,runtimeSHA256:String(repeating:"b",count:64),challenge:permit.challenge,recoverPending:permit.allowsPendingRecovery)
        if fault == "source-after-save",let source=plan.material.menu.sources.first {try Data("changed".utf8).write(to:URL(fileURLWithPath:source.directory).appendingPathComponent(source.name))}
        return try .init(plan:plan,permit:permit,request:request,raw:fault == "bad-receipt" ? request.receipt+Data([10]):request.receipt,before:before,after:after)
    }
    func disconnect() {closes+=1}
    func counts()->[Int] {[writes,closes]}
}
