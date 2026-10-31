import Foundation
import SwiftHakchiCore

/// A separate accepted-v4 entry point. Only inert preparation and RAM/read-only services are reachable.
enum SNESLibraryStartupDiagnostic {
    static func runIfPresent(_ args: [String],
        loadInputs: @Sendable () async throws -> RecoveryBootInputs = { try PayloadService.shared.pinnedRecoveryInputs() },
        requireOperation: @Sendable (URL) throws -> Void = { try SNESFirmwareJournalPolicy.requireOperation($0) },
        checkHost: @Sendable () async throws -> Void = { try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed() },
        makePreflightIO: @Sendable (SNESStartupAdapterCandidate, SNESMenuStartupParent) throws -> any SNESStartupPreflightIO = { candidate, parent in try NativeSNESStartupPreflightIO(candidate: candidate, parent: parent) },
        makeTrialIO: @Sendable (PreparedSNESStartupTrial) throws -> any SNESStartupTrialIO = { NativeSNESStartupTrialIO(trial: $0) },
        progress: @escaping RecoveryProgressSink = { _ in }) async throws -> String? {
        let library = ["--prepare-snes-library-startup", "--preflight-snes-library-startup", "--test-snes-library-startup", "--check-snes-library-startup"]
        let prior = ["--prepare-snes-menu-startup", "--preflight-snes-menu-startup", "--test-snes-menu-startup", "--check-snes-menu-startup"]
        guard let mode = args.first, let index = library.firstIndex(of: mode) else { return nil }
        var translated = args; translated[0] = prior[index]
        return try await SNESMenuStartupDiagnostic.runIfPresent(translated,
            resolveParent: { try await $0.libraryStartupParent() }, loadInputs: loadInputs,
            requireOperation: requireOperation, checkHost: checkHost, makePreflightIO: makePreflightIO,
            makeTrialIO: makeTrialIO, progress: progress)
    }
}
