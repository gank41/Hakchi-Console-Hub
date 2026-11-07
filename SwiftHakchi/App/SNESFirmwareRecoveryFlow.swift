import Foundation
import Combine

/// Guides a read-only inspection of an update whose result is uncertain.
@MainActor final class SNESFirmwareRecoveryFlow: ObservableObject {
    enum Phase { case ready, checking, complete, failed }
    @Published private(set) var phase: Phase = .ready
    @Published private(set) var result: SNESFirmwareInspectionResult.Classification?
    @Published private(set) var error: String?
    private let operation: () async throws -> SNESFirmwareInspectionResult.Classification

    init(phase: SNESFirmwareJournal.Phase, inspect: @escaping () async throws -> SNESFirmwareInspectionResult.Classification) throws {
        guard phase == .writeIntent || phase == .uncertain else { throw SNESRuntimeBinding.failure() }
        operation = inspect
    }

    func inspect(ready: Bool) async {
        guard phase == .ready, ready else { return }
        phase = .checking
        do { result = try await operation(); phase = .complete }
        catch { self.error = error.localizedDescription; phase = .failed }
    }
}
