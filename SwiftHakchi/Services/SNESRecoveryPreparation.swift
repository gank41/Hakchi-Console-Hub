import Foundation

protocol SNESPreparationIO: RecoveryProbeIO {
    func stageStock(_ data: Data, id: UUID) async throws
    func readStartup() async throws -> Data
}

/// Covers early USB errors as well as the coordinator's connected-session cleanup.
private actor SNESPreparationConnection: SNESPreparationIO {
    let base: any SNESPreparationIO
    private var closed = false
    init(_ base: any SNESPreparationIO) { self.base = base }
    func inventory() async throws -> [RecoveryProbeUSBDevice] { try await base.inventory() }
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) async throws { try await base.boot(inputs, expected: expected) }
    func connect(expected: RecoveryProbeUSBDevice) async throws { try await base.connect(expected: expected) }
    func observe() async throws -> String { try await base.observe() }
    func readBoot2(_ slot: RecoveryBootSlot) async throws -> RecoveryBoot2Read { try await base.readBoot2(slot) }
    func readBoot1() async throws -> Data { try await base.readBoot1() }
    func readPartitions() async throws -> Data { try await base.readPartitions() }
    func readDataSuperblock() async throws -> Data { try await base.readDataSuperblock() }
    func stageStock(_ data: Data, id: UUID) async throws { try await base.stageStock(data, id: id) }
    func readStartup() async throws -> Data { try await base.readStartup() }
    func disconnect() async { guard !closed else { return }; closed = true; await base.disconnect() }
}

actor SNESRecoveryPreparationService {
    private let session: RecoverySessionCoordinator
    private var busy = false
    init(wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) { session = RecoverySessionCoordinator(wait: wait) }
    func capture(source: SNESPreparationSource, inputs: RecoveryBootInputs, io: any SNESPreparationIO,
                 progress: @escaping RecoveryProgressSink = { _ in }) async throws -> SNESRecoveryPreparation {
        guard !busy else { throw SNESOfflineSource.failure() }; busy = true; defer { busy = false }
        try Task.checkCancellation(); try source.revalidate()
        let connection = SNESPreparationConnection(io)
        do {
            let (context, result) = try await session.run(inputs: inputs, io: connection, progress: progress,
                validateObservation: {
                    let observation = try SNESBackupPolicy.observation($0)
                    try source.requireObservation(observation); return observation
                }) { context in
                guard context.observation.hwid == source.source.expectedHWID else { throw SNESOfflineSource.failure() }
                await progress(.readingCurrentKernel)
                for _ in 0..<2 {
                    try Task.checkCancellation()
                    guard case .image(let bytes) = try await connection.readBoot2(.active), bytes == source.stock else { throw SNESOfflineSource.failure() }
                }
                await progress(.readingBootloader); try Task.checkCancellation()
                guard try await connection.readBoot1() == source.boot1 else { throw SNESOfflineSource.failure() }
                await progress(.checkingPartitions); try Task.checkCancellation()
                guard try await connection.readPartitions() == source.partitions else { throw SNESOfflineSource.failure() }
                let header = try source.validateHeader(await connection.readDataSuperblock())
                try Task.checkCancellation(); try source.revalidate()
                let beforeStage = try SNESBackupPolicy.observation(await connection.observe())
                guard beforeStage.hwid == context.observation.hwid, beforeStage.mounts == context.observation.mounts else { throw SNESOfflineSource.failure() }
                await progress(.stagingStock)
                try await connection.stageStock(source.stock, id: UUID())
                try Task.checkCancellation()
                await progress(.verifying)
                let first = try await Self.read(connection, source: source, stage: .firstCapture)
                let startup: SNESStartupFrame
                do { startup = try SNESStartupFrame(first) }
                catch { throw SNESPreparationFailure(binding: source.source.runtimeBinding, stage: .firstCapture, frame: first) }
                try Task.checkCancellation()
                let second = try await Self.read(connection, source: source, stage: .secondCapture)
                guard second == first else { throw SNESPreparationFailure(binding: source.source.runtimeBinding, stage: .changedCapture, frame: second) }
                let last = try SNESBackupPolicy.observation(await connection.observe())
                guard last.hwid == context.observation.hwid, last.mounts == context.observation.mounts else { throw SNESOfflineSource.failure() }
                try source.revalidate(); try Task.checkCancellation()
                return (startup, header)
            }
            return SNESRecoveryPreparation(source: source, startup: result.0, header: result.1,
                before: context.before, after: context.after, observation: context.observation)
        } catch { await connection.disconnect(); throw error }
    }
    private static func read(_ io: SNESPreparationConnection, source: SNESPreparationSource, stage: SNESPreparationFailure.Stage) async throws -> Data {
        do { return try await io.readStartup() }
        catch let error as SNESStartupTransportFailure {
            throw SNESPreparationFailure(binding: source.source.runtimeBinding, stage: stage, frame: error.frame, stageLog: error.stageLog)
        }
    }
}
