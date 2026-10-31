import Foundation
import SwiftHakchiCore

protocol SNESLibraryRollbackDevice:Sendable {
    func rollbackReady(plan:SNESLibrarySyncPlan) async throws->(RecoveryProbeUSBDevice,SNESLibraryInventory)
    func restorePrevious(plan:SNESLibrarySyncPlan,permit:SNESLibraryRollbackPermit) async throws->SNESLibraryRollbackResult
    func disconnect() async
}
struct SNESLibraryRollbackResult:Sendable {
    let receipt:SNESLibraryRollbackReceipt,after:SNESLibraryInventory
    init(plan:SNESLibrarySyncPlan,permit:SNESLibraryRollbackPermit,request:SNESLibraryRollbackCommands.Request,raw:Data,before:SNESLibraryInventory,after:SNESLibraryInventory)throws {
        try permit.require(plan,attachment:permit.attachment)
        guard request.id==plan.material.menu.id,request.challenge==permit.challenge,request.previous==plan.before.selection,
              request.currentSHA256==before.selection.selectorSHA256,request.contextSHA256==before.contextSHA256,request.contextSHA256==after.contextSHA256,
              request.hwid==plan.before.hwid,before.stateSHA256==permit.expectedStateSHA256,
              before.files.filter({$0.path.hasPrefix("clover/")})==after.files.filter({$0.path.hasPrefix("clover/")}),before.directories==after.directories else {throw SNESLibraryInventory.failure()}
        try SNESLibraryActiveCheck.require(plan,inventory:before,preserveProfiles:false)
        try SNESLibraryPreviousCheck.require(plan,inventory:after)
        receipt=try .init(raw,request:request);self.after=after
    }
}
struct SNESLibraryRollbackUnverified:LocalizedError,Sendable {
    let operation:URL
    var errorDescription:String? {"The previous menu may already be selected. Open this sync again to check it before another attempt. Games and saves were not removed."}
}
enum SNESLibraryRollbackTransaction {
    static func run(plan:SNESLibrarySyncPlan,journal:SNESLibraryJournal,device:any SNESLibraryRollbackDevice,review:SNESLibraryInventory?=nil)async throws->SNESLibraryRollbackResult {
        var dispatched=false
        do {
            try Task.checkCancellation();try plan.requireSources()
            let (attachment,current)=try await device.rollbackReady(plan:plan)
            try Task.checkCancellation();try plan.requireSources()
            if let review {
                // The reviewed menu choice remains fixed; newer saves are kept, not rolled back.
                guard review.contextSHA256==current.contextSHA256,review.selection==current.selection,
                      review.capacity.objects==current.capacity.objects,review.menus==current.menus,
                      review.files.filter({!$0.path.hasPrefix("clover/")})==current.files.filter({!$0.path.hasPrefix("clover/")}) else {throw SNESLibraryInventory.failure()}
            }
            let permit=try await journal.beginRollback(current:current,attachment:attachment);dispatched=true
            try Task.checkCancellation();try permit.require(plan,attachment:attachment)
            let result=try await device.restorePrevious(plan:plan,permit:permit)
            try Task.checkCancellation();try permit.require(plan,attachment:attachment)
            try await journal.noteRollbackSaved(result.receipt)
            await device.disconnect();return result
        } catch {
            if dispatched {try? await Task.detached {try await journal.rollbackUncertain()}.value}
            await device.disconnect()
            if dispatched {throw SNESLibraryRollbackUnverified(operation:journal.rollbackOperation)}
            throw error
        }
    }
}
