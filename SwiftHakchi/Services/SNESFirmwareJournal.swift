import Foundation
import Darwin
import SwiftHakchiCore

private final class SNESFirmwarePermitUse: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() throws {
        lock.lock(); defer { lock.unlock() }
        guard !used else { throw SNESRuntimeBinding.failure() }
        used = true
    }
}

struct SNESFirmwareWritePermit:Sendable {
    let id:UUID,reviewSHA256:String
    private let use:SNESFirmwarePermitUse
    fileprivate init(id:UUID,reviewSHA256:String){self.id=id;self.reviewSHA256=reviewSHA256;self.use=SNESFirmwarePermitUse()}
    func claim() throws { try use.claim() }
}
struct SNESFirmwareAcceptedInstall:Sendable {
    let material:SNESFirmwareMaterial,reviewSHA256:String
    let directory:URL,history:SNESFirmwareSourceSeal
    fileprivate init(material:SNESFirmwareMaterial,reviewSHA256:String,directory:URL)throws {
        self.material=material;self.reviewSHA256=reviewSHA256;self.directory=directory
        history=try SNESFirmwareSourceSeal.capture(directories:[directory],files:[])
    }
}
struct SNESFirmwareRestorableInstall:Sendable {
    let material:SNESFirmwareMaterial,reviewSHA256:String
    let directory:URL,history:SNESFirmwareSourceSeal
    fileprivate init(material:SNESFirmwareMaterial,reviewSHA256:String,directory:URL)throws {
        self.material=material;self.reviewSHA256=reviewSHA256;self.directory=directory
        history=try SNESFirmwareSourceSeal.capture(directories:[directory],files:[])
    }
}
enum SNESFirmwareJournalError:Error {case unresolved}
struct SNESFirmwarePreparationCleanupError: Error, LocalizedError, Sendable {
    let operation: URL
    var errorDescription: String? {
        "The local installation review could not be safely completed and was kept for inspection: \(operation.path). Do not use it until it is inspected. No console operation was requested."
    }
}
struct SNESFirmwarePublicationUncertainError: Error, LocalizedError, Sendable {
    let operation: URL
    var errorDescription: String? {
        "The local installation review may have been published but could not be fully verified: \(operation.path). Keep these files for inspection. Do not use them to update the console. No console operation was requested."
    }
}
actor SNESFirmwareJournal {
    enum Phase:String,Codable,Sendable {
        case prepared,preflightVerified,writeIntent,readbackVerified,startupVerified,menuAccepted,stoppedBeforeWrite,uncertain
        var unresolved:Bool {[.writeIntent,.readbackVerified,.startupVerified,.uncertain].contains(self)}
        func permits(_ next:Self,direction:SNESFirmwareMaterial.Direction,reviewedFirstInstall:Bool=false)throws {
            let valid:Bool
            switch (self,next) {
            case (.prepared,.preflightVerified),(.prepared,.stoppedBeforeWrite),(.preflightVerified,.writeIntent),(.preflightVerified,.stoppedBeforeWrite),
                 (.writeIntent,.readbackVerified),(.writeIntent,.uncertain),(.readbackVerified,.startupVerified),(.startupVerified,.menuAccepted):valid=true
            case (.readbackVerified,.menuAccepted):valid=direction == .restore
            case (.prepared,.writeIntent),(.readbackVerified,.uncertain):valid=direction == .install && reviewedFirstInstall
            default:valid=false
            }
            guard valid else {throw RestoreDirectory.failure()}
        }
    }
    struct Prepared:Sendable {let operation:URL,reviewSHA256:String}
    private struct Record:Codable {
        let phase:Phase,planSHA256:String,previousSHA256:String?
        // Absent on older journals. New prepared records require a marker even
        // if a backup or manual cleanup has omitted that marker.
        let markerRequired:Bool?
        init(phase:Phase,planSHA256:String,previousSHA256:String?,markerRequired:Bool?=nil) {
            self.phase=phase;self.planSHA256=planSHA256;self.previousSHA256=previousSHA256;self.markerRequired=markerRequired
        }
    }
    private struct State {let phase:Phase,count:Int,lastSHA256:String}
    private let storage:RestoreJournalStorage,material:SNESFirmwareMaterial,plan:Data
    private struct ReviewedReservation {let id:UUID;var verified=false;var proof:SNESReviewedPreflightProof?}
    private var reviewedReservation:ReviewedReservation?
    private let afterRecordRead:@Sendable () throws -> Void
    let reviewSHA256:String
    init(operation:URL,reviewSHA256:String,material:SNESFirmwareMaterial,guard guardValue:SNESFirmwareGuard?=nil,synchronize:@escaping @Sendable(Int32)->Int32={Darwin.fsync($0)},afterRecordRead:@escaping @Sendable () throws -> Void = {})throws {
        if let guardValue {try guardValue.require(material)} else {try material.validateCurrent()}
        let raw=try material.planData()
        guard BackupManifest.digest(raw)==reviewSHA256 else {throw RestoreDirectory.failure()}
        let storage=try RestoreJournalStorage(root:operation.deletingLastPathComponent(),operation:operation,synchronize:synchronize)
        try Self.checkParent(material,in:storage.root)
        try Self.checkOthers(storage,excluding:operation.lastPathComponent,recoveryParent:material.parentOperationID)
        _=try Self.load(storage.operation!,review:reviewSHA256,expectedPlan:raw)
        self.storage=storage;self.material=material;plan=raw;self.reviewSHA256=reviewSHA256;self.afterRecordRead=afterRecordRead
    }
    static func reopen(operation:URL,reviewSHA256:String,recovery:RecoveryBootInputs) async throws->SNESFirmwareJournal {
        let directory=try RestoreDirectory(operation),material=try rebuild(directory,review:reviewSHA256,recovery:recovery,visited:[])
        let checked=try SNESFirmwareGuard.prepare(material)
        return try SNESFirmwareJournal(operation:operation,reviewSHA256:reviewSHA256,material:material,guard:checked)
    }
    static func requireRebuildAncestry(id:UUID,visited:Set<UUID>) throws {
        // Discovery admits at most 64 operation directories. Permit their finite ancestry,
        // including a restore child after sequential upgrades, while still refusing cycles.
        guard visited.count<64,!visited.contains(id) else {throw RestoreDirectory.failure()}
    }
    private static func rebuild(_ directory:RestoreDirectory,review:String,recovery:RecoveryBootInputs,visited:Set<UUID>)throws->SNESFirmwareMaterial {
        let raw=try directory.read("plan.json",maximum:65536)
        guard SNESDataSnapshotChunk.isDigest(review),BackupManifest.digest(raw)==review else {throw RestoreDirectory.failure()}
        _=try load(directory,review:review)
        let saved=try JSONDecoder().decode(SNESFirmwarePlan.self,from:raw)
        try requireRebuildAncestry(id:saved.id,visited:visited)
        let material:SNESFirmwareMaterial
        if saved.direction == .install,saved.parentOperationID==nil {
            let rebuilt=try SNESFirmwareMaterial.install(paths:saved.paths,recovery:recovery,id:saved.firstInstall?.startupPlanID ?? saved.id)
            let base=try saved.firstInstall?.startupPlanData.map {try rebuilt.adoptingSavedPlan($0)} ?? rebuilt
            material=try saved.firstInstall.map {try base.bindingFirstInstall($0,operationID:saved.id)} ?? base
        } else {
            guard let parentID=saved.parentOperationID,let parentReview=saved.parentReviewSHA256,parentID != saved.id else {throw RestoreDirectory.failure()}
            let parentDirectory=try RestoreDirectory(directory.url.deletingLastPathComponent().appendingPathComponent("SNESFirmware-"+parentID.uuidString))
            let phase=try load(parentDirectory,review:parentReview).phase
            guard saved.direction == .install ? phase == .menuAccepted:restorablePhase(phase) else {throw RestoreDirectory.failure()}
            let parent=try rebuild(parentDirectory,review:parentReview,recovery:recovery,visited:visited.union([saved.id]))
            guard parent.direction == .install,parent.id==parentID else {throw RestoreDirectory.failure()}
            if saved.direction == .install {
                let targetCandidate=try SNESStartupAdapterCandidate.load(directory:URL(fileURLWithPath:saved.paths.candidate))
                let previous=parent.trial.candidate.backup, next=targetCandidate.backup
                let currentData:SNESDataSnapshotReceipt? = previous.directory.path == next.directory.path && previous.sha256 == next.sha256 && previous.manifestSHA256 == next.manifestSHA256 ? nil : .init(directory:next.directory,manifestSHA256:next.manifestSHA256)
                let context=try parent.trial.candidate.hasMenuSupport ? libraryParent(material:parent,review:parentReview,directory:parentDirectory.url,legacy:!targetCandidate.hasCorrectedLibrarySupport,targetRecipe:targetCandidate.libraryRecipeVersion,currentData:currentData):menuParent(material:parent,review:parentReview,directory:parentDirectory.url,currentData:currentData)
                material=try .upgrade(parent:context,paths:saved.paths,recovery:recovery,id:saved.id)
            } else {material=try .restore(installed:.init(material:parent,reviewSHA256:parentReview,directory:parentDirectory.url),id:saved.id)}
        }
        // Preserve exact historical bytes for every schema after checking all
        // decoded fields against material rebuilt from the saved sources.
        return try material.adoptingSavedPlan(raw)
    }
    /// Bounded Mac discovery only. Every returned hint must still be fully reconstructed.
    static func acceptedReferences(root:URL,hwid:String)throws->[SNESLibraryFirmwareReference] {
        guard hwid.count==32,SNESRuntimeBinding.hex(hwid),hwid.contains(where:{$0 != "0"}) else {throw RestoreDirectory.failure()}
        let storage=try RestoreJournalStorage(root:root)
        do {
            try checkOthers(storage,excluding:nil)
            let names=try storage.root.names().filter{$0 != ".stock-restore.lock" && $0 != ".DS_Store"}
            guard names.count<=64 else {throw RestoreDirectory.failure()}
            var records:[(SNESFirmwarePlan,String)]=[]
            for name in names {
                guard name.hasPrefix("SNESFirmware-"),UUID(uuidString:String(name.dropFirst(13))) != nil else {throw RestoreDirectory.failure()}
                let directory=try RestoreDirectory(storage.root.url.appendingPathComponent(name)),raw=try directory.read("plan.json",maximum:65536),review=BackupManifest.digest(raw)
                let plan=try JSONDecoder().decode(SNESFirmwarePlan.self,from:raw)
                if try load(directory,review:review).phase == .menuAccepted,plan.binding.expectedHWID==hwid {
                    try plan.paths.validate();records.append((plan,review))
                }
            }
            let superseded=Set(records.compactMap{$0.0.parentOperationID})
            let result=records.filter{$0.0.direction == .install}.map {plan,review in
                SNESLibraryFirmwareReference(id:plan.id,reviewSHA256:review,hwid:hwid,parentID:plan.parentOperationID,
                    candidate:URL(fileURLWithPath:plan.paths.candidate),imageSHA256:plan.candidateSHA256,isCurrentCandidate:!superseded.contains(plan.id))
            }
            try storage.closeLease();return result
        } catch {try? storage.closeLease();throw error}
    }
    static func prepare(material:SNESFirmwareMaterial,root:URL,guard guardValue:SNESFirmwareGuard?=nil,
                        afterCreate:@Sendable () throws -> Void = {},
                        verifyFinal:@Sendable () throws -> Void = {},
                        synchronize:@escaping @Sendable (Int32)->Int32 = { Darwin.fsync($0) })throws->Prepared {
        let input:Data
        let reviewedSeal:SNESFirmwareSourceSeal?
        if material.firstInstall != nil {reviewedSeal=try material.validateReviewedFirstInstall()} else {reviewedSeal=nil}
        if let guardValue {try guardValue.require(material);input=material.geometry+material.preimage+material.target} else {input=try material.input()}
        let plan=try material.planData(),review=BackupManifest.digest(plan)
        // Refuse oversized plans before creating a journal or completion marker.
        guard !plan.isEmpty,plan.count<=65536 else {throw SNESRuntimeBinding.failure()}
        let storage=try RestoreJournalStorage(root:root,synchronize:synchronize);try checkParent(material,in:storage.root);try checkOthers(storage,excluding:nil,recoveryParent:material.parentOperationID)
        let name="SNESFirmware-"+material.id.uuidString
        guard mkdirat(storage.root.fd,name,0o700)==0 else {throw RestoreDirectory.failure()}
        let operationURL = storage.root.url.appendingPathComponent(name)
        var createdDirectory = stat()
        guard fstatat(storage.root.fd, name, &createdDirectory, AT_SYMLINK_NOFOLLOW) == 0,
              createdDirectory.st_mode & S_IFMT == S_IFDIR else { throw SNESFirmwarePreparationCleanupError(operation: operationURL) }
        let directory: RestoreDirectory
        do {
            try afterCreate(); directory = try RestoreDirectory(operationURL)
            var opened = stat()
            guard fstat(directory.fd, &opened) == 0, opened.st_dev == createdDirectory.st_dev,
                  opened.st_ino == createdDirectory.st_ino, opened.st_uid == geteuid(),
                  opened.st_mode & 0o777 == 0o700 else { throw RestoreDirectory.failure() }
        }
        catch { throw SNESFirmwarePreparationCleanupError(operation: operationURL) }
        var published = false
        do {
            guard try directory.names().isEmpty else { throw RestoreDirectory.failure() }
            // Make an interrupted preparation visible before publishing any record.
            // Older completed journals have no marker and remain readable.
            try storage.write(Data(review.utf8),name:"preparation.pending",directory:directory)
            try storage.sync(directory);try storage.sync(storage.root)
            try storage.write(input,name:"input.bin",directory:directory)
            try storage.write(plan,name:"plan.json",directory:directory)
            if let guardValue {try guardValue.require(material)} else {try material.validateCurrent()}
            try storage.write(encode(Record(phase:.prepared,planSHA256:review,previousSHA256:nil,markerRequired:true)),name:"0000.pending",directory:directory)
            try storage.sync(directory);try storage.sync(storage.root)
            _=try load(directory,review:review,expectedPlan:plan,pending:true,preparing:true)
            try verifyFinal()
            try reviewedSeal?.validate()
            if let guardValue {try guardValue.require(material)} else {try material.validateCurrent()}
            if material.firstInstall != nil {try material.validateReviewedFirstInstall()}
            try reviewedSeal?.validate()
            _=try load(directory,review:review,expectedPlan:plan,pending:true,preparing:true)
            try Task.checkCancellation()
            try storage.checkLock(); try directory.check()
            var staged = stat(), final = stat()
            guard fstatat(directory.fd,"0000.pending",&staged,AT_SYMLINK_NOFOLLOW)==0,
                  staged.st_mode & S_IFMT == S_IFREG,staged.st_nlink==1,
                  renameatx_np(directory.fd,"0000.pending",directory.fd,"0000.json",UInt32(RENAME_EXCL))==0 else {throw RestoreDirectory.failure()}
            published = true
            guard fstatat(directory.fd,"0000.json",&final,AT_SYMLINK_NOFOLLOW)==0,
                  final.st_mode & S_IFMT == S_IFREG,final.st_nlink==1,
                  staged.st_dev==final.st_dev,staged.st_ino==final.st_ino else {throw RestoreDirectory.failure()}
            _=try load(directory,review:review,expectedPlan:plan,preparing:true)
            if let guardValue {try guardValue.require(material)} else {try material.validateCurrent()}
            try storage.sync(directory);try reviewedSeal?.validate();try storage.sync(storage.root);try reviewedSeal?.validate()
            // Only mark the operation complete after the published record and its
            // containing directories have been verified and synchronized.
            var marker = stat(), completed = stat()
            guard fstatat(directory.fd,"preparation.pending",&marker,AT_SYMLINK_NOFOLLOW)==0,
                  marker.st_mode & S_IFMT == S_IFREG,marker.st_nlink==1,
                  try directory.read("preparation.pending",maximum:64)==Data(review.utf8),
                  renameatx_np(directory.fd,"preparation.pending",directory.fd,"preparation.complete",UInt32(RENAME_EXCL))==0,
                  fstatat(directory.fd,"preparation.complete",&completed,AT_SYMLINK_NOFOLLOW)==0,
                  completed.st_mode & S_IFMT == S_IFREG,completed.st_nlink==1,
                  marker.st_dev==completed.st_dev,marker.st_ino==completed.st_ino else {throw RestoreDirectory.failure()}
            try reviewedSeal?.validate();try storage.sync(directory);try storage.sync(storage.root);try reviewedSeal?.validate()
            _=try load(directory,review:review,expectedPlan:plan)
            try reviewedSeal?.validate()
            try storage.closeLease();return .init(operation:directory.url,reviewSHA256:review)
        } catch {
            // The directory or a leaf can be replaced between any identity check
            // and unlink. Preserve all files rather than deleting uncertain data.
            if published { throw SNESFirmwarePublicationUncertainError(operation: operationURL) }
            throw SNESFirmwarePreparationCleanupError(operation: operationURL)
        }
    }
    func phase()throws->Phase {try state().phase}
    func requiresReviewedPreflight()->Bool {material.firstInstall != nil}
    func verifiedMaterial()throws->SNESFirmwareMaterial {_=try state();try material.validateCurrent();return material}
    func verifiedMaterial(guard guardValue:SNESFirmwareGuard)throws->SNESFirmwareMaterial {
        _=try state();try guardValue.require(material);return material
    }
    func preflightVerified()throws {
        // The legacy preflight does not compare the independent reviewed data.
        // Reviewed installs use a fresh owned-session check instead.
        guard material.firstInstall==nil else {throw RestoreDirectory.failure()}
        try append(.preflightVerified)
    }
    /// Reserve one read-only reviewed session. No persistent success record is
    /// written; every future installation must check the live backup again.
    func reserveReviewedPreflight()throws->UUID {
        try Task.checkCancellation()
        guard material.firstInstall != nil,reviewedReservation==nil,try state().phase == .prepared else {throw RestoreDirectory.failure()}
        let id=UUID();reviewedReservation=ReviewedReservation(id:id);return id
    }
    func verifyReviewedPreflight(_ proof:SNESReviewedPreflightProof,reservation:UUID)throws {
        guard material.firstInstall != nil,reviewedReservation?.id==reservation,reviewedReservation?.verified==false else {throw RestoreDirectory.failure()}
        try proof.consume(operation:material.id,review:reviewSHA256,reservation:reservation) {
            guard try state().phase == .prepared else {throw RestoreDirectory.failure()}
        }
        reviewedReservation?.verified=true;reviewedReservation?.proof=proof
    }
    func finishReviewedPreflight(_ id:UUID,verify:@Sendable () throws -> Void)throws {
        guard reviewedReservation?.id==id,reviewedReservation?.verified==true,try state().phase == .prepared else {throw RestoreDirectory.failure()}
        try verify()
        reviewedReservation=nil
    }
    /// Issue one permit only while the same live session still owns its verified backup proof.
    func beginReviewedWrite(_ id:UUID,proof:SNESReviewedPreflightProof)throws->SNESFirmwareWritePermit {
        guard material.firstInstall != nil,reviewedReservation?.id==id,reviewedReservation?.verified==true,
              reviewedReservation?.proof === proof,try state().phase == .prepared else {throw RestoreDirectory.failure()}
        try proof.validate();try append(.writeIntent,reservation:id);try proof.validate()
        return .init(id:material.id,reviewSHA256:reviewSHA256)
    }
    /// A successful readback is recorded only after the owned connection has closed.
    func finishReviewedWrite(_ id:UUID,verify:@Sendable () throws -> Void)throws {
        guard reviewedReservation?.id==id,reviewedReservation?.verified==true,try state().phase == .writeIntent else {throw RestoreDirectory.failure()}
        try verify();try append(.readbackVerified,reservation:id);try verify()
    }
    /// Preserve an interrupted intent even when the calling task was cancelled.
    func failReviewedWrite(_ id:UUID)throws {
        guard reviewedReservation?.id==id else {throw RestoreDirectory.failure()}
        defer {reviewedReservation=nil}
        let current=try state().phase
        if current == .writeIntent || current == .readbackVerified {try append(.uncertain,reservation:id)}
    }
    /// Cleanup is cancellation-independent and cannot release a newer owner.
    func releaseReviewedPreflight(_ id:UUID) {if reviewedReservation?.id==id {reviewedReservation=nil}}
    /// Only this transition can construct a permit. Reopened intent can never issue another.
    func beginWrite()throws->SNESFirmwareWritePermit {
        // Reviewed installs must use beginReviewedWrite with the same-session
        // backup proof; the legacy permit cannot authorize them.
        guard material.firstInstall==nil else {throw RestoreDirectory.failure()}
        guard try state().phase == .preflightVerified else {throw RestoreDirectory.failure()}
        try append(.writeIntent);return .init(id:material.id,reviewSHA256:reviewSHA256)
    }
    func readbackVerified()throws {try append(.readbackVerified)}
    func startupVerified()throws {try append(.startupVerified)}
    func acceptMenu()throws {try append(.menuAccepted)}
    func menuStartupParent(currentData:SNESDataSnapshotReceipt?=nil)throws->SNESMenuStartupParent {
        let accepted=try acceptedInstall(),value=try Self.menuParent(material:accepted.material,review:accepted.reviewSHA256,directory:storage.operation!.url,currentData:currentData)
        _=try acceptedInstall();try value.validate();return value
    }
    func libraryStartupParent(currentData:SNESDataSnapshotReceipt?=nil)throws->SNESMenuStartupParent {
        let accepted=try acceptedInstall(),value=try Self.libraryParent(material:accepted.material,review:accepted.reviewSHA256,directory:storage.operation!.url,currentData:currentData)
        _=try acceptedInstall();try value.validate();return value
    }
    /// Creates a RAM-only candidate from an already accepted recipe 10 installation.
    func parallelLibraryStartupParent(currentData:SNESDataSnapshotReceipt?=nil)throws->SNESMenuStartupParent {
        let accepted=try acceptedInstall(),value=try Self.libraryParent(material:accepted.material,review:accepted.reviewSHA256,directory:storage.operation!.url,targetRecipe:11,currentData:currentData)
        _=try acceptedInstall();try value.validate();return value
    }
    /// A separate RAM-only combined-stat trial; it is not installable firmware.
    func combinedLibraryStartupParent(currentData:SNESDataSnapshotReceipt?=nil)throws->SNESMenuStartupParent {
        let accepted=try acceptedInstall(),value=try Self.libraryParent(material:accepted.material,review:accepted.reviewSHA256,directory:storage.operation!.url,targetRecipe:12,currentData:currentData)
        _=try acceptedInstall();try value.validate();return value
    }
    /// A RAM-only queued-navigation trial based on the accepted recipe 10.
    func queuedLibraryStartupParent(currentData:SNESDataSnapshotReceipt?=nil)throws->SNESMenuStartupParent {
        let accepted=try acceptedInstall(),value=try Self.libraryParent(material:accepted.material,review:accepted.reviewSHA256,directory:storage.operation!.url,targetRecipe:13,currentData:currentData)
        _=try acceptedInstall();try value.validate();return value
    }
    /// A RAM-only concurrent-verification trial based on the accepted recipe 10.
    func concurrentLibraryStartupParent(currentData:SNESDataSnapshotReceipt?=nil)throws->SNESMenuStartupParent {
        let accepted=try acceptedInstall(),value=try Self.libraryParent(material:accepted.material,review:accepted.reviewSHA256,directory:storage.operation!.url,targetRecipe:14,currentData:currentData)
        _=try acceptedInstall();try value.validate();return value
    }
    private static func libraryParent(material:SNESFirmwareMaterial,review:String,directory:URL,legacy:Bool=false,targetRecipe:Int=10,currentData:SNESDataSnapshotReceipt?=nil)throws->SNESMenuStartupParent {
        let checked=try SNESFirmwareGuard.prepare(material),previous=material.trial.candidate
        guard material.direction == .install,previous.hasMenuSupport,
              ([11,12,13,14].contains(targetRecipe) ? previous.libraryRecipeVersion == 10 : !previous.hasNativeArtworkSupport),
              (!legacy || !previous.hasLibrarySupport),
              material.parentOperationID != nil,BackupManifest.digest(try material.planData())==review else {throw RestoreDirectory.failure()}
        let base=try SNESStartupAdapterCandidate.withLibrarySupport(previous,legacy:legacy,targetRecipe:targetRecipe)
        let candidate=try currentData.map {try SNESStartupAdapterCandidate.withCurrentBackup(base,receipt:$0)} ?? base
        let seal=try SNESFirmwareSourceSeal.capture(directories:[directory],files:[])
        guard try load(RestoreDirectory(directory),review:review).phase == .menuAccepted else {throw RestoreDirectory.failure()}
        try checked.validate();try seal.validate()
        return try .init(accepted:.init(material:material,reviewSHA256:review,directory:directory),candidate:candidate,directory:directory,source:checked,history:seal)
    }
    private static func menuParent(material:SNESFirmwareMaterial,review:String,directory:URL,currentData:SNESDataSnapshotReceipt?=nil)throws->SNESMenuStartupParent {
        let checked=try SNESFirmwareGuard.prepare(material)
        guard material.direction == .install,material.parentOperationID==nil,BackupManifest.digest(try material.planData())==review else {throw RestoreDirectory.failure()}
        let manifest=try material.trial.candidate.checkedExport().manifest
        guard let record=try JSONSerialization.jsonObject(with:manifest) as? [String:Any],record["schemaVersion"] as? Int==3 else {throw SNESRuntimeBinding.failure()}
        let base=try SNESStartupAdapterCandidate.withMenuSupport(material.trial.candidate)
        let candidate=try currentData.map {try SNESStartupAdapterCandidate.withCurrentBackup(base,receipt:$0)} ?? base
        let seal=try SNESFirmwareSourceSeal.capture(directories:[directory],files:[])
        guard try load(RestoreDirectory(directory),review:review).phase == .menuAccepted else {throw RestoreDirectory.failure()}
        try checked.validate();try seal.validate()
        return try .init(accepted:.init(material:material,reviewSHA256:review,directory:directory),candidate:candidate,directory:directory,source:checked,history:seal)
    }
    /// Validated accepted ancestors let a newer recipe reuse its owner's original-game capture.
    func acceptedLineage()throws->[SNESFirmwareAcceptedInstall] {
        var result=[try acceptedInstall()],seen=Set<UUID>()
        while let current=result.last {
            guard result.count<=8,seen.insert(current.material.id).inserted else {throw RestoreDirectory.failure()}
            guard let parent=current.material.trial.evidence.parent else {break}
            try parent.require(current.material.trial.candidate)
            let directory=try RestoreDirectory(parent.directory)
            guard directory.url.deletingLastPathComponent()==storage.root.url,
                  current.material.parentOperationID==parent.record.operationID,
                  current.material.parentReviewSHA256==parent.record.reviewSHA256,
                  try Self.load(directory,review:parent.record.reviewSHA256).phase == .menuAccepted else {throw RestoreDirectory.failure()}
            result.append(try .init(material:parent.installed,reviewSHA256:parent.record.reviewSHA256,directory:directory.url))
        }
        try storage.checkLock();return result
    }
    func restorableInstall()throws->SNESFirmwareRestorableInstall {
        guard try Self.restorablePhase(state().phase),material.direction == .install else {throw RestoreDirectory.failure()}
        try material.validateCurrent();return try .init(material:material,reviewSHA256:reviewSHA256,directory:storage.operation!.url)
    }
    func acceptedInstall()throws->SNESFirmwareAcceptedInstall {
        guard try state().phase == .menuAccepted,material.direction == .install else {throw RestoreDirectory.failure()}
        try material.validateCurrent();return try .init(material:material,reviewSHA256:reviewSHA256,directory:storage.operation!.url)
    }
    func uncertain()throws {try append(.uncertain)}
    func stoppedBeforeWrite()throws {try append(.stoppedBeforeWrite)}
    func close()throws {guard reviewedReservation==nil else {throw LegacyInspectionError.busy};try storage.closeLease()}
    private func append(_ next:Phase,reservation:UUID?=nil)throws {
        if let active=reviewedReservation {guard reservation==active.id else {throw LegacyInspectionError.busy}}
        else {guard reservation==nil else {throw LegacyInspectionError.busy}}
        try Task.checkCancellation();let current=try state();try current.phase.permits(next,direction:material.direction,reviewedFirstInstall:material.firstInstall != nil)
        try storage.write(Self.encode(Record(phase:next,planSHA256:reviewSHA256,previousSHA256:current.lastSHA256)),name:String(format:"%04d.json",current.count),directory:storage.operation!)
        try storage.sync(storage.operation!);try storage.sync(storage.root)
        let after=try state();guard after.phase==next,after.count==current.count+1 else {throw RestoreDirectory.failure()}
    }
    private func state()throws->State {
        try storage.checkLock();try Self.checkParent(material,in:storage.root)
        try Self.checkOthers(storage,excluding:storage.operation!.url.lastPathComponent,recoveryParent:material.parentOperationID)
        return try Self.load(storage.operation!,review:reviewSHA256,expectedPlan:plan,afterRead:afterRecordRead)
    }
    private static func load(_ directory:RestoreDirectory,review:String,expectedPlan:Data?=nil,pending:Bool=false,preparing:Bool=false,afterRead:() throws -> Void = {})throws->State {
        let raw=try directory.read("plan.json",maximum:65536)
        guard BackupManifest.digest(raw)==review,expectedPlan.map({$0==raw}) ?? true else {throw RestoreDirectory.failure()}
        try SNESStrictJSONKeys.validate(raw)
        let plan=try JSONDecoder().decode(SNESFirmwarePlan.self,from:raw)
        guard [1,2,3].contains(plan.schemaVersion),plan.scope=="snes-physical-active-boot2",directory.url.lastPathComponent=="SNESFirmware-"+plan.id.uuidString,
              plan.offsetBytes==0x600000,plan.byteCount==7340032,plan.unitBytes==131072 else {throw RestoreDirectory.failure()}
        if plan.schemaVersion==3 {
            guard let first=plan.firstInstall,plan.direction == .install,plan.parentOperationID==nil,
                  plan.parentReviewSHA256==nil,plan.originalRangeSHA256==nil,first.startupPlanID != plan.id else {throw RestoreDirectory.failure()}
            try first.validate()
            guard BackupManifest.digest(try plan.reviewedStartupPlanData())==first.startupPlanSHA256 else {throw RestoreDirectory.failure()}
            guard let original=try JSONSerialization.jsonObject(with:raw) as? NSDictionary,
                  let canonical=try JSONSerialization.jsonObject(with:encode(plan)) as? [String:Any],
                  original.isEqual(to:canonical) else {throw RestoreDirectory.failure()}
        } else if plan.schemaVersion==2 {
            guard plan.originalRangeSHA256.map(SNESDataSnapshotChunk.isDigest)==true,plan.parentOperationID != nil,
                  plan.parentReviewSHA256.map(SNESDataSnapshotChunk.isDigest)==true,plan.firstInstall==nil else {throw RestoreDirectory.failure()}
        } else {guard plan.firstInstall==nil,plan.originalRangeSHA256==nil,plan.direction != .install || plan.parentOperationID==nil else {throw RestoreDirectory.failure()}}
        let input=try directory.read("input.bin",maximum:14680088)
        guard input.count==14680088,BackupManifest.digest(input)==plan.inputSHA256,
              BackupManifest.digest(Data(input.prefix(24)))==plan.geometrySHA256,
              BackupManifest.digest(Data(input[24..<7340056]))==plan.preimageSHA256,
              BackupManifest.digest(Data(input[7340056...]))==plan.targetSHA256 else {throw RestoreDirectory.failure()}
        let files=try directory.names(),marker=preparing ? "preparation.pending":"preparation.complete"
        if preparing || plan.schemaVersion==3 || files.contains(marker) {
            guard files.contains(marker),try directory.read(marker,maximum:64)==Data(review.utf8) else {throw RestoreDirectory.failure()}
        }
        let records=files.filter{$0 != "plan.json" && $0 != "input.bin" && $0 != marker}
        guard (1...8).contains(records.count) else {throw RestoreDirectory.failure()}
        if pending { guard records == ["0000.pending"] else {throw RestoreDirectory.failure()} }
        var previous:String?,phase:Phase?,checkedRecords:[(String,Data)]=[]
        for (index,name) in records.enumerated() {
            guard name==(pending ? "0000.pending" : String(format:"%04d.json",index)) else {throw RestoreDirectory.failure()}
            let bytes=try directory.read(name,maximum:65536)
            try SNESStrictJSONKeys.validate(bytes)
            let record=try JSONDecoder().decode(Record.self,from:bytes)
            guard let canonical=try JSONSerialization.jsonObject(with:encode(record)) as? NSDictionary,
                  let original=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],canonical.isEqual(to:original),
                  record.planSHA256==review,record.previousSHA256==previous else {throw RestoreDirectory.failure()}
            if let phase {
                guard record.markerRequired == nil else {throw RestoreDirectory.failure()}
                try phase.permits(record.phase,direction:plan.direction,reviewedFirstInstall:plan.firstInstall != nil)
            } else {
                guard record.phase == .prepared else {throw RestoreDirectory.failure()}
                if plan.schemaVersion==3 {guard record.markerRequired==true else {throw RestoreDirectory.failure()}}
                if record.markerRequired == true {
                    guard files.contains(marker) else {throw RestoreDirectory.failure()}
                } else {
                    guard record.markerRequired == nil,!preparing,!files.contains(marker) else {throw RestoreDirectory.failure()}
                }
            }
            checkedRecords.append((name,bytes))
            phase=record.phase;previous=BackupManifest.digest(bytes)
        }
        try afterRead();try Task.checkCancellation()
        guard try directory.names()==files,
              try directory.read("plan.json",maximum:65536)==raw,
              try directory.read("input.bin",maximum:14680088)==input else {throw RestoreDirectory.failure()}
        for (name,bytes) in checkedRecords {
            try Task.checkCancellation()
            guard try directory.read(name,maximum:65536)==bytes else {throw RestoreDirectory.failure()}
        }
        if files.contains(marker) {
            guard try directory.read(marker,maximum:64)==Data(review.utf8) else {throw RestoreDirectory.failure()}
        }
        guard try directory.names()==files else {throw RestoreDirectory.failure()}
        try directory.check();return .init(phase:phase!,count:records.count,lastSHA256:previous!)
    }
    private static func checkParent(_ material:SNESFirmwareMaterial,in root:RestoreDirectory)throws {
        guard material.parentOperationID != nil else {guard material.direction == .install else {throw RestoreDirectory.failure()};return}
        guard let id=material.parentOperationID,let review=material.parentReviewSHA256 else {throw RestoreDirectory.failure()}
        let parent=try RestoreDirectory(root.url.appendingPathComponent("SNESFirmware-"+id.uuidString))
        let phase=try load(parent,review:review).phase
        guard material.direction == .install ? phase == .menuAccepted:restorablePhase(phase) else {throw RestoreDirectory.failure()}
        let raw=try parent.read("plan.json",maximum:65536),plan=try JSONDecoder().decode(SNESFirmwarePlan.self,from:raw)
        guard plan.direction == .install,plan.id==id,plan.binding==material.source.source.runtimeBinding,
              plan.targetSHA256==BackupManifest.digest(material.preimage),
              plan.geometrySHA256==BackupManifest.digest(material.geometry),plan.originalManifestSHA256==material.original.manifestSHA256,
              (plan.originalRangeSHA256 ?? plan.preimageSHA256)==BackupManifest.digest(material.original.active) else {throw RestoreDirectory.failure()}
        if material.direction == .install {
            guard let accepted=material.trial.evidence.parent else {throw RestoreDirectory.failure()}
            try requireUpgradeParent(accepted,savedPlan:raw,directory:parent.url)
        } else {
            guard material.target==material.original.active,plan.candidateSHA256==BackupManifest.digest(material.trial.image),
                  material.restorationParentDirectory?.path==parent.url.path else {throw RestoreDirectory.failure()}
        }
        try root.check()
    }
    /// Preserve the original 3→4 lineage and admit only the separately reconstructed 4→5 parent.
    /// A plan's schema alone never establishes an upgrade relationship.
    static func requireUpgradeParent(_ parent:SNESMenuStartupParent,savedPlan:Data,directory:URL)throws {
        try parent.require(parent.candidate)
        guard parent.directory.path==directory.path,
              BackupManifest.digest(savedPlan)==parent.record.reviewSHA256,
              try parent.installed.planData()==savedPlan else {throw RestoreDirectory.failure()}
        let plan=try JSONDecoder().decode(SNESFirmwarePlan.self,from:savedPlan)
        guard plan.direction == .install,plan.id==parent.record.operationID else {throw RestoreDirectory.failure()}
        if parent.candidate.hasLibrarySupport {
            guard parent.installed.trial.candidate.hasMenuSupport,!parent.installed.trial.candidate.hasNativeArtworkSupport,
                  (parent.candidate.hasNativeArtworkSupport || !parent.installed.trial.candidate.hasCleanMenuLaunch),
                  (parent.candidate.hasCleanMenuLaunch || !parent.installed.trial.candidate.hasEfficientNavigation),
                  (parent.candidate.hasEfficientNavigation || !parent.installed.trial.candidate.hasNavigationLaunchSupport),
                  (parent.candidate.hasNavigationLaunchSupport || !parent.installed.trial.candidate.hasCorrectedLibrarySupport),
                  (parent.candidate.hasCorrectedLibrarySupport || !parent.installed.trial.candidate.hasLibrarySupport),
                  plan.schemaVersion==2,plan.parentOperationID != nil,plan.parentReviewSHA256 != nil,
                  plan.originalRangeSHA256 != nil else {throw RestoreDirectory.failure()}
        } else {
            guard parent.candidate.hasMenuSupport,!parent.installed.trial.candidate.hasMenuSupport,
                  [1,3].contains(plan.schemaVersion),plan.parentOperationID==nil,plan.parentReviewSHA256==nil,
                  plan.originalRangeSHA256==nil else {throw RestoreDirectory.failure()}
        }
        try parent.validate()
    }
    private static func restorablePhase(_ phase:Phase)->Bool {[.readbackVerified,.startupVerified,.menuAccepted].contains(phase)}
    private struct NamedState {let name:String,plan:SNESFirmwarePlan,review:String,phase:Phase}
    /// Fresh sibling state is not covered by immutable accepted-install source seals.
    static func validateSiblingHistory(root:URL,excluding:UUID,recoveryParent:UUID?)throws {
        let storage=try RestoreJournalStorage(root:root)
        defer {try? storage.closeLease()}
        try checkOthers(storage,excluding:"SNESFirmware-"+excluding.uuidString,recoveryParent:recoveryParent)
        try storage.checkLock()
    }
    private static func checkOthers(_ storage:RestoreJournalStorage,excluding:String?,recoveryParent:UUID?=nil)throws {
        try storage.checkLock();let names=try storage.root.names().filter{$0 != ".stock-restore.lock" && $0 != ".DS_Store" && $0 != excluding}
        guard names.count<=64 else {throw RestoreDirectory.failure()}
        let entries=try names.map {name->NamedState in
            guard name.hasPrefix("SNESFirmware-"),UUID(uuidString:String(name.dropFirst(13))) != nil else {throw RestoreDirectory.failure()}
            let directory=try RestoreDirectory(storage.root.url.appendingPathComponent(name)),raw=try directory.read("plan.json",maximum:65536),review=BackupManifest.digest(raw)
            return .init(name:name,plan:try JSONDecoder().decode(SNESFirmwarePlan.self,from:raw),review:review,phase:try load(directory,review:review).phase)
        }
        for entry in entries where entry.phase.unresolved {
            // Only the already-reconstructed exact parent may be bypassed by its
            // own restore child. Sibling unresolved work always remains a gate.
            if entry.plan.id==recoveryParent {continue}
            let recovered=entry.plan.direction == .install && restorablePhase(entry.phase) && entries.contains {child in
                child.phase == .menuAccepted && child.plan.direction == .restore &&
                child.plan.parentOperationID==entry.plan.id && child.plan.parentReviewSHA256==entry.review &&
                child.plan.binding==entry.plan.binding && child.plan.originalManifestSHA256==entry.plan.originalManifestSHA256 &&
                child.plan.candidateSHA256==entry.plan.candidateSHA256 && child.plan.geometrySHA256==entry.plan.geometrySHA256 &&
                child.plan.preimageSHA256==entry.plan.targetSHA256 && child.plan.targetSHA256==(entry.plan.originalRangeSHA256 ?? entry.plan.preimageSHA256)
            }
            guard recovered else {throw SNESFirmwareJournalError.unresolved}
        }
    }
    private static func encode<T:Encodable>(_ value:T)throws->Data {let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];return try e.encode(value)}
}

/// Only the accepted journal can issue this parent. It authorizes RAM preparation,
/// never a firmware write. Reference storage breaks recursive evidence value layout.
final class SNESMenuStartupParent:Sendable {
    struct Record:Codable,Equatable,Sendable {
        let operationID:UUID,reviewSHA256:String,activeImageSHA256:String,activeImageBytes:Int
    }
    let candidate:SNESStartupAdapterCandidate,directory:URL,activeImage:Data,record:Record
    let installed:SNESFirmwareMaterial
    private let source:SNESFirmwareGuard,history:SNESFirmwareSourceSeal,backupSeal:SNESFirmwareSourceSeal
    fileprivate init(accepted:SNESFirmwareAcceptedInstall,candidate:SNESStartupAdapterCandidate,directory:URL,source:SNESFirmwareGuard,history:SNESFirmwareSourceSeal) throws {
        self.candidate=candidate;self.directory=directory;self.source=source;self.history=history
        backupSeal=try SNESFirmwareSourceSeal.capture(directories:[candidate.backup.directory],files:[])
        installed=accepted.material
        activeImage=accepted.material.trial.image
        record = .init(operationID:accepted.material.id,reviewSHA256:accepted.reviewSHA256,activeImageSHA256:BackupManifest.digest(activeImage),activeImageBytes:activeImage.count)
    }
    func validate()throws {try history.validate();try source.validate();try backupSeal.validate()}
    func require(_ value:SNESStartupAdapterCandidate)throws {
        try validate()
        guard value.hasMenuSupport,value.image==candidate.image,value.material.binding==candidate.material.binding,
              value.backup.directory.path==candidate.backup.directory.path,value.backup.sha256==candidate.backup.sha256,
              value.backup.manifestSHA256==candidate.backup.manifestSHA256 else {throw SNESRuntimeBinding.failure()}
    }
}
