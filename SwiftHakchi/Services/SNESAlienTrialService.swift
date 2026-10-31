import Foundation

protocol SNESAlienTrialIO: Sendable {
    func inventory() async throws -> [RecoveryProbeUSBDevice]
    func boot(expected: RecoveryProbeUSBDevice) async throws
    func connect(expected: RecoveryProbeUSBDevice) async throws
    func checkpoint(challenge: UUID) async throws -> Data
    func launch(_ request: SNESAlienTrialLaunchRequest) async throws
    func report(challenge: UUID) async throws -> Data
    func diagnostics() async throws -> Data
    func disconnect() async
}
struct SNESAlienTrialFailure: Error, Sendable {
    let stage: String, cause: String, diagnostics: Data
}
struct SNESAlienTrialResult: Sendable {
    let checkpointDirectory: URL, report: SNESAlienTrialReport
}
actor SNESAlienTrialService {
    private var busy = false
    private let wait: @Sendable () async throws -> Void
    init(wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) { self.wait = wait }
    func start(trial: PreparedSNESAlienTrial, store: RecoveryBootSnapshotStore, io: any SNESAlienTrialIO) async throws -> SNESAlienTrialResult {
        guard !busy else { throw LegacyInspectionError.busy }; busy = true; defer { busy = false }
        func validate() throws { try Task.checkCancellation(); try trial.validateCurrent(); try Task.checkCancellation() }
        var connected = false, stage = "recovery-connection"
        do {
            try validate()
            let before = try RecoveryProbePolicy.before(await io.inventory())
            try validate(); stage = "temporary-startup-requested"
            try await io.boot(expected: before); try validate()
            stage = "awaiting-trial-usb"
            var after: RecoveryProbeUSBDevice?
            for _ in 0..<60 {
                try validate()
                after = try SNESOriginalMenuUSBPolicy.after(await io.inventory(), original: before)
                if after != nil { break }
                try await wait()
            }
            guard let after else { throw SNESRuntimeBinding.failure() }
            try validate(); guard try await io.inventory() == [after] else { throw SNESRuntimeBinding.failure() }
            stage = "opening-connection"
            try await io.connect(expected: after); connected = true; try validate()
            stage = "pre-launch-checkpoint"
            let challenge = UUID(), raw = try await io.checkpoint(challenge: challenge)
            try validate()
            let checkpoint = SNESAlienTrialCheckpoint(before: before, after: after, challenge: challenge, report: raw)
            let request = try await checkpoint.persistForLaunch(trial: trial, store: store)
            try validate(); try request.validateCurrent()
            guard try await io.inventory() == [after] else { throw SNESRuntimeBinding.failure() }
            stage = "launching-trial"
            try await io.launch(request); try validate()
            // The fixed target report waits a bounded time for the launcher.
            // A missing report is a failure, not a reason to retry the launch.
            stage = "emulator-report"
            let reportChallenge = UUID(), response = try await io.report(challenge: reportChallenge)
            guard let nonce = UUID(uuidString: trial.expectation.nonce) else { throw SNESRuntimeBinding.failure() }
            let report = try SNESAlienTrialReport(response, nonce: nonce, challenge: reportChallenge,
                expectedExecutableSHA256: trial.frontendSHA256)
            try validate(); guard try await io.inventory() == [after] else { throw SNESRuntimeBinding.failure() }
            await io.disconnect(); return SNESAlienTrialResult(checkpointDirectory: request.checkpointDirectory, report: report)
        } catch {
            var logs = Data()
            if connected && !Task.isCancelled && !(error is CancellationError) {
                if let data = try? await io.diagnostics(), data.count <= 65536,
                   (try? SNESOriginalMenuDiagnostics(data, nonce: trial.expectation.nonce)) != nil { logs = data }
            }
            await io.disconnect()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let sanitized = String(error.localizedDescription.unicodeScalars.prefix(512).map { (32...126).contains($0.value) ? Character($0) : " " })
            throw SNESAlienTrialFailure(stage: stage, cause: sanitized, diagnostics: logs)
        }
    }
}
