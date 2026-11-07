import Foundation
import Combine

/// Guides only the first startup update. Later menu setup is a separate step.
@MainActor final class SNESReviewedInstallFlow: ObservableObject {
    enum Phase: Equatable { case ready, writing, restart, verifying, gameTest, completing, firstStageComplete, stopped, uncertain, needsAttention }
    @Published private(set) var phase: Phase = .ready
    @Published private(set) var stage: RecoveryStage = .checkingMaterial
    @Published private(set) var error: String?
    private let installOperation: (@escaping RecoveryProgressSink) async throws -> Void
    private let checkMenuOperation: () async throws -> Void
    private let acceptOperation: () async throws -> Void

    init(install: @escaping (@escaping RecoveryProgressSink) async throws -> Void,
         checkMenu: @escaping () async throws -> Void, accept: @escaping () async throws -> Void, initialPhase: Phase = .ready) {
        installOperation = install; checkMenuOperation = checkMenu; acceptOperation = accept; phase = initialPhase
    }

    static func resumePhase(for phase: SNESFirmwareJournal.Phase) throws -> Phase {
        _ = try SNESInstalledStartupCheck.recordStartupTransition(for: phase)
        return .restart
    }

    var isBusy: Bool { [.writing, .verifying, .completing].contains(phase) }

    func install(ready: Bool, approved: Bool) async {
        guard phase == .ready, ready, approved else { return }
        phase = .writing; error = nil
        do {
            try await installOperation { [weak self] value in await self?.update(value) }
            phase = .restart
        } catch {
            self.error = error.localizedDescription
            phase = error is SNESFirmwareTransactionError ? .uncertain : .stopped
        }
    }

    func checkMenu(visible: Bool) async {
        guard phase == .restart, visible else { return }
        phase = .verifying; error = nil
        do { try await checkMenuOperation(); phase = .gameTest }
        catch { self.error = error.localizedDescription; phase = .needsAttention }
    }

    func reportMenuProblem() {
        guard phase == .restart else { return }
        phase = .needsAttention
    }

    func confirmGame(works: Bool) async {
        guard phase == .gameTest else { return }
        guard works else { phase = .needsAttention; return }
        phase = .completing; error = nil
        do { try await acceptOperation(); phase = .firstStageComplete }
        catch { self.error = error.localizedDescription; phase = .needsAttention }
    }

    private func update(_ value: RecoveryStage) { stage = value }
}
