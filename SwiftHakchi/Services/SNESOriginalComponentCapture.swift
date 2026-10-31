import Foundation

protocol SNESOriginalComponentIO: RecoveryProbeIO { func readComponents() async throws -> Data }

/// Revalidates the immutable source before every operation; closing never depends on source validity.
private actor SNESOriginalComponentConnection: SNESOriginalComponentIO {
    let base: any SNESOriginalComponentIO, source: SNESOriginalComponentSource
    private var closed = false, reads = 0
    private var latest = Data(), log = Data(), stage = "session"
    init(_ base: any SNESOriginalComponentIO, source: SNESOriginalComponentSource) { self.base = base; self.source = source }
    private func check() throws { try Task.checkCancellation(); try source.revalidate() }
    func mark(_ value: String) { stage = value }
    func inventory() async throws -> [RecoveryProbeUSBDevice] { try check(); return try await base.inventory() }
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) async throws { try check(); try await base.boot(inputs, expected: expected) }
    func connect(expected: RecoveryProbeUSBDevice) async throws { try check(); try await base.connect(expected: expected) }
    func observe() async throws -> String { try check(); return try await base.observe() }
    func readBoot2(_ slot: RecoveryBootSlot) async throws -> RecoveryBoot2Read { try check(); return try await base.readBoot2(slot) }
    func readPartitions() async throws -> Data { try check(); return try await base.readPartitions() }
    func readComponents() async throws -> Data {
        reads += 1; stage = reads == 1 ? "first-capture" : "second-capture"
        try check()
        do {
            let frame = try await base.readComponents()
            latest = Data(frame.prefix(SNESOriginalComponentFrame.maximumSize)); return frame
        } catch let failure as SNESStartupTransportFailure {
            latest = Data(failure.frame.prefix(SNESOriginalComponentFrame.maximumSize)); log = Data(failure.stageLog.prefix(16384)); throw failure
        }
    }
    func failure() -> SNESOriginalComponentFailure { .init(source: source, stage: stage, frame: latest, log: log) }
    func disconnect() async { guard !closed else { return }; closed = true; await base.disconnect() }
}
actor SNESOriginalComponentService {
    private let session: RecoverySessionCoordinator
    private var busy = false
    init(wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) { session = RecoverySessionCoordinator(wait: wait) }
    func capture(source: SNESOriginalComponentSource, inputs: RecoveryBootInputs, io: any SNESOriginalComponentIO,
                 progress: @escaping RecoveryProgressSink = { _ in }) async throws -> SNESOriginalComponentResult {
        guard !busy else { throw SNESOriginalComponentFrame.failure() }; busy = true; defer { busy = false }
        try Task.checkCancellation(); try source.revalidate()
        let connection = SNESOriginalComponentConnection(io, source: source)
        do {
            let (context, frame) = try await session.run(inputs: inputs, io: connection, progress: progress,
                validateObservation: {
                    let observed = try SNESBackupPolicy.observation($0)
                    try source.requireObservation(observed); return observed
                }) { context in
                await connection.mark("current-kernel"); await progress(.readingCurrentKernel)
                for _ in 0..<2 {
                    guard case .image(let data) = try await connection.readBoot2(.active), data == source.material.setup.stock else { throw SNESOriginalComponentFrame.failure() }
                }
                await connection.mark("partitions"); await progress(.checkingPartitions)
                guard try await connection.readPartitions() == source.material.source.preparation.source.partitions else { throw SNESOriginalComponentFrame.failure() }
                let before = try SNESBackupPolicy.observation(await connection.observe())
                try source.requireObservation(before)
                guard before.mounts == context.observation.mounts else { throw SNESOriginalComponentFrame.failure() }
                await progress(.verifying)
                let first = try await connection.readComponents()
                try Task.checkCancellation(); try source.revalidate()
                let frame = try SNESOriginalComponentFrame(first); try source.validate(frame)
                let second = try await connection.readComponents()
                guard second == first else { await connection.mark("changed-capture"); throw SNESOriginalComponentFrame.failure() }
                await connection.mark("validation")
                try Task.checkCancellation(); try source.revalidate()
                let last = try SNESBackupPolicy.observation(await connection.observe())
                try source.requireObservation(last)
                guard last.mounts == context.observation.mounts else { throw SNESOriginalComponentFrame.failure() }
                try Task.checkCancellation(); try source.revalidate()
                return frame
            }
            await connection.mark("completion"); try Task.checkCancellation(); try source.revalidate()
            return SNESOriginalComponentResult(source: source, frame: frame, before: context.before, after: context.after, observation: context.observation)
        } catch {
            await connection.disconnect()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw await connection.failure()
        }
    }
}
