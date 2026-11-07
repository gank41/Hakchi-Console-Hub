import Foundation
import CryptoKit
import SwiftHakchiCore

struct SNESDataSnapshotReceipt: Sendable {
    let directory: URL
    let manifestSHA256: String
}

/// Checked Mac bytes; this type has no write, erase, boot or restore operation.
struct SNESDataSnapshotPackage: Sendable {
    let directory:URL, byteCount:Int, sha256:String
    let binding:SNESRuntimeBinding
    private let receipt:Data, hardwareID:String
    private let validatedSource: SNESPreparationSource?
    var manifestSHA256: String { BackupManifest.digest(receipt) }
    private init(directory:URL,byteCount:Int,sha256:String,receipt:Data,hardwareID:String,binding:SNESRuntimeBinding,validatedSource:SNESPreparationSource?) {
        self.directory=directory; self.byteCount=byteCount; self.sha256=sha256; self.receipt=receipt; self.hardwareID=hardwareID; self.binding=binding; self.validatedSource=validatedSource
    }
    func revalidate() throws {
        let checked=try Self.loadChecked(directory:directory,expectedHWID:hardwareID,expectedManifestSHA256:manifestSHA256,source:validatedSource)
        guard checked.receipt==receipt,checked.byteCount==byteCount,checked.sha256==sha256 else { throw SNESDataSnapshotError.refused }
    }
    /// Match an independently saved data snapshot to the exact setup it will protect.
    static func load(receipt: SNESDataSnapshotReceipt, source: SNESPreparationSource) throws -> Self {
        try loadChecked(directory:receipt.directory,expectedHWID:source.source.expectedHWID,expectedManifestSHA256:receipt.manifestSHA256,source:source)
    }
    static func load(directory:URL,expectedHWID:String) throws -> Self {
        try loadChecked(directory:directory,expectedHWID:expectedHWID,expectedManifestSHA256:nil,source:nil)
    }
    private static func loadChecked(directory:URL,expectedHWID:String,expectedManifestSHA256:String?,source:SNESPreparationSource?) throws -> Self {
        try Task.checkCancellation(); try source?.revalidate()
        let dir=try RestoreDirectory(directory), prefix="SNES-Current-Data-"
        guard dir.url.lastPathComponent.hasPrefix(prefix),UUID(uuidString:String(dir.url.lastPathComponent.dropFirst(prefix.count))) != nil else { throw SNESDataSnapshotError.refused }
        let receipt=try dir.read("manifest.json",maximum:65536)
        if let expectedManifestSHA256 {
            guard SNESDataSnapshotChunk.isDigest(expectedManifestSHA256),BackupManifest.digest(receipt)==expectedManifestSHA256 else {throw SNESDataSnapshotError.refused}
        }
        let m=try JSONDecoder().decode(SNESDataSnapshotResult.Manifest.self,from:receipt)
        try m.binding.validate(); try SNESBackupPolicy.requireReadOnlyObservation(m.context.observation)
        try source?.requireObservation(m.context.observation)
        guard m.schemaVersion==1,m.complete,!m.firmwareWritten,!m.firmwareRestoreEligible,m.scope=="snes-current-data-snapshot",
              m.binding.expectedHWID==expectedHWID.lowercased(),m.context.observation.hwid==m.binding.expectedHWID,
              try RecoveryProbePolicy.after([m.context.after],original:m.context.before)==m.context.after else { throw SNESDataSnapshotError.refused }
        let partitions=try dir.read("partitions.txt",maximum:16384)
        let plan=try SNESDataSnapshotPlan(partitionSectors:StockRestorePartitions.dataSectors(String(decoding:partitions,as:UTF8.self)))
        let chunkNames=Set((0..<plan.chunkCount).map(SNESDataSnapshotPlan.name))
        let names=chunkNames.union(["stock.img","boot1.bin","partitions.txt","data-header.bin"])
        guard m.byteCount==plan.byteCount,SNESDataSnapshotChunk.isDigest(m.sha256),Set(m.files.keys)==names,
              Set(try dir.names())==names.union(["manifest.json"]) else { throw SNESDataSnapshotError.refused }
        let stock=try dir.read("stock.img"), boot1=try dir.read("boot1.bin",maximum:RecoveryBoot1Read.maximumSize)
        let header=try dir.read("data-header.bin",maximum:2048)
        guard stock.count==2736128,BackupManifest.digest(stock)==SNESOfflineSource.stockSHA256,!boot1.isEmpty,header.count==2048 else { throw SNESDataSnapshotError.refused }
        let parsed=try SNESStorageHeader(frame:Data("SWIFTHAKCHI_DATA_SUPERBLOCK_V1 2048 \(BackupManifest.digest(header))\n".utf8)+header,partitionSectors:UInt64(plan.byteCount/512))
        guard parsed.summary.isClean else { throw SNESDataSnapshotError.refused }
        if let source {
            let frame=Data("SWIFTHAKCHI_DATA_SUPERBLOCK_V1 2048 \(BackupManifest.digest(header))\n".utf8)+header
            guard m.binding==source.source.runtimeBinding,plan.byteCount == (try source.dataSnapshotPlan()).byteCount,
                  stock==source.stock,boot1==source.boot1,partitions==source.partitions,
                  try source.validateHeader(frame)==header else {throw SNESDataSnapshotError.refused}
        }
        for (name,bytes) in ["stock.img":stock,"boot1.bin":boot1,"partitions.txt":partitions,"data-header.bin":header] {
            guard m.files[name]==BackupManifest.digest(bytes) else { throw SNESDataSnapshotError.refused }
        }
        var full=SHA256()
        for i in 0..<plan.chunkCount {
            try Task.checkCancellation(); let name=SNESDataSnapshotPlan.name(i)
            let bytes=try dir.read(name,maximum:SNESDataSnapshotPlan.maximumChunkBytes)
            guard bytes.count==(try plan.range(i)).count,m.files[name]==BackupManifest.digest(bytes),i != 0 || bytes.prefix(2048)==header else { throw SNESDataSnapshotError.refused }
            full.update(data:bytes)
        }
        guard full.finalize().map({ String(format:"%02x",$0) }).joined()==m.sha256 else { throw SNESDataSnapshotError.refused }
        try dir.check(); try source?.revalidate(); try dir.check()
        return .init(directory:dir.url,byteCount:plan.byteCount,sha256:m.sha256,receipt:receipt,hardwareID:expectedHWID.lowercased(),binding:m.binding,validatedSource:source)
    }
}
