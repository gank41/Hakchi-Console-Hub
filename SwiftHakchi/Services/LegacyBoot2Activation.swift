import Foundation

protocol LegacyBoot2ActivationIO: RecoveryProbeIO {
    func verifyPartitions() async throws
    func stage(legacy: Data, id: UUID) async throws
    func burn(id: UUID, expectedSHA256: String, expectedBytes: Int) async throws
}

/// Reinstates only the exact previously captured custom boot2 on its own NES.
actor LegacyBoot2Activation {
    enum Mode: Sendable { case preflight, write }
    private let session: RecoverySessionCoordinator
    private var busy = false

    init(wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) {
        session = RecoverySessionCoordinator(wait: wait)
    }

    func run(journal: LegacyBoot2ActivationJournal, inputs: RecoveryBootInputs,
             io: any LegacyBoot2ActivationIO, mode: Mode,
             progress: @escaping RecoveryProgressSink = { _ in }) async throws {
        guard !busy else { throw RecoveryProbeError.refused("A legacy boot2 activation is already running.") }
        busy = true; defer { busy = false }
        await progress(.checkingMaterial)
        let material = try await journal.verifiedMaterial()
        let expected: LegacyBoot2ActivationJournal.Phase = mode == .preflight ? .prepared : .preflightVerified
        guard try await journal.phase() == expected else {
            throw RecoveryProbeError.refused("This legacy activation journal cannot start that operation. No retry was dispatched.")
        }
        do {
            _ = try await session.run(inputs: inputs, io: io, progress: progress) { context in
                try Self.check(context.observation, material: material)
                try Task.checkCancellation()
                await progress(.checkingPartitions)
                try await io.verifyPartitions()
                try Task.checkCancellation()
                await progress(.readingCurrentKernel)
                guard case .image(let before) = try await io.readBoot2(.active), before == material.stock else {
                    throw RecoveryProbeError.refused("Active boot2 differs from the reviewed stock image. Do not activate the legacy image; inspect the console and prepare a new plan.")
                }
                try Task.checkCancellation()
                await progress(.stagingLegacy)
                try await io.stage(legacy: material.legacy, id: material.plan.id)
                try Task.checkCancellation()
                try Self.check(RecoveryProbePolicy.observation(await io.observe()), material: material)
                try Task.checkCancellation()
                _ = try await journal.verifiedMaterial()
                if mode == .write {
                    try await journal.append(.burnIntent)
                    try Task.checkCancellation()
                    await progress(.writingLegacy)
                    try await io.burn(id: material.plan.id,
                                      expectedSHA256: material.plan.legacySHA256,
                                      expectedBytes: material.legacy.count)
                    try Task.checkCancellation()
                    await progress(.readingBack)
                    guard case .image(let readback) = try await io.readBoot2(.active), readback == material.legacy else {
                        throw RecoveryProbeError.refused("Active boot2 readback did not match the legacy image. Preserve power, cables and journal; do not retry or reboot.")
                    }
                    try Task.checkCancellation()
                    await progress(.verifying)
                    try Self.check(RecoveryProbePolicy.observation(await io.observe()), material: material)
                }
            }
            try Task.checkCancellation()
            try await journal.append(mode == .preflight ? .preflightVerified : .readbackVerified)
        } catch {
            let failure: LegacyBoot2ActivationJournal.Phase = (try? await journal.phase()) == .burnIntent ? .uncertain : .stoppedBeforeWrite
            _ = await Task.detached { try? await journal.append(failure) }.value
            throw error
        }
    }

    private static func check(_ observation: RecoveryProbeObservation,
                              material: LegacyBoot2ActivationMaterial) throws {
        guard observation.board == "dp-nes", observation.hwid == material.plan.expectedHWID else {
            throw RecoveryProbeError.refused("Recovery board or hardware identity differs from the reviewed legacy NES operation.")
        }
    }
}
