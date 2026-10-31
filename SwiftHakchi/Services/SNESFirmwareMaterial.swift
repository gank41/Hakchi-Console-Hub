import Foundation
import SwiftHakchiCore

enum SNESFirmwareRangeTarget {
    static func install(image:Data,over original:Data)throws->Data {
        guard original.count==7340032,!image.isEmpty,image.count<=original.count else {throw SNESRuntimeBinding.failure()}
        let end=((image.count+131071)/131072)*131072
        guard end<=original.count else {throw SNESRuntimeBinding.failure()}
        var target=original;target.replaceSubrange(0..<image.count,with:image)
        if end>image.count {target.replaceSubrange(image.count..<end,with:Data(repeating:255,count:end-image.count))}
        return target
    }
}
struct SNESBoundedWriteHelper:Sendable {
    let bytes:Data,location:URL
    static let sha256="c7e60c081d0d181e248606d2d8bfefc4c8f62d10b5f288415a14510a82bc89bf"
    private init(bytes:Data,location:URL){self.bytes=bytes;self.location=location}
    static func load(_ location:URL)throws->Self {
        let directory=try RestoreDirectory(location.deletingLastPathComponent()),bytes=try directory.read(location.lastPathComponent,maximum:2*1024*1024)
        guard bytes.count==1594072,BackupManifest.digest(bytes)==sha256 else {throw SNESRuntimeBinding.failure()}
        let elf=try ARMRuntimeELF(data:bytes)
        guard elf.type==2,elf.interpreter==nil,elf.dependencies.isEmpty else {throw SNESRuntimeBinding.failure()}
        func word(_ n:Int)->UInt32 {(0..<4).reduce(0){$0 | UInt32(bytes[n+$1]) << ($1*8)}}
        let start=Int(word(28)),count=Int(bytes[44]) | Int(bytes[45])<<8,entry=UInt64(word(24));var found=false
        for i in 0..<count {
            let p=start+i*32,flags=word(p+24),address=UInt64(word(p+8)),size=UInt64(word(p+16))
            guard flags & 3 != 3 else {throw SNESRuntimeBinding.failure()}
            if word(p)==1,flags & 1 != 0,entry>=address,entry-address<size {found=true}
        }
        guard found else {throw SNESRuntimeBinding.failure()};try directory.check()
        return .init(bytes:bytes,location:directory.url.appendingPathComponent(location.lastPathComponent))
    }
    func revalidate()throws {guard try Self.load(location).bytes==bytes else {throw SNESRuntimeBinding.failure()}}
}

struct SNESFirmwarePaths:Codable,Sendable {
    let candidate:String,preflight:String,started:String,played:String,original:String,reader:String,writer:String
    func validate()throws {
        guard [candidate,preflight,started,played,original,reader,writer].allSatisfy({$0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count<=4096}) else {throw SNESRuntimeBinding.failure()}
    }
}
struct SNESFirmwareMaterial:Sendable {
    enum Direction:String,Codable,Sendable {case install,restore}
    let id:UUID,direction:Direction,paths:SNESFirmwarePaths
    let trial:PreparedSNESStartupTrial,proof:SNESFirmwareTrialProof,source:SNESPreparationSource,original:SNESActiveBoot2Package
    let reader:SNESBoundedReadHelper,writer:SNESBoundedWriteHelper,geometry:Data,preimage:Data,target:Data
    let parentReviewSHA256:String?,parentOperationID:UUID?
    let restorationParentDirectory:URL?,restorationParentHistory:SNESFirmwareSourceSeal?
    private init(id:UUID,direction:Direction,paths:SNESFirmwarePaths,trial:PreparedSNESStartupTrial,proof:SNESFirmwareTrialProof,source:SNESPreparationSource,original:SNESActiveBoot2Package,reader:SNESBoundedReadHelper,writer:SNESBoundedWriteHelper,geometry:Data,preimage:Data,target:Data,parentReviewSHA256:String?,parentOperationID:UUID?=nil,restorationParentDirectory:URL?=nil,restorationParentHistory:SNESFirmwareSourceSeal?=nil) {
        self.id=id;self.direction=direction;self.paths=paths;self.trial=trial;self.proof=proof;self.source=source;self.original=original;self.reader=reader;self.writer=writer;self.geometry=geometry;self.preimage=preimage;self.target=target;self.parentReviewSHA256=parentReviewSHA256;self.parentOperationID=parentOperationID
        self.restorationParentDirectory=restorationParentDirectory;self.restorationParentHistory=restorationParentHistory
    }
    static func install(paths:SNESFirmwarePaths,recovery:RecoveryBootInputs,id:UUID=UUID())throws->Self {
        try paths.validate();try Task.checkCancellation()
        func url(_ path:String)->URL {URL(fileURLWithPath:path)}
        let candidate=try SNESStartupAdapterCandidate.load(directory:url(paths.candidate))
        let trial=try PreparedSNESStartupTrial.prepare(candidate:candidate,evidence:url(paths.preflight),recovery:recovery)
        let source=try SNESPreparationSource.load(candidate.material.support.setup)
        let proof=try SNESFirmwareTrialProof.load(started:url(paths.started),played:url(paths.played),trial:trial)
        let original=try SNESActiveBoot2Package.load(directory:url(paths.original),source:source)
        let reader=try SNESBoundedReadHelper.load(url(paths.reader)),writer=try SNESBoundedWriteHelper.load(url(paths.writer))
        let geometry=try RestoreDirectory(original.directory).read("geometry.bin",maximum:24)
        let m=Self(id:id,direction:.install,paths:paths,trial:trial,proof:proof,source:source,original:original,reader:reader,writer:writer,geometry:geometry,
                   preimage:original.active,target:try SNESFirmwareRangeTarget.install(image:trial.image,over:original.active),parentReviewSHA256:nil)
        try m.validateCurrent();return m
    }
    static func restore(installed:SNESFirmwareRestorableInstall,id:UUID=UUID())throws->Self {
        try restoration(parent:installed.material,reviewSHA256:installed.reviewSHA256,directory:installed.directory,history:installed.history,id:id)
    }
    static func upgrade(parent:SNESMenuStartupParent,paths:SNESFirmwarePaths,recovery:RecoveryBootInputs,id:UUID=UUID())throws->Self {
        try paths.validate();try parent.validate()
        let base=parent.installed
        guard id != base.id,paths.original==base.paths.original,paths.reader==base.paths.reader,paths.writer==base.paths.writer else {throw SNESRuntimeBinding.failure()}
        let candidate=try SNESStartupAdapterCandidate.load(directory:URL(fileURLWithPath:paths.candidate));try parent.require(candidate)
        let trial=try PreparedSNESStartupTrial.prepare(candidate:candidate,evidence:URL(fileURLWithPath:paths.preflight),recovery:recovery,parent:parent)
        let proof=try SNESFirmwareTrialProof.load(started:URL(fileURLWithPath:paths.started),played:URL(fileURLWithPath:paths.played),trial:trial)
        let m=Self(id:id,direction:.install,paths:paths,trial:trial,proof:proof,source:base.source,original:base.original,reader:base.reader,writer:base.writer,geometry:base.geometry,
                   preimage:base.target,target:try SNESFirmwareRangeTarget.install(image:trial.image,over:base.original.active),parentReviewSHA256:parent.record.reviewSHA256,parentOperationID:base.id)
        try m.validateCurrent();return m
    }
    var currentImage:Data {direction == .restore ? trial.image:(trial.evidence.parent?.activeImage ?? source.stock)}
    var targetImage:Data {direction == .restore ? source.stock:trial.image}
    static func restore(accepted:SNESFirmwareAcceptedInstall,id:UUID=UUID())throws->Self {
        try restoration(parent:accepted.material,reviewSHA256:accepted.reviewSHA256,directory:accepted.directory,history:accepted.history,id:id)
    }
    private static func restoration(parent:SNESFirmwareMaterial,reviewSHA256:String,directory:URL,history:SNESFirmwareSourceSeal,id:UUID)throws->Self {
        try history.validate();try parent.validateCurrent();try history.validate()
        guard parent.direction == .install,parent.id != id,BackupManifest.digest(try parent.planData())==reviewSHA256 else {throw SNESRuntimeBinding.failure()}
        let m=Self(id:id,direction:.restore,paths:parent.paths,trial:parent.trial,proof:parent.proof,source:parent.source,original:parent.original,
                   reader:parent.reader,writer:parent.writer,geometry:parent.geometry,preimage:parent.target,target:parent.original.active,
                   parentReviewSHA256:reviewSHA256,parentOperationID:parent.id,restorationParentDirectory:directory,restorationParentHistory:history)
        try m.validateCurrent();return m
    }
    func validateCurrent()throws {
        try Task.checkCancellation();try restorationParentHistory?.validate();try paths.validate();try trial.validateCurrent();try proof.revalidate(trial:trial)
        try original.revalidate(source:source);try reader.revalidate();try writer.revalidate()
        let savedGeometry=try RestoreDirectory(original.directory).read("geometry.bin",maximum:24)
        guard geometry==savedGeometry else {throw SNESRuntimeBinding.failure()}
        _=try SNESPhysicalGeometry(geometry)
        let installed=try SNESFirmwareRangeTarget.install(image:trial.image,over:original.active)
        switch direction {
        case .install:
            guard restorationParentDirectory==nil,restorationParentHistory==nil else {throw SNESRuntimeBinding.failure()}
            if let parent=trial.evidence.parent {
                try parent.require(trial.candidate)
                let base=parent.installed
                guard parentOperationID==base.id,parentOperationID != id,parentReviewSHA256==parent.record.reviewSHA256,
                      paths.original==base.paths.original,paths.reader==base.paths.reader,paths.writer==base.paths.writer,
                      original.active==base.original.active,geometry==base.geometry,preimage==base.target,target==installed else {throw SNESRuntimeBinding.failure()}
            } else {
                guard parentReviewSHA256==nil,parentOperationID==nil,preimage==original.active,target==installed else {throw SNESRuntimeBinding.failure()}
            }
        case .restore:guard restorationParentDirectory != nil,restorationParentHistory != nil,let parentOperationID,parentOperationID != id,let parentReviewSHA256,SNESDataSnapshotChunk.isDigest(parentReviewSHA256),preimage==installed,target==original.active else {throw SNESRuntimeBinding.failure()}
        }
        try restorationParentHistory?.validate()
    }
    func input()throws->Data {try validateCurrent();return geometry+preimage+target}
    var changedUnits:[Int] {
        (0..<56).filter {let a=$0*131072;return preimage[a..<a+131072] != target[a..<a+131072]}
    }
}

struct SNESFirmwarePlan:Codable,Sendable {
    let schemaVersion:Int,scope:String,id:UUID,direction:SNESFirmwareMaterial.Direction,paths:SNESFirmwarePaths
    let binding:SNESRuntimeBinding,originalManifestSHA256:String,preimageSHA256:String,targetSHA256:String,geometrySHA256:String,inputSHA256:String
    let candidateSHA256:String,startedSHA256:String,playedSHA256:String,readerSHA256:String,writerSHA256:String
    let offsetBytes:Int,byteCount:Int,unitBytes:Int,parentReviewSHA256:String?,parentOperationID:UUID?
    let originalRangeSHA256:String?
}
extension SNESFirmwareMaterial {
    func planData()throws->Data {
        let menuUpgrade=trial.evidence.parent != nil
        let m=SNESFirmwarePlan(schemaVersion:menuUpgrade ? 2:1,scope:"snes-physical-active-boot2",id:id,direction:direction,paths:paths,
            binding:source.source.runtimeBinding,originalManifestSHA256:original.manifestSHA256,
            preimageSHA256:BackupManifest.digest(preimage),targetSHA256:BackupManifest.digest(target),geometrySHA256:BackupManifest.digest(geometry),
            inputSHA256:BackupManifest.digest(geometry+preimage+target),candidateSHA256:BackupManifest.digest(trial.image),
            startedSHA256:proof.startedSHA256,playedSHA256:proof.playedSHA256,readerSHA256:SNESBoundedReadHelper.sha256,writerSHA256:SNESBoundedWriteHelper.sha256,
            offsetBytes:0x600000,byteCount:7340032,unitBytes:131072,parentReviewSHA256:parentReviewSHA256,parentOperationID:parentOperationID,
            originalRangeSHA256:menuUpgrade ? BackupManifest.digest(original.active):nil)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];return try encoder.encode(m)
    }
}
