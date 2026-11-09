import Foundation
import CryptoKit
import SwiftHakchiCore

protocol SNESDataHashIO: RecoveryProbeIO {
    func dataHash(challenge: UUID) async throws -> Data
}
protocol SNESDataSnapshotIO: SNESDataHashIO {
    func dataChunk(index: Int, challenge: UUID) async throws -> Data
}
/// Evidence of a completed check in one live session; not a persistent write permit.
struct SNESDataSnapshotSessionCheck: Sendable {
    let backup: SNESDataSnapshotReceipt
    let dataSHA256: String
}
/// An accepted installed image, independently of whether another upgrade exists.
/// This is read-only evidence; it never grants permission to write firmware.
struct SNESDataSnapshotInstalledStartup: Sendable {
    private let accepted: SNESFirmwareAcceptedInstall
    private let checked: SNESFirmwareGuard

    init(accepted: SNESFirmwareAcceptedInstall) throws {
        try accepted.history.validate()
        let checked = try SNESFirmwareGuard.prepare(accepted.material)
        guard accepted.material.direction == .install, checked.reviewSHA256 == accepted.reviewSHA256 else { throw SNESDataSnapshotError.refused }
        try accepted.history.validate(); try checked.require(accepted.material)
        self.accepted = accepted; self.checked = checked
    }
    var material: SNESFirmwareMaterial { accepted.material }
    func validate() throws {
        try accepted.history.validate(); try checked.require(accepted.material); try accepted.history.validate()
    }
}
struct SNESDataSnapshotPostSaveError: Error, LocalizedError, Sendable {
    let location: URL
    let backupVerified: Bool
    var errorDescription: String? {
        if backupVerified {
            return "A backup at \(location.path) was verified, but the recovery session was not accepted. Keep the backup for inspection. No firmware was installed."
        }
        return "The save operation reported \(location.path), but the app could not verify a backup there. Preserve any files for inspection. No firmware was installed."
    }
}
private actor SNESDataSnapshotSavedReceipt {
    private var receipt: SNESDataSnapshotReceipt?
    private var verified = false
    func set(_ value: SNESDataSnapshotReceipt) { receipt = value }
    func markVerified() { verified = true }
    func get() -> (SNESDataSnapshotReceipt,Bool)? { receipt.map { ($0,verified) } }
}
extension SNESPreparationSource {
    func dataSnapshotPlan() throws -> SNESDataSnapshotPlan {
        try SNESDataSnapshotPlan(partitionSectors: StockRestorePartitions.dataSectors(String(decoding: partitions, as: UTF8.self)))
    }
}
/// Call only inside the coordinator's active recovery session. The context is not
/// itself a session capability; this comparison is not an approval or write permit.
enum SNESDataSnapshotLiveCheck {
    static func verify(package: SNESDataSnapshotPackage, source: SNESPreparationSource,
                       context: RecoverySessionContext, header: Data,
                       connection: any SNESDataHashIO) async throws {
        let plan = try source.dataSnapshotPlan()
        let receipt = SNESDataSnapshotReceipt(directory: package.directory, manifestSHA256: package.manifestSHA256)
        let checked = try SNESDataSnapshotPackage.load(receipt: receipt, source: source)
        guard checked.sha256 == package.sha256, checked.byteCount == package.byteCount,
              checked.binding == source.source.runtimeBinding, checked.byteCount == plan.byteCount else { throw SNESDataSnapshotError.refused }
        let checkLive: @Sendable () async throws -> Void = {
            try Task.checkCancellation(); try source.revalidate()
            guard try await connection.inventory() == [context.after] else { throw SNESDataSnapshotError.refused }
            let observation = try SNESBackupPolicy.observation(await connection.observe())
            try source.requireObservation(observation)
            guard observation.hwid == context.observation.hwid, observation.mounts == context.observation.mounts,
                  try await connection.inventory() == [context.after],
                  try await connection.readPartitions() == source.partitions,
                  try source.validateHeader(await connection.readDataSuperblock()) == header,
                  try await connection.inventory() == [context.after] else { throw SNESDataSnapshotError.refused }
            try Task.checkCancellation(); try source.revalidate()
        }
        try await checkLive()
        let challenge = UUID(), frame = try await connection.dataHash(challenge: challenge)
        guard try SNESDataSnapshotChunk.fullHash(frame, challenge: challenge, count: plan.byteCount) == checked.sha256 else { throw SNESDataSnapshotError.refused }
        try checked.revalidate(); try await checkLive()
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
    func capture(source:SNESPreparationSource,inputs:RecoveryBootInputs,io:any SNESDataSnapshotIO, installedParent:SNESMenuStartupParent? = nil, installedStartup:SNESDataSnapshotInstalledStartup? = nil,
        progress:@escaping RecoveryProgressSink={ _ in },detail:@escaping @Sendable (String) async -> Void={ _ in }) async throws -> SNESDataSnapshotResult {
        try await captureInSession(source:source,inputs:inputs,io:io,installedParent:installedParent,installedStartup:installedStartup,progress:progress,detail:detail) { result, _ in result }
    }
    /// Save and verify a new backup before the coordinator closes its one recovery session.
    /// If a store throws before returning a receipt, it must carry any known saved path in its error.
    func captureAndSave(source:SNESPreparationSource,inputs:RecoveryBootInputs,io:any SNESDataSnapshotIO, installedParent:SNESMenuStartupParent? = nil, installedStartup:SNESDataSnapshotInstalledStartup? = nil,
        progress:@escaping RecoveryProgressSink={ _ in },detail:@escaping @Sendable (String) async -> Void={ _ in },
        save:@escaping @Sendable (SNESDataSnapshotResult) async throws -> SNESDataSnapshotReceipt) async throws -> SNESDataSnapshotSessionCheck {
        let saved = SNESDataSnapshotSavedReceipt()
        do {
            return try await captureInSession(source:source,inputs:inputs,io:io,installedParent:installedParent,installedStartup:installedStartup,progress:progress,detail:detail) { result, connection in
                let expectedManifest = BackupManifest.digest(try result.checkedExport().manifest)
                await detail("Saving and checking the console backup on this Mac")
                let receipt = try await save(result)
                await saved.set(receipt)
                guard receipt.manifestSHA256 == expectedManifest else { throw SNESDataSnapshotError.refused }
                let package = try SNESDataSnapshotPackage.load(receipt:receipt,source:source)
                let plan = try source.dataSnapshotPlan(), context = result.context
                guard package.sha256 == result.sha256, package.byteCount == plan.byteCount else { throw SNESDataSnapshotError.refused }
                await saved.markVerified()
                await progress(.verifying)
                try await SNESDataSnapshotLiveCheck.verify(package: package, source: source, context: context,
                                                           header: result.header, connection: connection)
                return SNESDataSnapshotSessionCheck(backup:receipt,dataSHA256:package.sha256)
            }
        } catch {
            if let (receipt, verified) = await saved.get() { throw SNESDataSnapshotPostSaveError(location:receipt.directory,backupVerified:verified) }
            throw error
        }
    }
    private static func expectedStartup(source: SNESPreparationSource, installedParent: SNESMenuStartupParent?, installedStartup: SNESDataSnapshotInstalledStartup?) throws -> Data {
        try source.revalidate()
        guard installedParent == nil || installedStartup == nil else { throw SNESDataSnapshotError.refused }
        try installedParent?.validate(); try installedStartup?.validate()
        guard let installed = installedParent?.installed ?? installedStartup?.material else { return source.stock }
        let original = installed.source
        guard installed.direction == .install, installedParent.map({ $0.activeImage == installed.targetImage }) ?? true,
              original.source.runtimeBinding == source.source.runtimeBinding,
              original.source.directoryURL == source.source.directoryURL,
              original.source.manifestSHA256 == source.source.manifestSHA256,
              original.stock == source.stock, original.boot1 == source.boot1,
              original.partitions == source.partitions, original.header == source.header else { throw SNESDataSnapshotError.refused }
        try installedParent?.validate(); try installedStartup?.validate(); return installed.targetImage
    }
    private func captureInSession<Value:Sendable>(source:SNESPreparationSource,inputs:RecoveryBootInputs,io:any SNESDataSnapshotIO,
        installedParent:SNESMenuStartupParent?, installedStartup:SNESDataSnapshotInstalledStartup?, progress:@escaping RecoveryProgressSink,detail:@escaping @Sendable (String) async -> Void,
        finish:@escaping @Sendable (SNESDataSnapshotResult,SNESDataSnapshotConnection) async throws -> Value) async throws -> Value {
        guard !busy else { throw LegacyInspectionError.busy }; busy=true; defer { busy=false }
        let validate:@Sendable () throws -> Void = { try Task.checkCancellation(); try source.revalidate(); try installedParent?.validate(); try installedStartup?.validate() }
        try validate(); let startup=try Self.expectedStartup(source:source,installedParent:installedParent,installedStartup:installedStartup)
        let plan=try source.dataSnapshotPlan(), connection=SNESDataSnapshotConnection(io)
        do {
            let (context,value)=try await session.run(inputs:inputs,io:connection,progress:progress,validateObservation:{
                let o=try SNESBackupPolicy.observation($0); try source.requireObservation(o); return o
            }) { context in
                try validate(); await progress(.readingCurrentKernel); try validate()
                for _ in 0..<2 { guard case .image(let bytes)=try await connection.readBoot2(.active), bytes==startup else { throw SNESDataSnapshotError.refused }; try validate() }
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
                guard case .image(let beforeFinish)=try await connection.readBoot2(.active), beforeFinish==startup else { throw SNESDataSnapshotError.refused }
                try validate()
                let result = SNESDataSnapshotResult(source:source,context:context,header:header,chunks:chunks,sha256:expected)
                let value = try await finish(result,connection)
                guard case .image(let afterFinish)=try await connection.readBoot2(.active), afterFinish==startup else { throw SNESDataSnapshotError.refused }
                try validate(); return value
            }
            _ = context; try validate(); return value
        } catch { await connection.disconnect(); throw error }
    }
}
