import Foundation

actor NativeSNESMenuSupportIO: SNESMenuSupportIO {
    private let shell: SSHService
    private let recovery: NativeRecoveryProbeIO
    private let source: SNESMenuSupportSource
    init(source: SNESMenuSupportSource) {
        self.source = source
        let shell = SSHService(); self.shell = shell
        recovery = NativeRecoveryProbeIO(shell: shell, observationCommand: SNESBackupPolicy.command)
    }
    func inventory() async throws -> [RecoveryProbeUSBDevice] { try await recovery.inventory() }
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) async throws { try await recovery.boot(inputs, expected: expected) }
    func connect(expected: RecoveryProbeUSBDevice) async throws { try await recovery.connect(expected: expected) }
    func observe() async throws -> String { try await recovery.observe() }
    func readBoot2(_ slot: RecoveryBootSlot) async throws -> RecoveryBoot2Read { try await recovery.readBoot2(slot) }
    func readPartitions() async throws -> Data { try await recovery.readPartitions() }
    func readSupport() async throws -> Data {
        try Task.checkCancellation(); try source.revalidate()
        try source.preparation.source.requireObservation(SNESBackupPolicy.observation(await recovery.observe()))
        let response: BoundedSSHExecution
        do {
            response = try await shell.executeBounded(SNESMenuSupportCommand.read, stdoutLimit: SNESMenuSupportFrame.maximumSize,
                                                       stderrLimit: 16384, timeout: 120000)
        } catch is CancellationError { throw CancellationError() }
        catch { throw SNESStartupTransportFailure(frame: Data(), stageLog: Data("Support connection stopped before a response was received.\n".utf8)) }
        guard response.transportCode == 0, response.exitCode == 0,
              response.stdout.count <= SNESMenuSupportFrame.maximumSize, response.stderr.count <= 16384 else {
            throw SNESStartupTransportFailure(frame: Data(response.stdout.prefix(SNESMenuSupportFrame.maximumSize)), stageLog: Data(response.stderr.prefix(16384)))
        }
        try Task.checkCancellation(); return response.stdout
    }
    func disconnect() async { await recovery.disconnect() }
}
