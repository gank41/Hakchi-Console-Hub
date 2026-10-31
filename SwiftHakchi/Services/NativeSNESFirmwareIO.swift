import Foundation

protocol SNESFirmwareShell: Sendable {
    func executeBounded(_ command: String, stdoutLimit: Int, stderrLimit: Int, timeout: Int) async throws -> BoundedSSHExecution
    func uploadExclusive(data: Data, to remotePath: String, timeout: Int) async throws
}
extension SSHService: SNESFirmwareShell {}

struct SNESFirmwareCommandFailure:Error,Sendable {
    let transport:Int,exit:Int,output:Data,errors:Data
    var diagnostic:String {
        let value:[String:Any]=["transport":transport,"exit":exit,"stdoutBase64":Data(output.prefix(4096)).base64EncodedString(),"stderrBase64":Data(errors.prefix(4096)).base64EncodedString()]
        guard let data=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]) else {return "Recovery command diagnostics could not be encoded."}
        return String(decoding:data,as:UTF8.self)
    }
}

/// One recovery connection and one permitted firmware dispatch for its lifetime.
actor NativeSNESFirmwareIO: SNESFirmwareIO {
    private let material: SNESFirmwareMaterial
    private let guardValue: SNESFirmwareGuard
    private let base: any SNESActiveBoot2IO
    private let shell: any SNESFirmwareShell
    private var closed = false, bootRequested = false, connectRequested = false, ready = false
    private var stageRequested = false, staged = false, verifyRequested = false, verified = false, writeRequested = false
    private var attachment: RecoveryProbeUSBDevice?

    init(material: SNESFirmwareMaterial, guard guardValue: SNESFirmwareGuard) throws {
        try guardValue.require(material)
        if material.direction == .install { try SNESColdBootPolicy.require(boot1:material.source.boot1,image:material.trial.image) }
        self.material = material; self.guardValue = guardValue
        let shared = SSHService()
        shell = shared
        base = NativeSNESActiveBoot2IO(source: material.source, helper: material.reader, shell: shared)
    }
    init(material: SNESFirmwareMaterial, guard guardValue: SNESFirmwareGuard, base: any SNESActiveBoot2IO, shell: any SNESFirmwareShell) throws {
        try guardValue.require(material)
        if material.direction == .install { try SNESColdBootPolicy.require(boot1:material.source.boot1,image:material.trial.image) }
        self.material = material; self.guardValue = guardValue; self.base = base; self.shell = shell
    }
    private func check() throws {
        guard !closed else { throw LegacyInspectionError.disconnected }
        try guardValue.validate()
    }
    private func checked<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try check()
        let value = try await operation()
        try check()
        return value
    }
    func inventory() async throws -> [RecoveryProbeUSBDevice] { try await checked { try await self.base.inventory() } }
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) async throws {
        try check()
        guard !bootRequested, !connectRequested else { throw SNESRuntimeBinding.failure() }
        bootRequested = true
        try await checked { try await self.base.boot(inputs, expected: expected) }
    }
    func connect(expected: RecoveryProbeUSBDevice) async throws {
        try check()
        guard !connectRequested else { throw SNESRuntimeBinding.failure() }
        connectRequested = true
        try await checked { try await self.base.connect(expected: expected) }
        attachment = expected
    }
    func observe() async throws -> String { try await checked { try await self.base.observe() } }
    func readBoot2(_ slot: RecoveryBootSlot) async throws -> RecoveryBoot2Read { try await checked { try await self.base.readBoot2(slot) } }
    func readBoot1() async throws -> Data { try await checked { try await self.base.readBoot1() } }
    func readPartitions() async throws -> Data {
        ready = false
        return try await checked { try await self.base.readPartitions() }
    }
    func readDataSuperblock() async throws -> Data {
        ready = false
        let raw = try await checked { try await self.base.readDataSuperblock() }
        _ = try material.source.validateHeader(raw)
        ready = true
        return raw
    }
    func geometry(challenge: UUID) async throws -> Data { try await checked { try await self.base.geometry(challenge: challenge) } }
    func readActive(challenge: UUID) async throws -> Data { try await checked { try await self.base.readActive(challenge: challenge) } }
    private func current() async throws {
        try check()
        guard ready, let expected = attachment else { throw SNESRuntimeBinding.failure() }
        guard try await checked({ try await self.base.inventory() }) == [expected] else { throw SNESRuntimeBinding.failure() }
        let raw = try await checked { try await self.base.observe() }
        try material.source.requireObservation(SNESBackupPolicy.observation(raw))
        guard ready, attachment == expected else { throw SNESRuntimeBinding.failure() }
        try check()
    }
    private func execute(_ command: String, expected: String) async throws {
        try await current()
        let result = try await checked {
            try await self.shell.executeBounded(command, stdoutLimit: 512, stderrLimit: 16384, timeout: 180000)
        }
        guard result.transportCode == 0, result.exitCode == 0,
              result.stdout == Data(expected.utf8), result.stderr.count <= 16384 else {
            throw SNESFirmwareCommandFailure(transport:result.transportCode,exit:result.exitCode,output:Data(result.stdout.prefix(4096)),errors:Data(result.stderr.prefix(4096)))
        }
    }
    func stage() async throws {
        try check()
        guard ready, attachment != nil, !stageRequested, !writeRequested else { throw SNESRuntimeBinding.failure() }
        stageRequested = true
        try await execute(SNESFirmwareCommands.create(material.id), expected: SNESFirmwareCommands.created(material.id))
        let directory = SNESFirmwareCommands.directory(material.id)
        let payload = material.geometry + material.preimage + material.target
        try await current()
        try await checked { try await self.shell.uploadExclusive(data: self.material.writer.bytes, to: directory + "/writer", timeout: 180000) }
        try await current()
        try await checked { try await self.shell.uploadExclusive(data: payload, to: directory + "/input", timeout: 180000) }
        try await execute(SNESFirmwareCommands.checked(material), expected: SNESFirmwareCommands.staged(material))
        staged = true
    }
    func verifyStaged() async throws {
        try check()
        guard staged, !verifyRequested, !writeRequested else { throw SNESRuntimeBinding.failure() }
        verifyRequested = true
        try await execute(SNESFirmwareCommands.invoke(material, writing: false), expected: SNESFirmwareCommands.marker(material, writing: false))
        verified = true
    }
    func replace(_ permit: SNESFirmwareWritePermit) async throws {
        try check()
        guard ready, staged, verified, !writeRequested,
              permit.id == material.id, permit.reviewSHA256 == guardValue.reviewSHA256 else { throw SNESRuntimeBinding.failure() }
        let libraryRoot = try SNESLibraryJournalPolicy.ensureRoot()
        let libraryLease = try SNESLibraryJournal.firmwareLease(hwid: material.trial.expectedHWID, root: libraryRoot)
        defer { try? libraryLease.closeLease() }
        writeRequested = true
        try await execute(SNESFirmwareCommands.invoke(material, writing: true), expected: SNESFirmwareCommands.marker(material, writing: true))
    }
    func disconnect() async {
        guard !closed else { return }
        closed = true; ready = false; attachment = nil
        await base.disconnect()
    }
}
