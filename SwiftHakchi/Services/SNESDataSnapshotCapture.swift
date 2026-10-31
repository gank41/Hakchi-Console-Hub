import Foundation
import CryptoKit
import SwiftHakchiCore

protocol SNESDataSnapshotIO: RecoveryProbeIO {
    func dataHash(challenge: UUID) async throws -> Data
    func dataChunk(index: Int, challenge: UUID) async throws -> Data
}
extension SNESPreparationSource {
    func dataSnapshotPlan() throws -> SNESDataSnapshotPlan {
        try SNESDataSnapshotPlan(partitionSectors: StockRestorePartitions.dataSectors(String(decoding: partitions, as: UTF8.self)))
    }
}
struct SNESDataSnapshotResult: Sendable {
    let source: SNESPreparationSource, context: RecoverySessionContext, header: Data, chunks: [Data], sha256: String
    struct Manifest: Codable {
        let schemaVersion: Int, complete: Bool, firmwareWritten: Bool, firmwareRestoreEligible: Bool
        let scope: String, binding: SNESRuntimeBinding, context: RecoverySessionContextRecord
        let byteCount: Int, sha256: String, files: [String: String]
    }
    struct RecoverySessionContextRecord: Codable {
        let before: RecoveryProbeUSBDevice, after: RecoveryProbeUSBDevice, observation: RecoveryProbeObservation
        init(_ c: RecoverySessionContext) { before=c.before; after=c.after; observation=c.observation }
    }
    func checkedExport() throws -> (files: [String: Data], manifest: Data) {
        try Task.checkCancellation(); try source.revalidate(); try source.requireObservation(context.observation)
        guard try RecoveryProbePolicy.after([context.after], original: context.before) == context.after else { throw SNESDataSnapshotError.refused }
        let plan = try source.dataSnapshotPlan()
        guard chunks.count == plan.chunkCount, chunks.first?.prefix(2048) == header,
              try source.validateHeader(Data("SWIFTHAKCHI_DATA_SUPERBLOCK_V1 2048 \(BackupManifest.digest(header))\n".utf8)+header) == header else { throw SNESDataSnapshotError.refused }
        var full = SHA256(), files = ["stock.img":source.stock, "boot1.bin":source.boot1, "partitions.txt":source.partitions, "data-header.bin":header]
        for (i,bytes) in chunks.enumerated() {
            try Task.checkCancellation(); guard bytes.count == (try plan.range(i)).count else { throw SNESDataSnapshotError.refused }
            full.update(data:bytes); files[SNESDataSnapshotPlan.name(i)] = bytes
        }
        guard full.finalize().map({ String(format:"%02x",$0) }).joined() == sha256 else { throw SNESDataSnapshotError.refused }
        let m = Manifest(schemaVersion:1, complete:true, firmwareWritten:false, firmwareRestoreEligible:false,
            scope:"snes-current-data-snapshot", binding:source.source.runtimeBinding, context:.init(context),
            byteCount:plan.byteCount, sha256:sha256, files:files.mapValues(BackupManifest.digest))
        let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try source.revalidate(); return (files,try encoder.encode(m))
    }
}
private actor SNESDataSnapshotConnection: SNESDataSnapshotIO {
    let base:any SNESDataSnapshotIO
    private var closed=false
    init(_ base:any SNESDataSnapshotIO) { self.base=base }
    func inventory() async throws -> [RecoveryProbeUSBDevice] { try await base.inventory() }
    func boot(_ inputs:RecoveryBootInputs,expected:RecoveryProbeUSBDevice) async throws { try await base.boot(inputs,expected:expected) }
    func connect(expected:RecoveryProbeUSBDevice) async throws { try await base.connect(expected:expected) }
    func observe() async throws -> String { try await base.observe() }
    func readBoot2(_ slot:RecoveryBootSlot) async throws -> RecoveryBoot2Read { try await base.readBoot2(slot) }
    func readBoot1() async throws -> Data { try await base.readBoot1() }
    func readPartitions() async throws -> Data { try await base.readPartitions() }
    func readDataSuperblock() async throws -> Data { try await base.readDataSuperblock() }
    func dataHash(challenge:UUID) async throws -> Data { try await base.dataHash(challenge:challenge) }
    func dataChunk(index:Int,challenge:UUID) async throws -> Data { try await base.dataChunk(index:index,challenge:challenge) }
    func disconnect() async { guard !closed else { return }; closed=true; await base.disconnect() }
}
actor SNESDataSnapshotService {
    private let session:RecoverySessionCoordinator
    private var busy=false
    init(wait:@escaping @Sendable () async throws -> Void={ try await Task.sleep(for:.seconds(1)) }) { session=RecoverySessionCoordinator(wait:wait) }
    func capture(source:SNESPreparationSource,inputs:RecoveryBootInputs,io:any SNESDataSnapshotIO,
        progress:@escaping RecoveryProgressSink={ _ in },detail:@escaping @Sendable (String) async -> Void={ _ in }) async throws -> SNESDataSnapshotResult {
        guard !busy else { throw LegacyInspectionError.busy }; busy=true; defer { busy=false }
        let validate:@Sendable () throws -> Void = { try Task.checkCancellation(); try source.revalidate() }
        try validate(); let plan=try source.dataSnapshotPlan(), connection=SNESDataSnapshotConnection(io)
        do {
            let (context,value)=try await session.run(inputs:inputs,io:connection,progress:progress,validateObservation:{
                let o=try SNESBackupPolicy.observation($0); try source.requireObservation(o); return o
            }) { context in
                try validate(); await progress(.readingCurrentKernel); try validate()
                for _ in 0..<2 { guard case .image(let bytes)=try await connection.readBoot2(.active), bytes==source.stock else { throw SNESDataSnapshotError.refused }; try validate() }
                await progress(.readingBootloader); try validate()
                guard try await connection.readBoot1()==source.boot1 else { throw SNESDataSnapshotError.refused }; try validate()
                await progress(.checkingPartitions); try validate()
                guard try await connection.readPartitions()==source.partitions else { throw SNESDataSnapshotError.refused }; try validate()
                let header=try source.validateHeader(await connection.readDataSuperblock()); try validate()
                let before=try SNESBackupPolicy.observation(await connection.observe()); try validate()
                guard before.hwid==context.observation.hwid, before.mounts==context.observation.mounts else { throw SNESDataSnapshotError.refused }
                let firstID=UUID(), firstHash=try await connection.dataHash(challenge:firstID); try validate()
                let expected=try SNESDataSnapshotChunk.fullHash(firstHash,challenge:firstID,count:plan.byteCount)
                var chunks:[Data]=[], full=SHA256()
                for i in 0..<plan.chunkCount {
                    await detail("Copying console data to this Mac: part \(i+1) of \(plan.chunkCount)"); try validate()
                    guard try await connection.inventory()==[context.after] else { throw SNESDataSnapshotError.refused }; try validate()
                    let id=UUID(), raw=try await connection.dataChunk(index:i,challenge:id); try validate()
                    let chunk=try SNESDataSnapshotChunk(frame:raw,challenge:id,index:i,count:plan.range(i).count)
                    if i==0 { guard chunk.bytes.prefix(2048)==header else { throw SNESDataSnapshotError.refused } }
                    full.update(data:chunk.bytes); chunks.append(chunk.bytes)
                    guard try await connection.inventory()==[context.after] else { throw SNESDataSnapshotError.refused }; try validate()
                }
                await progress(.verifying); try validate()
                let lastID=UUID(), lastHash=try await connection.dataHash(challenge:lastID); try validate()
                guard try SNESDataSnapshotChunk.fullHash(lastHash,challenge:lastID,count:plan.byteCount)==expected,
                      full.finalize().map({ String(format:"%02x",$0) }).joined()==expected else { throw SNESDataSnapshotError.refused }
                guard try source.validateHeader(await connection.readDataSuperblock())==header,
                      try await connection.readPartitions()==source.partitions else { throw SNESDataSnapshotError.refused }; try validate()
                let after=try SNESBackupPolicy.observation(await connection.observe()); try validate()
                guard after.hwid==context.observation.hwid, after.mounts==context.observation.mounts,
                      try await connection.inventory()==[context.after] else { throw SNESDataSnapshotError.refused }; try validate()
                return (header,chunks,expected)
            }
            try validate(); return .init(source:source,context:context,header:value.0,chunks:value.1,sha256:value.2)
        } catch { await connection.disconnect(); throw error }
    }
}
