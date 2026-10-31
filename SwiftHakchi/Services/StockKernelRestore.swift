import Foundation

protocol StockRestoreIO: RecoveryProbeIO {
    func verifyPartitions() async throws
    func stage(stock: Data, id: UUID) async throws
    func burn(id: UUID, expectedSHA256: String, expectedBytes: Int) async throws
}
actor StockKernelRestore {
    enum Mode: Sendable { case preflight, write }
    private let session: RecoverySessionCoordinator
    private var busy = false
    init(wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) {
        session = RecoverySessionCoordinator(wait: wait)
    }
    func run(journal: StockRestoreJournal, inputs: RecoveryBootInputs, io: any StockRestoreIO, mode: Mode, progress: @escaping RecoveryProgressSink = { _ in }) async throws {
        guard !busy else { throw RecoveryProbeError.refused("A stock restore operation is already running.") }
        busy = true; defer { busy = false }
        // This gate occurs before inventory, bootstrap, stage or any device access.
        await progress(.checkingMaterial)
        let material = try await journal.verifiedMaterial()
        let expected: StockRestoreJournal.Phase = mode == .preflight ? .prepared : .preflightVerified
        guard try await journal.phase() == expected else { throw RecoveryProbeError.refused("This journal cannot start that operation. No retry was dispatched.") }
        do {
            _ = try await session.run(inputs: inputs, io: io, progress:progress) { context in
                try Self.check(context.observation, material: material)
                try Task.checkCancellation()
                await progress(.checkingPartitions)
                try await io.verifyPartitions()
                try Task.checkCancellation()
                await progress(.readingCurrentKernel)
                guard case .image(let before) = try await io.readBoot2(.active), before == material.preimage else {
                    throw RecoveryProbeError.refused("Active boot2 differs from the reviewed preimage; prepare a fresh snapshot before proceeding.")
                }
                try Task.checkCancellation()
                await progress(.stagingStock)
                try await io.stage(stock: material.stock, id: material.plan.id)
                try Task.checkCancellation()
                try Self.check(RecoveryProbePolicy.observation(await io.observe()), material: material)
                try Task.checkCancellation()
                // Re-open and validate frozen materials and journal immediately before intent.
                _ = try await journal.verifiedMaterial()
                if mode == .write {
                    try await journal.append(.burnIntent)
                    try Task.checkCancellation()
                    await progress(.writingStock)
                    try await io.burn(id: material.plan.id, expectedSHA256: material.plan.stockSHA256, expectedBytes: material.stock.count)
                    try Task.checkCancellation()
                    await progress(.readingBack)
                    guard case .image(let readback) = try await io.readBoot2(.active), readback == material.stock else {
                        throw RecoveryProbeError.refused("Written boot2 readback did not match the exact stock bytes. The outcome is uncertain; preserve power, cables and journal.")
                    }
                    try Task.checkCancellation()
                    await progress(.verifying)
                    try Self.check(RecoveryProbePolicy.observation(await io.observe()), material: material)
                }
            }
            try Task.checkCancellation()
            try await journal.append(mode == .preflight ? .preflightVerified : .readbackVerified)
        } catch {
            // Cancellation must not prevent recording uncertainty. A failed append leaves
            // the durable intent/partial record as the conservative recovery evidence.
            let failurePhase: StockRestoreJournal.Phase = (try? await journal.phase()) == .burnIntent ? .uncertain : .stoppedBeforeWrite
            _ = await Task.detached { try? await journal.append(failurePhase) }.value
            throw error
        }
    }
    private static func check(_ observation: RecoveryProbeObservation, material: StockRestoreMaterial) throws {
        guard observation.board == "dp-nes", observation.hwid == material.plan.expectedHWID else {
            throw RecoveryProbeError.refused("This recovery board or hardware identity does not match the reviewed NES operation.")
        }
    }
}
