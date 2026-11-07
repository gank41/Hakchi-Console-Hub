import Foundation
import Combine

/// Saves the included-game catalog after the game-folder update was confirmed.
@MainActor final class SNESLibrarySetupCompletionFlow: ObservableObject {
    enum Phase { case ready, checking, complete, failed }
    @Published private(set) var phase: Phase = .ready
    @Published private(set) var catalog: URL?
    @Published private(set) var error: String?
    private let upgrade: SNESFirmwareJournal.Prepared
    private let operation: (SNESFirmwareJournal.Prepared) async throws -> URL

    init(stage: SNESMenuSetupStageContext, upgrade: SNESFirmwareJournal.Prepared,
         capture: @escaping (SNESFirmwareJournal.Prepared) async throws -> URL) throws {
        guard stage.stage == .gameFolders, let parent = stage.parent,
              parent.operation.standardizedFileURL != upgrade.operation.standardizedFileURL else { throw SNESRuntimeBinding.failure() }
        self.upgrade = upgrade; operation = capture
    }

    func capture(ready: Bool) async {
        guard phase == .ready, ready else { return }
        phase = .checking
        do { catalog = try await operation(upgrade); phase = .complete }
        catch { self.error = error.localizedDescription; phase = .failed }
    }
}
