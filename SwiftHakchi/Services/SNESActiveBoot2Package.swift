import Foundation
import SwiftHakchiCore

/// A verified physical preimage on the Mac. This type never authorizes a write.
struct SNESActiveBoot2Package:Sendable {
    let directory:URL,active:Data,manifestSHA256:String
    var byteCount:Int {active.count}
    var sha256:String {BackupManifest.digest(active)}
    private init(directory:URL,active:Data,manifestSHA256:String) {
        self.directory=directory;self.active=active;self.manifestSHA256=manifestSHA256
    }
    private struct Record:Codable {
        let schemaVersion:Int,scope:String,complete:Bool
        let firmwareWritten:Bool,firmwareInstallEligible:Bool,firmwareRestoreEligible:Bool,bootEligible:Bool
        let binding:SNESRuntimeBinding,context:SNESDataSnapshotResult.RecoverySessionContextRecord
        let sourcePath:String,sourceManifestSHA256:String,helperSHA256:String,stockImageSHA256:String,boot1SHA256:String,partitionsSHA256:String
        let offsetBytes:Int,byteCount:Int,unitBytes:Int,pageSize:UInt32,pagesPerBlock:UInt32,blockCount:UInt32
        let challenges:[UUID],files:[String:String]
    }
    static func load(directory:URL,source:SNESPreparationSource)throws->Self {
        try Task.checkCancellation();try source.revalidate()
        let dir=try RestoreDirectory(directory),prefix="SNES-Active-Boot2-"
        guard dir.url.lastPathComponent.hasPrefix(prefix),UUID(uuidString:String(dir.url.lastPathComponent.dropFirst(prefix.count))) != nil,
              Set(try dir.names())==Set(["manifest.json","active-range.bin","geometry.bin","data-header.bin"]) else {throw SNESRuntimeBinding.failure()}
        let raw=try dir.read("manifest.json",maximum:65536),m=try JSONDecoder().decode(Record.self,from:raw)
        // Refuse ignored/unknown fields as well as altered eligibility flags.
        let canonical=try JSONSerialization.jsonObject(with:JSONEncoder().encode(m)) as? NSDictionary
        guard canonical?.isEqual(to:try JSONSerialization.jsonObject(with:raw) as? [AnyHashable:Any] ?? [:])==true,
              m.schemaVersion==1,m.scope=="snes-active-boot2-preimage",m.complete,
              !m.firmwareWritten,!m.firmwareInstallEligible,!m.firmwareRestoreEligible,!m.bootEligible,
              m.binding==source.source.runtimeBinding,m.sourceManifestSHA256==source.source.manifestSHA256,
              SNESBoundedReadHelper.accepts(digest:m.helperSHA256),m.stockImageSHA256==BackupManifest.digest(source.stock),
              m.boot1SHA256==BackupManifest.digest(source.boot1),m.partitionsSHA256==BackupManifest.digest(source.partitions),
              m.offsetBytes==0x600000,m.byteCount==7340032,m.unitBytes==131072,
              m.challenges.count==4,Set(m.challenges).count==4 else {throw SNESRuntimeBinding.failure()}
        _=try SNESBoot2Bounds(partitions:source.partitions)
        _=try RecoveryProbePolicy.before([m.context.before])
        guard try RecoveryProbePolicy.after([m.context.after],original:m.context.before)==m.context.after else {throw SNESRuntimeBinding.failure()}
        try source.requireObservation(m.context.observation)
        let active=try dir.read("active-range.bin",maximum:7340032),geometry=try dir.read("geometry.bin",maximum:24),header=try dir.read("data-header.bin",maximum:2048)
        let g=try SNESPhysicalGeometry(geometry)
        guard active.count==7340032,active.prefix(source.stock.count)==source.stock,
              g.pageSize==m.pageSize,g.pagesPerBlock==m.pagesPerBlock,g.blockCount==m.blockCount,
              m.files==["active-range.bin":BackupManifest.digest(active),"geometry.bin":BackupManifest.digest(geometry),"data-header.bin":BackupManifest.digest(header)] else {throw SNESRuntimeBinding.failure()}
        _=try source.validateHeader(Data("SWIFTHAKCHI_DATA_SUPERBLOCK_V1 2048 \(BackupManifest.digest(header))\n".utf8)+header)
        try dir.check();try source.revalidate();try Task.checkCancellation()
        return .init(directory:dir.url,active:active,manifestSHA256:BackupManifest.digest(raw))
    }
    func revalidate(source:SNESPreparationSource)throws {
        let current=try Self.load(directory:directory,source:source)
        guard current.manifestSHA256==manifestSHA256,current.active==active else {throw SNESRuntimeBinding.failure()}
    }
}
