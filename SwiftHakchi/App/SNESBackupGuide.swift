import Foundation

@MainActor final class SNESBackupGuide: ObservableObject {
    enum Phase { case instructions, working, returnToNormal, complete, failed }
    @Published private(set) var phase = Phase.instructions
    @Published private(set) var stage = RecoveryStage.checkingMaterial
    @Published private(set) var backupDirectory: URL?
    @Published private(set) var diagnosticDirectory: URL?
    @Published private(set) var errorMessage: String?
    private let execute: @Sendable (@escaping RecoveryProgressSink) async throws -> URL
    init(execute: @escaping @Sendable (@escaping RecoveryProgressSink) async throws -> URL) { self.execute = execute }
    func start(ready: Bool) async {
        guard ready, phase == .instructions else { return }
        phase = .working
        do {
            backupDirectory = try await execute { [weak self] stage in await self?.update(stage) }
        } catch {
            errorMessage = error.localizedDescription
            diagnosticDirectory = (error as? SNESSetupDiagnosticSavedError)?.directory
        }
        // Even a failed boot request may have executed. Never retry or claim normal mode automatically.
        phase = .returnToNormal
    }
    private func update(_ value: RecoveryStage) { stage = value }
    func confirmNormalBoot() {
        guard phase == .returnToNormal else { return }
        phase = errorMessage == nil ? .complete : .failed
    }
}
