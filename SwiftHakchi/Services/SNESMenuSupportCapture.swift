import Foundation

protocol SNESMenuSupportIO: RecoveryProbeIO {
    func readSupport() async throws -> Data
}
private actor SNESMenuSupportConnection: SNESMenuSupportIO {
    let base: any SNESMenuSupportIO
    private var closed = false
    init(_ base: any SNESMenuSupportIO) { self.base = base }
    func inventory() async throws -> [RecoveryProbeUSBDevice] { try await base.inventory() }
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) async throws { try await base.boot(inputs, expected: expected) }
    func connect(expected: RecoveryProbeUSBDevice) async throws { try await base.connect(expected: expected) }
    func observe() async throws -> String { try await base.observe() }
    func readBoot2(_ slot: RecoveryBootSlot) async throws -> RecoveryBoot2Read { try await base.readBoot2(slot) }
    func readPartitions() async throws -> Data { try await base.readPartitions() }
    func readSupport() async throws -> Data { try await base.readSupport() }
    func disconnect() async { guard !closed else { return }; closed = true; await base.disconnect() }
}
actor SNESMenuSupportService {
    private let session: RecoverySessionCoordinator
    private var busy = false
    init(wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) { session = RecoverySessionCoordinator(wait: wait) }
    func capture(source: SNESMenuSupportSource, inputs: RecoveryBootInputs, io: any SNESMenuSupportIO,
                 progress: @escaping RecoveryProgressSink = { _ in }) async throws -> SNESMenuSupportResult {
        guard !busy else { throw SNESMenuSupportFrame.failure() }; busy = true; defer { busy = false }
        try Task.checkCancellation(); try source.revalidate()
        let connection = SNESMenuSupportConnection(io)
        do {
            let (context, frame) = try await session.run(inputs: inputs, io: connection, progress: progress,
                validateObservation: {
                    let observed = try SNESBackupPolicy.observation($0)
                    try source.preparation.source.requireObservation(observed); return observed
                }) { context in
                await progress(.readingCurrentKernel)
                for _ in 0..<2 {
                    try Task.checkCancellation()
                    guard case .image(let bytes) = try await connection.readBoot2(.active), bytes == source.preparation.source.stock else { throw SNESOfflineSource.failure() }
                }
                await progress(.checkingPartitions)
                guard try await connection.readPartitions() == source.preparation.source.partitions else { throw SNESOfflineSource.failure() }
                try source.revalidate(); try Task.checkCancellation()
                let before = try SNESBackupPolicy.observation(await connection.observe())
                try source.preparation.source.requireObservation(before)
                guard before.mounts == context.observation.mounts else { throw SNESOfflineSource.failure() }
                await progress(.verifying)
                let first = try await Self.read(connection, source: source, stage: .firstCapture)
                var latest = first
                do {
                    let frame: SNESMenuSupportFrame
                    do { frame = try SNESMenuSupportFrame(first); try source.validate(frame) }
                    catch { throw SNESMenuSupportFailure(source: source, stage: .firstCapture, frame: first) }
                    try Task.checkCancellation(); try source.revalidate()
                    let second = try await Self.read(connection, source: source, stage: .secondCapture)
                    latest = second
                    guard second == first else { throw SNESMenuSupportFailure(source: source, stage: .changedCapture, frame: second) }
                    let last = try SNESBackupPolicy.observation(await connection.observe())
                    try source.preparation.source.requireObservation(last)
                    guard last.mounts == context.observation.mounts else { throw SNESOfflineSource.failure() }
                    try Task.checkCancellation(); try source.revalidate()
                    return frame
                } catch is CancellationError { throw CancellationError() }
                catch let failure as SNESMenuSupportFailure { throw failure }
                catch {
                    throw SNESMenuSupportFailure(source: source, stage: .validation, frame: latest,
                        log: Data("Validation after capture stopped. No installation was performed.\n".utf8))
                }
            }
            return SNESMenuSupportResult(source: source, frame: frame, before: context.before, after: context.after, observation: context.observation)
        } catch { await connection.disconnect(); throw error }
    }
    private static func read(_ io: SNESMenuSupportConnection, source: SNESMenuSupportSource, stage: SNESMenuSupportFailure.Stage) async throws -> Data {
        do { return try await io.readSupport() }
        catch let failure as SNESStartupTransportFailure {
            throw SNESMenuSupportFailure(source: source, stage: stage, frame: failure.frame, log: failure.stageLog)
        }
    }
}
