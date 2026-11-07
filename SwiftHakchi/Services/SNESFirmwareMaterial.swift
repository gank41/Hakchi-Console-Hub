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
    var digest:String {BackupManifest.digest(bytes)}
    private init(bytes:Data,location:URL){self.bytes=bytes;self.location=location}
    static func load(_ location:URL)throws->Self {
        let directory=try RestoreDirectory(location.deletingLastPathComponent()),bytes=try directory.read(location.lastPathComponent,maximum:2*1024*1024)
        let digest=BackupManifest.digest(bytes)
        guard (bytes.count==1594072 && digest==sha256) ||
              SNESPortableHelpers.recognizes(kind:.writer,byteCount:bytes.count,sha256:digest) else {throw SNESRuntimeBinding.failure()}
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
    static func withHelpers(candidate:URL,preflight:URL,started:URL,played:URL,original:URL,
                            helpers:SNESPortableHelperPackage)throws->Self {
        try helpers.revalidate()
        guard [candidate,preflight,started,played,original].allSatisfy(\.isFileURL) else {throw SNESRuntimeBinding.failure()}
        let paths=Self(candidate:candidate.path,preflight:preflight.path,started:started.path,played:played.path,
                       original:original.path,reader:helpers.reader.location.path,writer:helpers.writer.location.path)
        try paths.validate();try helpers.revalidate();return paths
    }
    func validate()throws {
        guard [candidate,preflight,started,played,original,reader,writer].allSatisfy({$0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count<=4096}) else {throw SNESRuntimeBinding.failure()}
    }
}
struct SNESFirmwareVerifiedInputs: Sendable {
    let backup: SNESSetupRecordReceipt, helpers: URL, candidate: SNESSetupRecordReceipt
    let helpersManifestSHA256: String
    let preflight: SNESStartupPreflightReceipt, started: SNESSetupRecordReceipt, played: SNESSetupRecordReceipt, active: SNESSetupRecordReceipt
    let currentData: SNESDataSnapshotReceipt
}
struct SNESFirmwarePreparationReceipt: Sendable {
    let offlineReviewSHA256: String, changedUnits: Int
    let savedReview: SNESFirstInstallReviewReceipt?
    init(offlineReviewSHA256: String, changedUnits: Int, savedReview: SNESFirstInstallReviewReceipt? = nil) {
        self.offlineReviewSHA256 = offlineReviewSHA256; self.changedUnits = changedUnits; self.savedReview = savedReview
    }
}
/// A temporary Mac-only review; this is not a firmware journal or write permit.
struct SNESFirstInstallOfflineReview: Encodable, Sendable {
    let schemaVersion = 1, scope = "snes-first-install-offline-review"
    let startupPlanSHA256: String, dataDirectory: String, dataManifestSHA256: String, dataSHA256: String
    let dataBytes: Int
    init(startupPlanSHA256: String, dataDirectory: URL, dataManifestSHA256: String, dataSHA256: String, dataBytes: Int) throws {
        guard [startupPlanSHA256,dataManifestSHA256,dataSHA256].allSatisfy(SNESDataSnapshotChunk.isDigest),
              dataDirectory.isFileURL, dataDirectory == dataDirectory.standardizedFileURL,
              dataDirectory.path.hasPrefix("/"), !dataDirectory.path.contains("\0"), dataDirectory.path.utf8.count <= 4096,
              (1048576...536870912).contains(dataBytes), dataBytes % 1048576 == 0 else { throw SNESRuntimeBinding.failure() }
        self.startupPlanSHA256=startupPlanSHA256;self.dataDirectory=dataDirectory.path
        self.dataManifestSHA256=dataManifestSHA256;self.dataSHA256=dataSHA256;self.dataBytes=dataBytes
    }
    func canonicalBytes() throws -> Data {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return try encoder.encode(self)
    }
    func digest() throws -> String { BackupManifest.digest(try canonicalBytes()) }
    private struct Fields: Decodable {
        let schemaVersion: Int, scope: String, startupPlanSHA256: String, dataDirectory: String
        let dataManifestSHA256: String, dataSHA256: String, dataBytes: Int
    }
    /// Checks a pinned record only; it does not validate referenced files or authorize a write.
    static func load(_ data: Data, expectedSHA256: String) throws -> Self {
        guard data.count <= 65536, SNESDataSnapshotChunk.isDigest(expectedSHA256),
              BackupManifest.digest(data) == expectedSHA256 else { throw SNESRuntimeBinding.failure() }
        try SNESStrictJSONKeys.validate(data)
        let fields = try JSONDecoder().decode(Fields.self, from: data)
        guard fields.schemaVersion == 1, fields.scope == "snes-first-install-offline-review",
              fields.dataDirectory.hasPrefix("/") else { throw SNESRuntimeBinding.failure() }
        let directory = URL(fileURLWithPath: fields.dataDirectory)
        guard directory.path == fields.dataDirectory else { throw SNESRuntimeBinding.failure() }
        let review = try Self(startupPlanSHA256: fields.startupPlanSHA256, dataDirectory: directory,
            dataManifestSHA256: fields.dataManifestSHA256, dataSHA256: fields.dataSHA256, dataBytes: fields.dataBytes)
        // The receipt pins exact bytes. Compare the typed fields independently
        // so harmless encoder formatting changes do not strand a saved review.
        guard let original=try JSONSerialization.jsonObject(with:data) as? NSDictionary,
              let expected=try JSONSerialization.jsonObject(with:review.canonicalBytes()) as? [String:Any],
              original.isEqual(to:expected) else { throw SNESRuntimeBinding.failure() }
        return review
    }
}
/// A pinned Mac-only draft, not evidence of a live check or an authorization to write.
struct SNESFirstInstallReviewReceipt: Sendable {
    let directory: URL, sha256: String
    /// Pin what the user selected for a new review; this does not establish prior approval.
    static func inspect(directory: URL) throws -> Self {
        guard directory.isFileURL, directory == directory.standardizedFileURL else { throw SNESRuntimeBinding.failure() }
        let held = try RestoreDirectory(directory)
        let bytes = try held.read("manifest.json", maximum: 65536)
        let receipt = Self(directory: directory, sha256: BackupManifest.digest(bytes))
        _ = try open(receipt)
        guard try held.read("manifest.json", maximum: 65536) == bytes else { throw SNESRuntimeBinding.failure() }
        try held.check()
        return receipt
    }
    static func open(_ receipt: Self, afterRead: () throws -> Void = {}) throws -> SNESFirstInstallOfflineReview {
        let prefix = "SNES-First-Install-Review-"
        guard receipt.directory.isFileURL, receipt.directory == receipt.directory.standardizedFileURL,
              receipt.directory.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(receipt.directory.lastPathComponent.dropFirst(prefix.count))) != nil else { throw SNESRuntimeBinding.failure() }
        let directory = try RestoreDirectory(receipt.directory)
        let expected: Set<String> = ["manifest.json", "startup-plan.json"]
        guard Set(try directory.names()) == expected else { throw SNESRuntimeBinding.failure() }
        let bytes = try directory.read("manifest.json", maximum: 65536)
        let review = try SNESFirstInstallOfflineReview.load(bytes, expectedSHA256: receipt.sha256)
        let plan = try directory.read("startup-plan.json", maximum: 65536)
        guard BackupManifest.digest(plan) == review.startupPlanSHA256 else { throw SNESRuntimeBinding.failure() }
        try afterRead(); try directory.check()
        guard Set(try directory.names()) == expected,
              try directory.read("manifest.json", maximum: 65536) == bytes,
              try directory.read("startup-plan.json", maximum: 65536) == plan else { throw SNESRuntimeBinding.failure() }
        try directory.check()
        return review
    }
}
/// Identifies the exact Mac review and independent data backup for a new install.
/// It is not an approval, a live-console check, or a firmware write permit.
struct SNESFirstInstallPlanBinding:Codable,Sendable,Equatable {
    static let maximumStartupPlanBytes=16384
    let reviewDirectory:String,reviewSHA256:String,startupPlanSHA256:String
    let startupPlanID:UUID
    // New records retain the exact reviewed bytes. Older schema-3 records
    // omit this field and retain their original reconstruction behavior.
    let startupPlanData:Data?
    let dataDirectory:String,dataManifestSHA256:String,dataSHA256:String,dataBytes:Int
    let requiresPreparationMarker:Bool
    init(receipt:SNESFirstInstallReviewReceipt,review:SNESFirstInstallOfflineReview,startupPlanID:UUID,startupPlanData:Data?=nil)throws {
        reviewDirectory=receipt.directory.path;reviewSHA256=receipt.sha256;startupPlanSHA256=review.startupPlanSHA256
        self.startupPlanID=startupPlanID;self.startupPlanData=startupPlanData
        dataDirectory=review.dataDirectory;dataManifestSHA256=review.dataManifestSHA256;dataSHA256=review.dataSHA256
        dataBytes=review.dataBytes;requiresPreparationMarker=true
        try validate()
    }
    func validate()throws {
        func validDirectory(_ path:String,prefix:String)->Bool {
            let url=URL(fileURLWithPath:path),name=url.lastPathComponent
            return path.hasPrefix("/") && !path.contains("\0") && path.utf8.count<=4096 &&
                url.standardizedFileURL.path==path && name.hasPrefix(prefix) && UUID(uuidString:String(name.dropFirst(prefix.count))) != nil
        }
        guard validDirectory(reviewDirectory,prefix:"SNES-First-Install-Review-"),
              validDirectory(dataDirectory,prefix:"SNES-Current-Data-"),
              [reviewSHA256,startupPlanSHA256,dataManifestSHA256,dataSHA256].allSatisfy(SNESDataSnapshotChunk.isDigest),
              (1048576...536870912).contains(dataBytes),dataBytes%1048576==0,requiresPreparationMarker else {throw SNESRuntimeBinding.failure()}
        if let startupPlanData {
            guard (1...Self.maximumStartupPlanBytes).contains(startupPlanData.count),BackupManifest.digest(startupPlanData)==startupPlanSHA256 else {throw SNESRuntimeBinding.failure()}
        }
    }
}
struct SNESFirmwareMaterial:Sendable {
    /// Experimental startup recipes may be booted temporarily, never written as firmware.
    static func requireInstallableRecipe(_ version: Int) throws {
        guard (1...10).contains(version) else { throw SNESRuntimeBinding.failure() }
    }
    enum Direction:String,Codable,Sendable {case install,restore}
    let id:UUID,direction:Direction,paths:SNESFirmwarePaths
    let trial:PreparedSNESStartupTrial,proof:SNESFirmwareTrialProof,source:SNESPreparationSource,original:SNESActiveBoot2Package
    let reader:SNESBoundedReadHelper,writer:SNESBoundedWriteHelper,geometry:Data,preimage:Data,target:Data
    let parentReviewSHA256:String?,parentOperationID:UUID?
    let restorationParentDirectory:URL?,restorationParentHistory:SNESFirmwareSourceSeal?
    let firstInstall:SNESFirstInstallPlanBinding?
    private let preservedPlan:Data?
    private init(id:UUID,direction:Direction,paths:SNESFirmwarePaths,trial:PreparedSNESStartupTrial,proof:SNESFirmwareTrialProof,source:SNESPreparationSource,original:SNESActiveBoot2Package,reader:SNESBoundedReadHelper,writer:SNESBoundedWriteHelper,geometry:Data,preimage:Data,target:Data,parentReviewSHA256:String?,parentOperationID:UUID?=nil,restorationParentDirectory:URL?=nil,restorationParentHistory:SNESFirmwareSourceSeal?=nil,firstInstall:SNESFirstInstallPlanBinding?=nil,preservedPlan:Data?=nil) {
        self.id=id;self.direction=direction;self.paths=paths;self.trial=trial;self.proof=proof;self.source=source;self.original=original;self.reader=reader;self.writer=writer;self.geometry=geometry;self.preimage=preimage;self.target=target;self.parentReviewSHA256=parentReviewSHA256;self.parentOperationID=parentOperationID
        self.restorationParentDirectory=restorationParentDirectory;self.restorationParentHistory=restorationParentHistory
        self.firstInstall=firstInstall;self.preservedPlan=preservedPlan
    }
    /// Preserve the reviewed bytes only after checking every decoded field
    /// against freshly reconstructed, verified material.
    func adoptingSavedPlan(_ raw:Data)throws->Self {
        guard try SNESFirmwarePlan.sameFields(raw,planData()) else {throw SNESRuntimeBinding.failure()}
        return Self(id:id,direction:direction,paths:paths,trial:trial,proof:proof,source:source,original:original,
            reader:reader,writer:writer,geometry:geometry,preimage:preimage,target:target,
            parentReviewSHA256:parentReviewSHA256,parentOperationID:parentOperationID,
            restorationParentDirectory:restorationParentDirectory,restorationParentHistory:restorationParentHistory,
            firstInstall:firstInstall,preservedPlan:raw)
    }
    /// Structural binding only. Active installation must separately reload and
    /// verify the reviewed files and obtain same-session write authorization.
    func bindingFirstInstall(_ binding:SNESFirstInstallPlanBinding,operationID:UUID=UUID())throws->Self {
        try binding.validate();try validateCurrent()
        guard direction == .install,parentOperationID==nil,firstInstall==nil,id==binding.startupPlanID,operationID != id,
              BackupManifest.digest(try planData())==binding.startupPlanSHA256 else {throw SNESRuntimeBinding.failure()}
        return Self(id:operationID,direction:direction,paths:paths,trial:trial,proof:proof,source:source,original:original,
            reader:reader,writer:writer,geometry:geometry,preimage:preimage,target:target,
            parentReviewSHA256:parentReviewSHA256,parentOperationID:parentOperationID,firstInstall:binding)
    }
    /// Required for a new preparation. Historical restore reconstruction does
    /// not depend on the newer snapshot remaining on the Mac.
    @discardableResult func validateReviewedFirstInstall()throws->SNESFirmwareSourceSeal {
        guard let binding=firstInstall,direction == .install,parentOperationID==nil,trial.evidence.backupMatches else {throw SNESRuntimeBinding.failure()}
        try binding.validate();try validateCurrent()
        let reviewURL=URL(fileURLWithPath:binding.reviewDirectory),dataURL=URL(fileURLWithPath:binding.dataDirectory)
        let seal=try SNESFirmwareSourceSeal.capture(directories:[reviewURL,dataURL],files:[])
        try seal.requireFileDigest(reviewURL.appendingPathComponent("manifest.json"),sha256:binding.reviewSHA256,maximum:65536)
        try seal.requireFileDigest(reviewURL.appendingPathComponent("startup-plan.json"),sha256:binding.startupPlanSHA256,maximum:65536)
        try seal.requireFileDigest(dataURL.appendingPathComponent("manifest.json"),sha256:binding.dataManifestSHA256,maximum:65536)
        let review=try SNESFirstInstallReviewReceipt.open(.init(directory:reviewURL,sha256:binding.reviewSHA256))
        guard review.startupPlanSHA256==binding.startupPlanSHA256,review.dataDirectory==binding.dataDirectory,
              review.dataManifestSHA256==binding.dataManifestSHA256,review.dataSHA256==binding.dataSHA256,
              review.dataBytes==binding.dataBytes else {throw SNESRuntimeBinding.failure()}
        let data=try SNESDataSnapshotPackage.load(receipt:.init(directory:dataURL,manifestSHA256:binding.dataManifestSHA256),source:source)
        guard data.sha256==binding.dataSHA256,data.byteCount==binding.dataBytes else {throw SNESRuntimeBinding.failure()}
        _=try Self.requireFirstInstallBackup(candidate:trial.candidate)
        try SNESColdBootPolicy.require(boot1:source.boot1,image:trial.image)
        try data.revalidate();try seal.validate();try validateCurrent();try seal.validate();return seal
    }
    /// New first-install reviews require the backup to belong to the exact setup.
    /// Legacy recovery reconstruction intentionally retains its original policy.
    static func requireFirstInstallBackup(candidate: SNESStartupAdapterCandidate) throws -> SNESDataSnapshotPackage {
        let source = try SNESPreparationSource.load(candidate.material.support.setup)
        let receipt = SNESDataSnapshotReceipt(directory: candidate.backup.directory, manifestSHA256: candidate.backup.manifestSHA256)
        let checked = try SNESDataSnapshotPackage.load(receipt: receipt, source: source)
        guard checked.sha256 == candidate.backup.sha256, checked.byteCount == candidate.backup.byteCount else { throw SNESRuntimeBinding.failure() }
        return checked
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
    /// Builds a first-install plan only from the exact records confirmed in the guide.
    static func install(verified: SNESFirmwareVerifiedInputs, recovery: RecoveryBootInputs, id: UUID = UUID()) throws -> Self {
        guard verified.backup.kind == .backup, verified.candidate.kind == .candidate,
              verified.preflight.record.kind == .preflight, verified.preflight.backupMatches,
              verified.started.kind == .trialStarted, verified.played.kind == .trialPlayed,
              verified.active.kind == .activeBoot2 else { throw SNESRuntimeBinding.failure() }
        let setup = try SNESOfflineSource.load(snapshot: verified.backup.directory)
        guard setup.manifestSHA256 == verified.backup.manifestSHA256 else { throw SNESRuntimeBinding.failure() }
        let candidate = try SNESStartupAdapterCandidate.load(directory: verified.candidate.directory, expectedManifestSHA256: verified.candidate.manifestSHA256)
        guard candidate.material.support.setup.directoryURL == setup.directoryURL,
              candidate.material.support.setup.manifestSHA256 == setup.manifestSHA256 else { throw SNESRuntimeBinding.failure() }
        let checkedBackup = try requireFirstInstallBackup(candidate: candidate)
        let trial = try PreparedSNESStartupTrial.prepare(candidate: candidate, receipt: verified.preflight, recovery: recovery)
        let source = try SNESPreparationSource.load(setup)
        let currentData = try SNESDataSnapshotPackage.load(receipt: verified.currentData, source: source)
        let proof = try SNESFirmwareTrialProof.load(started: verified.started.directory, played: verified.played.directory, trial: trial,
            expectedStartedSHA256: verified.started.manifestSHA256, expectedPlayedSHA256: verified.played.manifestSHA256)
        let original = try SNESActiveBoot2Package.load(directory: verified.active.directory, source: source)
        guard original.manifestSHA256 == verified.active.manifestSHA256 else { throw SNESRuntimeBinding.failure() }
        let helpers = try SNESPortableHelperPackage.load(directory: verified.helpers)
        guard helpers.manifestSHA256 == verified.helpersManifestSHA256 else { throw SNESRuntimeBinding.failure() }
        let paths = try SNESFirmwarePaths.withHelpers(candidate: verified.candidate.directory, preflight: verified.preflight.record.directory,
            started: verified.started.directory, played: verified.played.directory, original: verified.active.directory, helpers: helpers)
        let geometry = try RestoreDirectory(original.directory).read("geometry.bin", maximum: 24)
        let m = Self(id: id, direction: .install, paths: paths, trial: trial, proof: proof, source: source, original: original,
            reader: helpers.reader, writer: helpers.writer, geometry: geometry, preimage: original.active,
            target: try SNESFirmwareRangeTarget.install(image: trial.image, over: original.active), parentReviewSHA256: nil)
        try m.validateCurrent(); try helpers.revalidate()
        let reloaded = try SNESStartupAdapterCandidate.load(directory: verified.candidate.directory, expectedManifestSHA256: verified.candidate.manifestSHA256)
        guard reloaded.image == candidate.image else { throw SNESRuntimeBinding.failure() }
        try trial.evidence.requireReceipt(verified.preflight, candidate: candidate)
        try proof.revalidate(trial: trial); try original.revalidate(source: source); try checkedBackup.revalidate(); try currentData.revalidate(); try setup.revalidate()
        return m
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
        try Self.requireInstallableRecipe(trial.candidate.libraryRecipeVersion)
        try Task.checkCancellation();try restorationParentHistory?.validate();try paths.validate();try trial.validateCurrent();try proof.revalidate(trial:trial)
        if let firstInstall {try firstInstall.validate();guard direction == .install,parentOperationID==nil,firstInstall.startupPlanID != id else {throw SNESRuntimeBinding.failure()}}
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
    var firstInstall:SNESFirstInstallPlanBinding? = nil
    /// Rebuild the exact unbound v1 plan which the user reviewed, without
    /// requiring the newer data snapshot for historical discovery or restore.
    func reviewedStartupPlanData()throws->Data {
        guard schemaVersion==3,let firstInstall else {throw SNESRuntimeBinding.failure()}
        let base=Self(schemaVersion:1,scope:scope,id:firstInstall.startupPlanID,direction:direction,paths:paths,
            binding:binding,originalManifestSHA256:originalManifestSHA256,preimageSHA256:preimageSHA256,
            targetSHA256:targetSHA256,geometrySHA256:geometrySHA256,inputSHA256:inputSHA256,candidateSHA256:candidateSHA256,
            startedSHA256:startedSHA256,playedSHA256:playedSHA256,readerSHA256:readerSHA256,writerSHA256:writerSHA256,
            offsetBytes:offsetBytes,byteCount:byteCount,unitBytes:unitBytes,parentReviewSHA256:parentReviewSHA256,
            parentOperationID:parentOperationID,originalRangeSHA256:originalRangeSHA256,firstInstall:nil)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        let rebuilt=try encoder.encode(base)
        guard let saved=firstInstall.startupPlanData else {return rebuilt}
        try firstInstall.validate()
        guard try SNESFirmwarePlan.sameFields(saved,rebuilt) else {throw SNESRuntimeBinding.failure()}
        return saved
    }
    /// Compare decoded fields while the original bytes remain bound by their digest.
    static func sameFields(_ left:Data,_ right:Data)throws->Bool {
        guard left.count<=65536,right.count<=65536 else {throw SNESRuntimeBinding.failure()}
        // Reject ambiguous keys before decoding, and validate types before
        // Foundation's comparison can equate booleans with numbers.
        try SNESStrictJSONKeys.validate(left);try SNESStrictJSONKeys.validate(right)
        _=try JSONDecoder().decode(Self.self,from:left)
        _=try JSONDecoder().decode(Self.self,from:right)
        guard let a=try JSONSerialization.jsonObject(with:left) as? NSDictionary,
              let b=try JSONSerialization.jsonObject(with:right) as? [String:Any] else {throw SNESRuntimeBinding.failure()}
        return a.isEqual(to:b)
    }
}
extension SNESFirmwareMaterial {
    func planData()throws->Data {
        if let preservedPlan {return preservedPlan}
        let menuUpgrade=trial.evidence.parent != nil
        let m=SNESFirmwarePlan(schemaVersion:firstInstall != nil ? 3:(menuUpgrade ? 2:1),scope:"snes-physical-active-boot2",id:id,direction:direction,paths:paths,
            binding:source.source.runtimeBinding,originalManifestSHA256:original.manifestSHA256,
            preimageSHA256:BackupManifest.digest(preimage),targetSHA256:BackupManifest.digest(target),geometrySHA256:BackupManifest.digest(geometry),
            inputSHA256:BackupManifest.digest(geometry+preimage+target),candidateSHA256:BackupManifest.digest(trial.image),
            startedSHA256:proof.startedSHA256,playedSHA256:proof.playedSHA256,readerSHA256:reader.digest,writerSHA256:writer.digest,
            offsetBytes:0x600000,byteCount:7340032,unitBytes:131072,parentReviewSHA256:parentReviewSHA256,parentOperationID:parentOperationID,
            originalRangeSHA256:menuUpgrade ? BackupManifest.digest(original.active):nil,firstInstall:firstInstall)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];return try encoder.encode(m)
    }
}
