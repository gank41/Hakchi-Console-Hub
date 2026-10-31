import Foundation
import Darwin
import SwiftHakchiCore

struct SNESOneGameCopyPermit:Sendable {
    let id:UUID,materialReviewSHA256:String,challenge:UUID
    fileprivate init(id:UUID,materialReviewSHA256:String,challenge:UUID){self.id=id;self.materialReviewSHA256=materialReviewSHA256;self.challenge=challenge}
    func require(_ material:SNESOneGameMaterial)throws {
        guard id==material.menu.id,materialReviewSHA256==material.reviewSHA256 else {throw SNESOneGameMenu.failure()};try material.validate()
    }
}

enum SNESOneGameJournalPolicy {
    static func root()throws->URL {
        guard let app=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first else {throw RestoreDirectory.failure()}
        return app.appendingPathComponent("SwiftHakchi/GameCopyTransactions/SNES",isDirectory:true).standardizedFileURL
    }
    static func ensureRoot()throws->URL {
        let url=try root();guard url==url.resolvingSymlinksInPath() else {throw RestoreDirectory.failure()}
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);return try RestoreDirectory(url).url
    }
    static func requireOperation(_ url:URL)throws {
        let d=url.standardizedFileURL,prefix="SNESGameCopy-"
        guard d.deletingLastPathComponent()==(try root()),d.lastPathComponent.hasPrefix(prefix),UUID(uuidString:String(d.lastPathComponent.dropFirst(prefix.count))) != nil else {throw SNESOneGameMenu.failure()}
    }
}

struct SNESOneGameMenuTrialPermit:Sendable {
 let id:UUID,materialReviewSHA256:String,challenge:UUID
 fileprivate init(id:UUID,materialReviewSHA256:String,challenge:UUID){self.id=id;self.materialReviewSHA256=materialReviewSHA256;self.challenge=challenge}
 func require(_ m:SNESOneGameMaterial)throws {try m.validate();guard id==m.menu.id,materialReviewSHA256==m.reviewSHA256 else {throw SNESOneGameMenu.failure()}}
}
actor SNESOneGameStageJournal {
    enum Phase:String,Codable,Sendable {case prepared,copyIntent,inactiveVerified,uncertain,failedInactive,menuTrialIntent,menuTrialShown,menuTrialUncertain,menuTrialReturned}
    struct Prepared:Sendable {let operation:URL,reviewSHA256:String}
    struct Saved:Codable {
        let schemaVersion:Int,scope:String,artifactPath:String,materialPlanSHA256:String,materialPlan:Data
        let id:UUID,binding:SNESRuntimeBinding
    }
    private struct Record:Codable {
        let phase:Phase,planSHA256:String,previousSHA256:String?,challenge:UUID?,receipt:Data?,menuManifest:Data?
    }
    private struct State {let phase:Phase,count:Int,lastSHA256:String,intentChallenge:UUID?}
    private let storage:RestoreJournalStorage,material:SNESOneGameMaterial,artifact:URL
    let reviewSHA256:String
    private let plan:Data
    init(operation:URL,reviewSHA256:String,material:SNESOneGameMaterial,artifact:URL)throws {
        guard SNESDataSnapshotChunk.isDigest(reviewSHA256),operation.lastPathComponent=="SNESGameCopy-"+material.menu.id.uuidString else {throw RestoreDirectory.failure()}
        let storage=try RestoreJournalStorage(root:operation.deletingLastPathComponent(),operation:operation)
        let expected=try Self.plan(material:material,artifact:artifact),raw=try storage.operation!.read("plan.json",maximum:131072)
        guard raw==expected,BackupManifest.digest(raw)==reviewSHA256 else {throw RestoreDirectory.failure()}
        self.storage=storage;self.material=material;self.artifact=artifact;self.reviewSHA256=reviewSHA256;plan=raw
        try storage.checkLock();try material.validate()
        try Self.checkOthers(storage,excluding:operation.lastPathComponent,binding:material.accepted.material.trial.candidate.material.binding)
        _=try Self.load(storage.operation!,review:reviewSHA256,expected:raw,menu:material.menu,binding:material.accepted.material.trial.candidate.material.binding)
    }
    static func readSaved(operation:URL,reviewSHA256:String)throws->Saved {
        guard SNESDataSnapshotChunk.isDigest(reviewSHA256) else {throw RestoreDirectory.failure()}
        let d=try RestoreDirectory(operation),raw=try d.read("plan.json",maximum:131072)
        guard BackupManifest.digest(raw)==reviewSHA256 else {throw RestoreDirectory.failure()}
        let saved=try JSONDecoder().decode(Saved.self,from:raw)
        guard saved.schemaVersion==1,saved.scope=="snes-reviewed-inactive-copy",saved.artifactPath.hasPrefix("/"),!saved.artifactPath.contains("\0"),saved.artifactPath.utf8.count<=4096,
              BackupManifest.digest(saved.materialPlan)==saved.materialPlanSHA256,operation.lastPathComponent=="SNESGameCopy-"+saved.id.uuidString else {throw RestoreDirectory.failure()}
        return saved
    }
    static func prepare(material:SNESOneGameMaterial,artifact:URL,root:URL)throws->Prepared {
        try material.validate();let storage=try RestoreJournalStorage(root:root)
        try checkOthers(storage,excluding:nil,binding:material.accepted.material.trial.candidate.material.binding)
        let plan=try plan(material:material,artifact:artifact),review=BackupManifest.digest(plan),name="SNESGameCopy-"+material.menu.id.uuidString
        guard mkdirat(storage.root.fd,name,0o700)==0 else {throw RestoreDirectory.failure()}
        let operation=try RestoreDirectory(storage.root.url.appendingPathComponent(name))
        try storage.write(plan,name:"plan.json",directory:operation)
        try storage.write(encode(Record(phase:.prepared,planSHA256:review,previousSHA256:nil,challenge:nil,receipt:nil,menuManifest:nil)),name:"0000.json",directory:operation)
        try storage.sync(operation);try storage.sync(storage.root);try storage.closeLease()
        return .init(operation:operation.url,reviewSHA256:review)
    }
    func phase()throws->Phase {try state().phase}
    func beginCopy()throws->SNESOneGameCopyPermit {
        let current=try state();guard current.phase == .prepared else {throw SNESOneGameMenu.failure()}
        try material.validate();let challenge=UUID()
        try append(.copyIntent,challenge:challenge,receipt:nil)
        return .init(id:material.menu.id,materialReviewSHA256:material.reviewSHA256,challenge:challenge)
    }
    func verified(receipt:SNESOneGameStageReceipt)throws {
        let current=try state();guard current.phase == .copyIntent,receipt.challenge != current.intentChallenge,!receipt.isPreflight else {throw SNESOneGameMenu.failure()}
        _=try SNESOneGameStageReceipt(receipt.raw,menu:material.menu,binding:material.accepted.material.trial.candidate.material.binding,challenge:receipt.challenge,preflight:false)
        try append(.inactiveVerified,challenge:receipt.challenge,receipt:receipt.raw)
    }
    /// Records a failed inactive folder; it does not accept the menu or permit rewriting this operation.
    func noteInactiveFailure(_ receipt:SNESOneGameInspectionReceipt)throws {
        let current=try state()
        guard current.phase == .uncertain,receipt.challenge != current.intentChallenge,
              !material.accepted.material.trial.candidate.hasMenuSupport,receipt.selectorMissing,!receipt.matchesMenu,receipt.copyLimitReady else {throw SNESOneGameMenu.failure()}
        _=try SNESOneGameInspectionReceipt(receipt.raw,menu:material.menu,binding:material.accepted.material.trial.candidate.material.binding,challenge:receipt.challenge)
        try append(.failedInactive,challenge:receipt.challenge,receipt:receipt.raw,menuManifest:material.menu.manifest)
    }
    func uncertain()throws {guard try state().phase == .copyIntent else {throw SNESOneGameMenu.failure()};try append(.uncertain,challenge:nil,receipt:nil)}
    func beginMenuTrial()throws->SNESOneGameMenuTrialPermit {
        let current=try state()
        // Reserve intent, completion/failure and original-return records before any restart.
        guard [.inactiveVerified,.menuTrialReturned].contains(current.phase),current.count<=61,
              !material.accepted.material.trial.candidate.hasMenuSupport else {throw SNESOneGameMenu.failure()}
        let challenge=UUID();try append(.menuTrialIntent,challenge:challenge,receipt:nil)
        return .init(id:material.menu.id,materialReviewSHA256:material.reviewSHA256,challenge:challenge)
    }
    private func checkTrialReceipt(_ receipt:SNESOneGameMenuTrialReceipt,original:Bool)throws {
        guard receipt.original==original else {throw SNESOneGameMenu.failure()}
        _=try SNESOneGameMenuTrialReceipt(receipt.raw,id:material.menu.id,tree:material.menu.treeSHA256,binding:material.accepted.material.trial.candidate.material.binding,challenge:receipt.challenge,original:original)
    }
    func menuTrialShown(_ receipt:SNESOneGameMenuTrialReceipt)throws {
        let current=try state();guard current.phase == .menuTrialIntent,receipt.challenge != current.intentChallenge else {throw SNESOneGameMenu.failure()}
        try checkTrialReceipt(receipt,original:false);try append(.menuTrialShown,challenge:receipt.challenge,receipt:receipt.raw)
    }
    func menuTrialFailed()throws {
        guard try state().phase == .menuTrialIntent else {throw SNESOneGameMenu.failure()}
        try append(.menuTrialUncertain,challenge:nil,receipt:nil)
    }
    func menuTrialReturned(_ receipt:SNESOneGameMenuTrialReceipt)throws {
        guard [.menuTrialShown,.menuTrialUncertain,.menuTrialIntent].contains(try state().phase) else {throw SNESOneGameMenu.failure()}
        try checkTrialReceipt(receipt,original:true);try append(.menuTrialReturned,challenge:receipt.challenge,receipt:receipt.raw)
    }
    func close()throws {try storage.closeLease()}
    private static func encode<T:Encodable>(_ value:T)throws->Data {let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];return try e.encode(value)}
    private static func plan(material:SNESOneGameMaterial,artifact:URL)throws->Data {
        try material.validate();let d=try RestoreDirectory(artifact),prefix="SNES-One-Game-"
        guard d.url.lastPathComponent.hasPrefix(prefix),UUID(uuidString:String(d.url.lastPathComponent.dropFirst(prefix.count))) != nil,
              Set(try d.names())==Set(["manifest.json","menu.bundle"]),try d.read("manifest.json",maximum:65536)==material.planData(),
              try d.read("menu.bundle",maximum:9*1024*1024)==material.bundle else {throw RestoreDirectory.failure()}
        return try encode(Saved(schemaVersion:1,scope:"snes-reviewed-inactive-copy",artifactPath:d.url.path,materialPlanSHA256:material.reviewSHA256,
            materialPlan:material.planData(),id:material.menu.id,binding:material.accepted.material.trial.candidate.material.binding))
    }
    private func state()throws->State {
        try storage.checkLock();try material.validate()
        guard try Self.plan(material:material,artifact:artifact)==plan else {throw RestoreDirectory.failure()}
        try Self.checkOthers(storage,excluding:storage.operation!.url.lastPathComponent,binding:material.accepted.material.trial.candidate.material.binding)
        return try Self.load(storage.operation!,review:reviewSHA256,expected:plan,menu:material.menu,binding:material.accepted.material.trial.candidate.material.binding)
    }
    private func append(_ phase:Phase,challenge:UUID?,receipt:Data?,menuManifest:Data?=nil)throws {
        let current=try state();guard current.count<64 else {throw RestoreDirectory.failure()}
        try storage.write(Self.encode(Record(phase:phase,planSHA256:reviewSHA256,previousSHA256:current.lastSHA256,challenge:challenge,receipt:receipt,menuManifest:menuManifest)),name:String(format:"%04d.json",current.count),directory:storage.operation!)
        try storage.sync(storage.operation!);try storage.sync(storage.root)
        guard try state().phase==phase else {throw RestoreDirectory.failure()}
    }
    private static func load(_ d:RestoreDirectory,review:String,expected:Data?=nil,menu:SNESOneGameMenu?=nil,binding:SNESRuntimeBinding?=nil)throws->State {
        let raw=try d.read("plan.json",maximum:131072)
        guard BackupManifest.digest(raw)==review,expected.map({$0==raw}) ?? true else {throw RestoreDirectory.failure()}
        let plan=try JSONDecoder().decode(Saved.self,from:raw)
        guard plan.schemaVersion==1,plan.scope=="snes-reviewed-inactive-copy",d.url.lastPathComponent=="SNESGameCopy-"+plan.id.uuidString else {throw RestoreDirectory.failure()}
        guard BackupManifest.digest(plan.materialPlan)==plan.materialPlanSHA256 else {throw RestoreDirectory.failure()}
        let frozen=try JSONDecoder().decode(SNESOneGameMaterial.Plan.self,from:plan.materialPlan)
        try frozen.paths.validate();try plan.binding.validate()
        guard frozen.schemaVersion==1,frozen.scope=="snes-one-game-inactive-copy",!frozen.selectorWillChange,!frozen.firmwareWriteRequested,
              frozen.id==plan.id,frozen.binding==plan.binding,frozen.consoleRoot==SNESOneGameMenu.namespace+"/menus/"+plan.id.uuidString,
              binding.map({$0==plan.binding}) ?? true else {throw RestoreDirectory.failure()}
        let records=try d.names().filter{$0 != "plan.json"};guard (1...64).contains(records.count) else {throw RestoreDirectory.failure()}
        var phase:Phase?,previous:String?,intent:UUID?;var challenges=Set<UUID>()
        for (index,name) in records.enumerated() {
            guard name==String(format:"%04d.json",index) else {throw RestoreDirectory.failure()}
            let bytes=try d.read(name,maximum:98304),r=try JSONDecoder().decode(Record.self,from:bytes)
            guard r.planSHA256==review,r.previousSHA256==previous,
                  let canonical=try JSONSerialization.jsonObject(with:encode(r)) as? NSDictionary,
                  let original=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],canonical.isEqual(to:original) else {throw RestoreDirectory.failure()}
            guard r.phase == .failedInactive || r.menuManifest==nil else {throw RestoreDirectory.failure()}
            if let challenge=r.challenge {guard challenges.insert(challenge).inserted else {throw RestoreDirectory.failure()}}
            switch (phase,r.phase) {
            case (nil,.prepared):guard r.challenge==nil,r.receipt==nil else {throw RestoreDirectory.failure()}
            case (.prepared,.copyIntent):guard let challenge=r.challenge,r.receipt==nil else {throw RestoreDirectory.failure()};intent=challenge
            case (.copyIntent,.uncertain):guard r.challenge==nil,r.receipt==nil else {throw RestoreDirectory.failure()}
            case (.uncertain,.failedInactive):
                guard let challenge=r.challenge,challenge != intent,let receipt=r.receipt,receipt.count<=16384,
                      let manifest=r.menuManifest,menu.map({$0.manifest==manifest}) ?? true else {throw RestoreDirectory.failure()}
                let checked=try SNESOneGameInspectionReceipt(receipt,manifest:manifest,plan:frozen,binding:plan.binding,challenge:challenge)
                guard checked.selectorMissing,!checked.matchesMenu,checked.copyLimitReady else {throw RestoreDirectory.failure()}
            case (.copyIntent,.inactiveVerified):
                guard let challenge=r.challenge,challenge != intent,let receipt=r.receipt,receipt.count<=4096 else {throw RestoreDirectory.failure()}
                if let menu,let binding {_=try SNESOneGameStageReceipt(receipt,menu:menu,binding:binding,challenge:challenge,preflight:false)}
            case (.inactiveVerified,.menuTrialIntent),(.menuTrialReturned,.menuTrialIntent):
                guard let challenge=r.challenge,r.receipt==nil else {throw RestoreDirectory.failure()};intent=challenge
            case (.menuTrialIntent,.menuTrialShown):
                guard let challenge=r.challenge,let receipt=r.receipt else {throw RestoreDirectory.failure()}
                _=try SNESOneGameMenuTrialReceipt(receipt,id:plan.id,tree:frozen.menuTreeSHA256,binding:plan.binding,challenge:challenge,original:false)
            case (.menuTrialIntent,.menuTrialUncertain):
                guard r.challenge==nil,r.receipt==nil else {throw RestoreDirectory.failure()}
            case (.menuTrialShown,.menuTrialReturned),(.menuTrialUncertain,.menuTrialReturned),(.menuTrialIntent,.menuTrialReturned):
                guard let challenge=r.challenge,let receipt=r.receipt else {throw RestoreDirectory.failure()}
                _=try SNESOneGameMenuTrialReceipt(receipt,id:plan.id,tree:frozen.menuTreeSHA256,binding:plan.binding,challenge:challenge,original:true)
            default:throw RestoreDirectory.failure()
            }
            phase=r.phase;previous=BackupManifest.digest(bytes)
        }
        try d.check();return .init(phase:phase!,count:records.count,lastSHA256:previous!,intentChallenge:intent)
    }
    private static func checkOthers(_ s:RestoreJournalStorage,excluding:String?,binding:SNESRuntimeBinding)throws {
        for name in try s.root.names() where name != ".stock-restore.lock" && name != excluding {
            guard name.hasPrefix("SNESGameCopy-"),UUID(uuidString:String(name.dropFirst(13))) != nil else {throw RestoreDirectory.failure()}
            let d=try RestoreDirectory(s.root.url.appendingPathComponent(name)),raw=try d.read("plan.json",maximum:131072),p=try JSONDecoder().decode(Saved.self,from:raw)
            let state=try load(d,review:BackupManifest.digest(raw))
            if p.binding.expectedHWID==binding.expectedHWID,state.phase != .prepared,state.phase != .failedInactive,state.phase != .menuTrialReturned {throw RecoveryProbeError.refused("A previous game copy needs to be checked before starting another. Its saved record is kept on this Mac.")}
        }
    }
}
