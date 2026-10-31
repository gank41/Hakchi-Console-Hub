import Foundation
import Darwin
import SwiftHakchiCore

struct SNESFirmwareWritePermit:Sendable {
    let id:UUID,reviewSHA256:String
    fileprivate init(id:UUID,reviewSHA256:String){self.id=id;self.reviewSHA256=reviewSHA256}
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
actor SNESFirmwareJournal {
    enum Phase:String,Codable,Sendable {
        case prepared,preflightVerified,writeIntent,readbackVerified,startupVerified,menuAccepted,stoppedBeforeWrite,uncertain
        var unresolved:Bool {[.writeIntent,.readbackVerified,.startupVerified,.uncertain].contains(self)}
        func permits(_ next:Self,direction:SNESFirmwareMaterial.Direction)throws {
            let valid:Bool
            switch (self,next) {
            case (.prepared,.preflightVerified),(.prepared,.stoppedBeforeWrite),(.preflightVerified,.writeIntent),(.preflightVerified,.stoppedBeforeWrite),
                 (.writeIntent,.readbackVerified),(.writeIntent,.uncertain),(.readbackVerified,.startupVerified),(.startupVerified,.menuAccepted):valid=true
            case (.readbackVerified,.menuAccepted):valid=direction == .restore
            default:valid=false
            }
            guard valid else {throw RestoreDirectory.failure()}
        }
    }
    struct Prepared:Sendable {let operation:URL,reviewSHA256:String}
    private struct Record:Codable {let phase:Phase,planSHA256:String,previousSHA256:String?}
    private struct State {let phase:Phase,count:Int,lastSHA256:String}
    private let storage:RestoreJournalStorage,material:SNESFirmwareMaterial,plan:Data
    let reviewSHA256:String
    init(operation:URL,reviewSHA256:String,material:SNESFirmwareMaterial,guard guardValue:SNESFirmwareGuard?=nil,synchronize:@escaping @Sendable(Int32)->Int32={Darwin.fsync($0)})throws {
        if let guardValue {try guardValue.require(material)} else {try material.validateCurrent()}
        let raw=try material.planData()
        guard BackupManifest.digest(raw)==reviewSHA256 else {throw RestoreDirectory.failure()}
        let storage=try RestoreJournalStorage(root:operation.deletingLastPathComponent(),operation:operation,synchronize:synchronize)
        try Self.checkParent(material,in:storage.root)
        try Self.checkOthers(storage,excluding:operation.lastPathComponent,recoveryParent:material.parentOperationID)
        _=try Self.load(storage.operation!,review:reviewSHA256,expectedPlan:raw)
        self.storage=storage;self.material=material;plan=raw;self.reviewSHA256=reviewSHA256
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
            material=try SNESFirmwareMaterial.install(paths:saved.paths,recovery:recovery,id:saved.id)
        } else {
            guard let parentID=saved.parentOperationID,let parentReview=saved.parentReviewSHA256,parentID != saved.id else {throw RestoreDirectory.failure()}
            let parentDirectory=try RestoreDirectory(directory.url.deletingLastPathComponent().appendingPathComponent("SNESFirmware-"+parentID.uuidString))
            let phase=try load(parentDirectory,review:parentReview).phase
            guard saved.direction == .install ? phase == .menuAccepted:restorablePhase(phase) else {throw RestoreDirectory.failure()}
            let parent=try rebuild(parentDirectory,review:parentReview,recovery:recovery,visited:visited.union([saved.id]))
            guard parent.direction == .install,parent.id==parentID else {throw RestoreDirectory.failure()}
            if saved.direction == .install {
                let targetCandidate=try SNESStartupAdapterCandidate.load(directory:URL(fileURLWithPath:saved.paths.candidate))
                let context=try parent.trial.candidate.hasMenuSupport ? libraryParent(material:parent,review:parentReview,directory:parentDirectory.url,legacy:!targetCandidate.hasCorrectedLibrarySupport,targetRecipe:targetCandidate.libraryRecipeVersion):menuParent(material:parent,review:parentReview,directory:parentDirectory.url)
                material=try .upgrade(parent:context,paths:saved.paths,recovery:recovery,id:saved.id)
            } else {material=try .restore(installed:.init(material:parent,reviewSHA256:parentReview,directory:parentDirectory.url),id:saved.id)}
        }
        guard try material.planData()==raw else {throw RestoreDirectory.failure()}
        return material
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
    static func prepare(material:SNESFirmwareMaterial,root:URL,guard guardValue:SNESFirmwareGuard?=nil)throws->Prepared {
        let input:Data
        if let guardValue {try guardValue.require(material);input=material.geometry+material.preimage+material.target} else {input=try material.input()}
        let plan=try material.planData(),review=BackupManifest.digest(plan)
        let storage=try RestoreJournalStorage(root:root);try checkParent(material,in:storage.root);try checkOthers(storage,excluding:nil,recoveryParent:material.parentOperationID)
        let name="SNESFirmware-"+material.id.uuidString
        guard mkdirat(storage.root.fd,name,0o700)==0 else {throw RestoreDirectory.failure()}
        let directory=try RestoreDirectory(storage.root.url.appendingPathComponent(name))
        do {
            guard fchmod(directory.fd,0o700)==0 else {throw RestoreDirectory.failure()}
            try storage.write(input,name:"input.bin",directory:directory)
            try storage.write(plan,name:"plan.json",directory:directory)
            if let guardValue {try guardValue.require(material)} else {try material.validateCurrent()}
            try storage.write(encode(Record(phase:.prepared,planSHA256:review,previousSHA256:nil)),name:"0000.json",directory:directory)
            try storage.sync(directory);try storage.sync(storage.root)
            _=try load(directory,review:review,expectedPlan:plan)
            try storage.closeLease();return .init(operation:directory.url,reviewSHA256:review)
        } catch {
            // This newly owned local preparation has never authorized console I/O.
            // Only its own three leaves may be removed on preparation failure.
            if (try? directory.check()) != nil,(try? storage.root.check()) != nil {
                for leaf in ["0000.json","plan.json","input.bin"] {_=unlinkat(directory.fd,leaf,0)}
                _=unlinkat(storage.root.fd,name,AT_REMOVEDIR)
                _=try? storage.sync(storage.root)
            }
            throw error
        }
    }
    func phase()throws->Phase {try state().phase}
    func verifiedMaterial()throws->SNESFirmwareMaterial {_=try state();try material.validateCurrent();return material}
    func verifiedMaterial(guard guardValue:SNESFirmwareGuard)throws->SNESFirmwareMaterial {
        _=try state();try guardValue.require(material);return material
    }
    func preflightVerified()throws {try append(.preflightVerified)}
    /// Only this transition can construct a permit. Reopened intent can never issue another.
    func beginWrite()throws->SNESFirmwareWritePermit {
        guard try state().phase == .preflightVerified else {throw RestoreDirectory.failure()}
        try append(.writeIntent);return .init(id:material.id,reviewSHA256:reviewSHA256)
    }
    func readbackVerified()throws {try append(.readbackVerified)}
    func startupVerified()throws {try append(.startupVerified)}
    func acceptMenu()throws {try append(.menuAccepted)}
    func menuStartupParent()throws->SNESMenuStartupParent {
        let accepted=try acceptedInstall(),value=try Self.menuParent(material:accepted.material,review:accepted.reviewSHA256,directory:storage.operation!.url)
        _=try acceptedInstall();try value.validate();return value
    }
    func libraryStartupParent()throws->SNESMenuStartupParent {
        let accepted=try acceptedInstall(),value=try Self.libraryParent(material:accepted.material,review:accepted.reviewSHA256,directory:storage.operation!.url)
        _=try acceptedInstall();try value.validate();return value
    }
    private static func libraryParent(material:SNESFirmwareMaterial,review:String,directory:URL,legacy:Bool=false,targetRecipe:Int=10)throws->SNESMenuStartupParent {
        let checked=try SNESFirmwareGuard.prepare(material),previous=material.trial.candidate
        guard material.direction == .install,previous.hasMenuSupport,!previous.hasNativeArtworkSupport,
              (!legacy || !previous.hasLibrarySupport),
              material.parentOperationID != nil,BackupManifest.digest(try material.planData())==review else {throw RestoreDirectory.failure()}
        let candidate=try SNESStartupAdapterCandidate.withLibrarySupport(previous,legacy:legacy,targetRecipe:targetRecipe)
        let seal=try SNESFirmwareSourceSeal.capture(directories:[directory],files:[])
        guard try load(RestoreDirectory(directory),review:review).phase == .menuAccepted else {throw RestoreDirectory.failure()}
        try checked.validate();try seal.validate()
        return try .init(accepted:.init(material:material,reviewSHA256:review,directory:directory),candidate:candidate,directory:directory,source:checked,history:seal)
    }
    private static func menuParent(material:SNESFirmwareMaterial,review:String,directory:URL)throws->SNESMenuStartupParent {
        let checked=try SNESFirmwareGuard.prepare(material)
        guard material.direction == .install,material.parentOperationID==nil,BackupManifest.digest(try material.planData())==review else {throw RestoreDirectory.failure()}
        let manifest=try material.trial.candidate.checkedExport().manifest
        guard let record=try JSONSerialization.jsonObject(with:manifest) as? [String:Any],record["schemaVersion"] as? Int==3 else {throw SNESRuntimeBinding.failure()}
        let candidate=try SNESStartupAdapterCandidate.withMenuSupport(material.trial.candidate)
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
    func close()throws {try storage.closeLease()}
    private func append(_ next:Phase)throws {
        try Task.checkCancellation();let current=try state();try current.phase.permits(next,direction:material.direction)
        try storage.write(Self.encode(Record(phase:next,planSHA256:reviewSHA256,previousSHA256:current.lastSHA256)),name:String(format:"%04d.json",current.count),directory:storage.operation!)
        try storage.sync(storage.operation!);try storage.sync(storage.root)
        let after=try state();guard after.phase==next,after.count==current.count+1 else {throw RestoreDirectory.failure()}
    }
    private func state()throws->State {
        try storage.checkLock();try Self.checkParent(material,in:storage.root)
        try Self.checkOthers(storage,excluding:storage.operation!.url.lastPathComponent,recoveryParent:material.parentOperationID)
        return try Self.load(storage.operation!,review:reviewSHA256,expectedPlan:plan)
    }
    private static func load(_ directory:RestoreDirectory,review:String,expectedPlan:Data?=nil)throws->State {
        let raw=try directory.read("plan.json",maximum:65536)
        guard BackupManifest.digest(raw)==review,expectedPlan.map({$0==raw}) ?? true else {throw RestoreDirectory.failure()}
        let plan=try JSONDecoder().decode(SNESFirmwarePlan.self,from:raw)
        guard [1,2].contains(plan.schemaVersion),plan.scope=="snes-physical-active-boot2",directory.url.lastPathComponent=="SNESFirmware-"+plan.id.uuidString,
              plan.offsetBytes==0x600000,plan.byteCount==7340032,plan.unitBytes==131072 else {throw RestoreDirectory.failure()}
        if plan.schemaVersion==2 {
            guard plan.originalRangeSHA256.map(SNESDataSnapshotChunk.isDigest)==true,plan.parentOperationID != nil,
                  plan.parentReviewSHA256.map(SNESDataSnapshotChunk.isDigest)==true else {throw RestoreDirectory.failure()}
        } else {guard plan.originalRangeSHA256==nil,plan.direction != .install || plan.parentOperationID==nil else {throw RestoreDirectory.failure()}}
        let input=try directory.read("input.bin",maximum:14680088)
        guard input.count==14680088,BackupManifest.digest(input)==plan.inputSHA256,
              BackupManifest.digest(Data(input.prefix(24)))==plan.geometrySHA256,
              BackupManifest.digest(Data(input[24..<7340056]))==plan.preimageSHA256,
              BackupManifest.digest(Data(input[7340056...]))==plan.targetSHA256 else {throw RestoreDirectory.failure()}
        let files=try directory.names(),records=files.filter{$0 != "plan.json" && $0 != "input.bin"}
        guard (1...8).contains(records.count) else {throw RestoreDirectory.failure()}
        var previous:String?,phase:Phase?
        for (index,name) in records.enumerated() {
            guard name==String(format:"%04d.json",index) else {throw RestoreDirectory.failure()}
            let bytes=try directory.read(name,maximum:65536),record=try JSONDecoder().decode(Record.self,from:bytes)
            guard let canonical=try JSONSerialization.jsonObject(with:encode(record)) as? NSDictionary,
                  let original=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],canonical.isEqual(to:original),
                  record.planSHA256==review,record.previousSHA256==previous else {throw RestoreDirectory.failure()}
            if let phase {try phase.permits(record.phase,direction:plan.direction)} else {guard record.phase == .prepared else {throw RestoreDirectory.failure()}}
            phase=record.phase;previous=BackupManifest.digest(bytes)
        }
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
                  plan.schemaVersion==1,plan.parentOperationID==nil,plan.parentReviewSHA256==nil,
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
    private let source:SNESFirmwareGuard,history:SNESFirmwareSourceSeal
    fileprivate init(accepted:SNESFirmwareAcceptedInstall,candidate:SNESStartupAdapterCandidate,directory:URL,source:SNESFirmwareGuard,history:SNESFirmwareSourceSeal) {
        self.candidate=candidate;self.directory=directory;self.source=source;self.history=history
        installed=accepted.material
        activeImage=accepted.material.trial.image
        record = .init(operationID:accepted.material.id,reviewSHA256:accepted.reviewSHA256,activeImageSHA256:BackupManifest.digest(activeImage),activeImageBytes:activeImage.count)
    }
    func validate()throws {try history.validate();try source.validate()}
    func require(_ value:SNESStartupAdapterCandidate)throws {
        try validate()
        guard value.hasMenuSupport,value.image==candidate.image,value.material.binding==candidate.material.binding,
              value.backup.directory==candidate.backup.directory,value.backup.sha256==candidate.backup.sha256 else {throw SNESRuntimeBinding.failure()}
    }
}
