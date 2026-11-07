import Foundation
import CryptoKit
import SwiftHakchiCore

enum LegacyInspectionError: Error, LocalizedError {
    case busy, disconnected, invalidResponse, invalidReport, invalidMetadata, invalidBackup, timeout, outputLimit, usb(Int), archiveChanged(Int)
    var errorDescription: String? {
        switch self {
        case .busy: return "A legacy console operation is already running."
        case .disconnected: return "The legacy console connection closed. Reconnect before continuing."
        case .invalidResponse: return "The device did not return a valid Clovershell protocol response. No partial console result was accepted."
        case .invalidReport: return "The console information could not be read consistently. Return to the first game page, reconnect, and review the library again."
        case .invalidMetadata: return "Legacy game metadata could not be validated. No games were imported or changed."
        case .invalidBackup: return "Legacy backup verification failed. No verified manifest was created."
        case .timeout: return "The legacy console response was incomplete or timed out. No partial result was accepted."
        case .archiveChanged(let bytes): return "The downloaded legacy archive (\(bytes) bytes) did not match the independent console hash. Files may have changed or data was incomplete. No verified manifest was created; the unverified download was retained for diagnosis."
        case .outputLimit: return "The legacy response exceeds this preview's memory limit. No verified backup was created."
        case .usb(-4): return "The NES USB transfer timed out. Reconnect the console directly to the Mac and try again."
        case .usb(let code): return "Legacy USB access failed (\(code)). Check the cable and close other console applications before reconnecting."
        }
    }
}

actor LegacyInspectionClient: LegacyRequestExecuting {
    private let transport: any LegacyUSBTransport
    private let maximumOutputBytes: Int
    private let diagnosticsURL: URL?
    private let retainIncompleteOutput: Bool
    private var partialOutput = (stdout: Data(), stderr: Data())
    private var connected = false
    private var readPacketSize = 0
    private var busy = false
    private var generation = 0
    private var leaseID: UUID?
    private var pendingLeaseRelease: UUID?
    init(transport: any LegacyUSBTransport = IOKitLegacyUSBTransport(), maximumOutputBytes: Int = 512 * 1024 * 1024,
         diagnosticsURL: URL? = nil, retainIncompleteOutput: Bool = false) {
        self.transport = transport; self.maximumOutputBytes = maximumOutputBytes
        self.diagnosticsURL = diagnosticsURL; self.retainIncompleteOutput = retainIncompleteOutput
    }
    var isConnected: Bool { connected }
    func incompleteOutput() -> (stdout: Data, stderr: Data) { partialOutput }
    func connect(timeoutMilliseconds: Int = 3000) async throws {
        guard !busy, !connected else { throw LegacyInspectionError.busy }
        guard timeoutMilliseconds > 0 else { throw LegacyInspectionError.timeout }
        busy = true; defer { busy = false }
        generation += 1; let token = generation
        connected = false
        let challenge = Data(UUID().uuidString.utf8)
        let clock = ContinuousClock(); let deadline = clock.now.advanced(by: .milliseconds(timeoutMilliseconds))
        do {
            try await transport.open()
            try check(token)
            let size = try await transport.packetSize()
            guard [8, 16, 32, 64, 512, 1024].contains(size) else { throw LegacyInspectionError.invalidResponse }
            readPacketSize = size
            try check(token)
            try await send(ClovershellFrame(command: 0, connectionID: 0, payload: challenge))
            var decoder = ClovershellFrameDecoder()
            while clock.now < deadline {
                try check(token)
                let data = try await transport.read(maximumBytes: readPacketSize, timeoutMilliseconds: 100)
                try check(token)
                guard clock.now < deadline else { throw LegacyInspectionError.timeout }
                for frame in try decoder.feed(data) {
                    try check(token)
                    if frame.command == 0 { try await pong(frame) }
                    if frame.command == 1, frame.connectionID == 0, frame.payload == challenge {
                        connected = true; return
                    }
                }
            }
            throw LegacyInspectionError.timeout
        } catch {
            generation += 1
            connected = false; leaseID = nil; pendingLeaseRelease = nil
            await transport.close()
            throw error
        }
    }
    func disconnect() async {
        generation += 1; connected = false; leaseID = nil; pendingLeaseRelease = nil
        await transport.close()
    }
    func execute(_ request: LegacyReadRequest, timeoutMilliseconds: Int = 30_000) async throws -> SSHResult {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        return try await executeCommand(request.command, maximumBytes: request.maximumOutputBytes, binary: request.isBinary, timeoutMilliseconds: timeoutMilliseconds)
    }
    /// Fixed discovery only; no user metadata or mutable-console path is interpolated.
    func readSNESLibraryIdentity(challenge: UUID) async throws -> SSHResult {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        let input = Data(SNESLibraryIdentity.command(challenge: challenge).trimmingCharacters(in: .newlines).utf8)
        guard !input.isEmpty, input.count <= 65536, !input.contains(0) else { throw LegacyInspectionError.outputLimit }
        let hash = BackupManifest.digest(input)
        let command = "B=/mnt/swifthakchi/busybox; s=$(\"$B\" head -c " + String(input.count) + "); h=$(printf '%s' \"$s\" | \"$B\" sha256sum); [ \"${h%% *}\" = '" + hash + "' ] || exit 1; eval \"$s\" </dev/null"
        return try await executeCommand(command, maximumBytes: 1024, binary: false, timeoutMilliseconds: 30000, input: input)
    }
    /// A fixed, passive snapshot; it neither writes to the console nor controls a process.
    func readSNESNativeProcessSnapshot() async throws -> SSHResult {
        try await executeSNESLibraryRead(SNESNativeProcessSnapshot.command, maximumBytes: 65536, timeoutMilliseconds: 30000)
    }
    func readSNESNativeLaunchOptionNames() async throws -> SSHResult {
        try await executeSNESLibraryRead(SNESNativeProcessSnapshot.commandWithOptionNames, maximumBytes: 65536, timeoutMilliseconds: 30000)
    }
    /// Bounded, read-only time-file samples; no save path or game title leaves the console.
    func readSNESNativeTimeInventory() async throws -> SSHResult {
        try await executeSNESLibraryRead(SNESNativeTimeInventory.command, maximumBytes: 1024, timeoutMilliseconds: 30000)
    }
    func readSNESRAMTrialProcesses() async throws -> SSHResult {
        try await executeSNESRAMTrialRead(SNESNativeProcessSnapshot.commandForTemporaryTrial, maximumBytes: 65536)
    }
    func readSNESRAMLaunchObservation() async throws -> SSHResult {
        try await executeSNESRAMTrialRead(SNESRAMLaunchObservation.command, maximumBytes: 4096)
    }
    func readSNESRAMLifecycle() async throws -> SSHResult {
        try await executeSNESRAMTrialRead(SNESRAMLifecycleObservation.command, maximumBytes: 4096)
    }
    private func executeSNESRAMTrialRead(_ script: String, maximumBytes: Int) async throws -> SSHResult {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        let envelope = try SNESRAMLaunchObservation.envelope(script)
        return try await executeCommand(envelope.command, maximumBytes: maximumBytes, binary: false,
                                        timeoutMilliseconds: 30000, input: envelope.input)
    }
    /// Explicitly invoked diagnostic only. This reads the current menu and never installs the candidate.
    func readSNESParallelVerifierCandidate() async throws -> SSHResult {
        let idle = #"B=/mnt/swifthakchi/busybox; test -z "$("$B" pidof canoe-shvc clover-canoe-shvc kachikachi clover-kachikachi || :)" || exit 1"#
        return try await executeSNESLibraryRead(idle + "\n" + SNESLibraryStartupScripts.parallelChecksumVerifierCandidate(), maximumBytes: 1024, timeoutMilliseconds: 60000)
    }
    /// Fixed read-only startup report, streamed to avoid the old daemon's small exec buffer.
    func readSNESStartupTrial(_ trial: PreparedSNESStartupTrial, challenge: UUID) async throws -> SSHResult {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        let script = try SNESStartupTrialCommands.script(trial: trial, challenge: challenge).trimmingCharacters(in: .newlines)
        let input = Data(script.utf8)
        guard !input.isEmpty, input.count <= 65536, !input.contains(0) else { throw LegacyInspectionError.outputLimit }
        let hash = BackupManifest.digest(input)
        let command = "B=/mnt/swifthakchi/busybox; s=$(\"$B\" head -c " + String(input.count) + "); h=$(printf '%s' \"$s\" | \"$B\" sha256sum); [ \"${h%% *}\" = '" + hash + "' ] || exit 1; eval \"$s\" </dev/null"
        return try await executeCommand(command, maximumBytes: 16384, binary: false, timeoutMilliseconds: 120000, input: input)
    }
    func readSNESLibraryInventory(_ context: SNESLibraryContext, challenge: UUID) async throws -> SSHResult {
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        return try await executeSNESLibraryRead(SNESLibraryInventoryCommands.script(contextSHA256: context.sha256,
            hwid: context.installation.expected.hwid, catalogSHA256: context.installation.catalogContentSHA256,
            runtimeSHA256: context.installation.expected.runtimeSHA256, librarySupport: context.supportsLibrarySync, challenge: challenge),
            maximumBytes: SNESLibraryInventory.maximumFrameBytes)
    }
    /// Fixed read-only inspection; it cannot stage, publish, or retry a copy.
    func inspectSNESReplacementSaveStage(_ context: SNESLibraryContext,
                                         request: SNESReplacementSaveStageInspection.Request) async throws -> SNESReplacementSaveStageInspectionReceipt.Outcome {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        try request.require(context)
        let outcome = try await SNESReplacementSaveStageInspection.dispatch(request, contextSHA256: context.sha256,
            hwid: context.installation.expected.hwid, runtimeSHA256: context.installation.expected.runtimeSHA256) { checked in
                let stream = try checked.stream()
                let result = try await self.executeCommand(stream.command, maximumBytes: 4096, binary: false,
                                                           timeoutMilliseconds: 120000, input: stream.input)
                try checked.require(context)
                guard result.succeeded, result.stderr.isEmpty else { throw SNESLibraryInventory.failure() }
                return result.stdoutData
            }
        try request.require(context)
        return outcome
    }
    /// One inactive staging attempt under an already-durable, single-use permit.
    func stageSNESReplacementSave(_ context: SNESLibraryContext, request: SNESReplacementSaveStageCommands.Request,
                                  before: SNESLibraryInventory, permit: SNESReplacementSaveJournal.StagePermit) async throws -> SNESReplacementSaveStageReceipt {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        try permit.requireOwner(context); try permit.require(request: request, before: before)
        return try await SNESReplacementSaveStageCommands.dispatch(request: request, before: before, permit: permit) { checked in
            try permit.requireOwner(context)
            let stream = try checked.stream()
            let result = try await self.executeCommand(stream.command, maximumBytes: 4096, binary: false,
                                                       timeoutMilliseconds: 600000, input: stream.input)
            try permit.requireOwner(context)
            guard result.succeeded, result.stderr.isEmpty else { throw SNESLibraryInventory.failure() }
            return result.stdoutData
        }
    }
    /// Temporary runtime helper only, guarded by a single-use permit.
    func deliverSNESReplacementSaveHelper(_ context: SNESLibraryContext, request: SNESReplacementSaveHelperDelivery.Request,
                                          before: SNESLibraryInventory, permit: SNESReplacementSaveJournal.HelperDeliveryPermit) async throws {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        try permit.requireOwner(context); try permit.require(request: request, before: before)
        try await SNESReplacementSaveHelperDelivery.dispatch(request: request, before: before, permit: permit) { checked in
            try permit.requireOwner(context)
            let stream = try checked.stream()
            let result = try await self.executeCommand(stream.command, maximumBytes: 4096, binary: false,
                                                      timeoutMilliseconds: 120000, input: stream.input)
            try permit.requireOwner(context)
            guard result.succeeded, result.stderr.isEmpty else { throw SNESLibraryInventory.failure() }
            return result.stdoutData
        }
    }
    /// Publish only the exact request recorded by the one-use permit.
    func publishSNESReplacementSave(_ context: SNESLibraryContext, request: SNESReplacementSaveProfilePublication.Request,
                                    before: SNESLibraryInventory, permit: SNESReplacementSaveJournal.PublicationPermit) async throws {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        try permit.requireOwner(context); try permit.require(request: request, before: before)
        try await SNESReplacementSaveProfilePublication.dispatch(request: request, before: before, permit: permit) { checked in
            try permit.requireOwner(context)
            let stream = try checked.stream()
            let result = try await self.executeCommand(stream.command, maximumBytes: 4096, binary: false,
                                                      timeoutMilliseconds: 600000, input: stream.input)
            try permit.requireOwner(context)
            guard result.succeeded, result.stderr.isEmpty else { throw SNESLibraryInventory.failure() }
            return result.stdoutData
        }
    }
    func readSNESLibraryRecoveryInventory(_ context: SNESLibraryContext, permit: SNESLibraryReconciliationPermit, challenge: UUID) async throws -> SSHResult {
        try SNESLibraryJournalPolicy.requireOperation(permit.operation); try permit.requireOwner(context)
        return try await executeSNESLibraryRead(SNESLibraryInventoryCommands.script(contextSHA256: context.sha256,
            hwid: context.installation.expected.hwid, catalogSHA256: context.installation.catalogContentSHA256,
            runtimeSHA256: context.installation.expected.runtimeSHA256, librarySupport: context.supportsLibrarySync,
            challenge: challenge, excludingIncompleteMenu: permit.excludedMenuID, allowIncompleteNamespace: permit.allowsIncompleteNamespace), maximumBytes: SNESLibraryInventory.maximumFrameBytes)
    }
    /// Read-only support-file observation; a matching receipt does not authorize launch.
    func checkSNESCompatibilityInstalledSupport(_ context: SNESLibraryContext, helperSHA256: String) async throws -> SSHResult {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        let check = try SNESCompatibilityInstalledSupportCommand.prepare(helperSHA256: helperSHA256)
        let result = try await executeCommand(check.command, maximumBytes: 256, binary: true, timeoutMilliseconds: 30000)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard result.succeeded, result.stderr.isEmpty, try check.validateReceipt(result.stdoutData) else { throw SNESLibraryMenu.failure() }
        return result
    }
    /// Read-only compatibility preflight. The helper and game object must
    /// already be installed and independently verified by the calling workflow.
    func preflightSNESCompatibility(_ context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest,
                                    helperSHA256: String) async throws -> SSHResult {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        let preflight = try SNESCompatibilityPreflightCommand.prepare(request: request, helperSHA256: helperSHA256)
        let result = try await executeCommand(preflight.command, maximumBytes: 1024, binary: true,
                                              timeoutMilliseconds: 30000, input: preflight.input)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        try request.verifySource()
        guard result.succeeded, result.stderr.isEmpty, try preflight.validateReceipt(result.stdoutData) else {
            throw SNESLibraryMenu.failure()
        }
        return result
    }
    /// Bounded read-only inventory. The helper and connection must be
    /// independently verified; observations do not authorize recovery.
    func readSNESCompatibilityManagerInventory(_ context: SNESLibraryContext, game: Game,
                                               source: SNESLibraryROMSource, helperSHA256: String) async throws -> SNESCompatibilityManagerInventory.Observation {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        let command = try SNESCompatibilityManagerInventory.prepare(game: game, source: source, helperSHA256: helperSHA256)
        let result = try await executeCommand(command, maximumBytes: 10+16*(2+SNESRecoveryBinding.maximumManagerRecordBytes), binary: true, timeoutMilliseconds: 30000)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard result.succeeded, result.stderr.isEmpty else { throw SNESLibraryMenu.failure() }
        let observations = try SNESCompatibilityManagerInventory.parse(result.stdoutData, game: game, source: source)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        return observations
    }
    /// Bounded read-only recovery correlation; the helper must already be
    /// independently verified and the result does not authorize recovery.
    func readSNESCompatibilityRecovery(_ context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest,
                                       helperSHA256: String) async throws -> SSHResult {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        let prepared = try SNESCompatibilityRecoveryCommand.prepare(request: request, helperSHA256: helperSHA256)
        let result = try await executeCommand(prepared.command, maximumBytes: 24576, binary: true,
                                              timeoutMilliseconds: 30000, input: prepared.input)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        try request.verifySource()
        guard result.succeeded, result.stderr.isEmpty, result.stdoutData.count <= 24576 else { throw SNESLibraryMenu.failure() }
        return result
    }
    /// Bounded current-save read only; the response is not a restore permit.
    func readSNESCompatibilityCurrent(_ context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest,
                                      helperSHA256: String, region: SNESRecoveryRegion) async throws -> SSHResult {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        let prepared = try SNESCompatibilityRecoveryCommand.prepareCurrent(request: request, helperSHA256: helperSHA256, region: region)
        let result = try await executeCommand(prepared.command, maximumBytes: 128 * 1024 + 256, binary: true,
                                              timeoutMilliseconds: 30000, input: prepared.input)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        try request.verifySource()
        guard result.succeeded, result.stderr.isEmpty, result.stdoutData.count <= 128 * 1024 + 256 else { throw SNESLibraryMenu.failure() }
        return result
    }
    /// Read-only raw evidence; the caller must validate its framing, binding,
    /// session and independently reviewed state before offering recovery.
    func readSNESCompatibilityRetainedState(_ context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest,
                                            helperSHA256: String, paired: Bool) async throws -> SSHResult {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        let prepared = try SNESCompatibilityRecoveryCommand.prepareRetainedState(request: request, helperSHA256: helperSHA256, paired: paired)
        let limit = 16 * 1024 * 1024 + 24576
        let result = try await executeCommand(prepared.command, maximumBytes: limit, binary: true,
                                              timeoutMilliseconds: 30000, input: prepared.input)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        try request.verifySource()
        guard result.succeeded, result.stderr.isEmpty, result.stdoutData.count <= limit else { throw SNESLibraryMenu.failure() }
        return result
    }
    /// Raw read-only image evidence; callers must validate its binding and
    /// independently reviewed digest before considering any recovery action.
    func readSNESCompatibilityRetainedImage(_ context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest,
                                            helperSHA256: String, paired: Bool, retired: Bool = false) async throws -> SSHResult {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        let prepared = try SNESCompatibilityRecoveryCommand.prepareRetainedImage(request: request, helperSHA256: helperSHA256, paired: paired, retired: retired)
        let limit = 8 * 1024 * 1024 + 24576
        let result = try await executeCommand(prepared.command, maximumBytes: limit, binary: true,
                                              timeoutMilliseconds: 30000, input: prepared.input)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        try request.verifySource()
        guard result.succeeded, result.stderr.isEmpty, result.stdoutData.count <= limit else { throw SNESLibraryMenu.failure() }
        return result
    }
    /// Read-only archived-state evidence; callers independently validate its digest and session.
    func readSNESCompatibilityStateArchive(_ context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest,
                                           helperSHA256: String) async throws -> SSHResult {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        let prepared = try SNESCompatibilityRecoveryCommand.prepareStateArchive(request: request, helperSHA256: helperSHA256)
        let limit = 16 * 1024 * 1024 + 24576
        let result = try await executeCommand(prepared.command, maximumBytes: limit, binary: true,
                                              timeoutMilliseconds: 30000, input: prepared.input)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        try request.verifySource()
        guard result.succeeded, result.stderr.isEmpty, result.stdoutData.count <= limit else { throw SNESLibraryMenu.failure() }
        return result
    }
    /// Read-only prior-time evidence; the caller validates the frame and an independent digest.
    func readSNESCompatibilityRetainedTime(_ context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest,
                                           helperSHA256: String) async throws -> SSHResult {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        let prepared = try SNESCompatibilityRecoveryCommand.prepareRetainedTime(request: request, helperSHA256: helperSHA256)
        let result = try await executeCommand(prepared.command, maximumBytes: 24576, binary: true,
                                              timeoutMilliseconds: 30000, input: prepared.input)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        try request.verifySource()
        guard result.succeeded, result.stderr.isEmpty, result.stdoutData.count <= 24576 else { throw SNESLibraryMenu.failure() }
        return result
    }
    /// Inspect the selected clock workspace only. No restore is performed.
    func inspectSNESBatteryRecovery(_ context: SNESLibraryContext, plan: SNESBatteryRecoveryPlan,
                                    helperSHA256: String) async throws -> SSHResult {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        let prepared = try SNESBatteryRecoveryInspection.prepare(plan: plan, helperSHA256: helperSHA256)
        let result = try await executeCommand(prepared.command, maximumBytes: 128, binary: true,
                                              timeoutMilliseconds: 30000, input: prepared.input)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard result.succeeded, result.stderr.isEmpty, try prepared.validateReceipt(result.stdoutData),
              try SNESBatteryRecoveryInspection.prepare(plan: plan, helperSHA256: helperSHA256).input == prepared.input else { throw SNESLibraryMenu.failure() }
        return result
    }
    func inspectSNESClockRecovery(_ context: SNESLibraryContext, plan: SNESClockRecoveryPlan,
                                  helperSHA256: String) async throws -> SSHResult {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        let prepared = try SNESClockRecoveryInspection.prepare(plan: plan, helperSHA256: helperSHA256)
        let result = try await executeCommand(prepared.command, maximumBytes: 128, binary: true,
                                              timeoutMilliseconds: 30000, input: prepared.input)
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard result.succeeded, result.stderr.isEmpty, try prepared.validateReceipt(result.stdoutData),
              try SNESClockRecoveryInspection.prepare(plan: plan, helperSHA256: helperSHA256).input == prepared.input else { throw SNESLibraryMenu.failure() }
        return result
    }
    func readSNESCompatibilitySupport(_ context:SNESLibraryContext,challenge:UUID) async throws -> SSHResult {
        try context.requireCurrent(attachment:context.attachment,sessionID:context.sessionID)
        let command=try SNESCompatibilitySupportCommand.read(challenge:challenge,context:context.sha256,hwid:context.installation.expected.hwid)
        return try await executeSNESLibraryRead(command,maximumBytes:SNESCompatibilitySupportFrame.maximumBytes,binary:true,timeoutMilliseconds:120000)
    }
    func readSNESPowerInput(_ context:SNESLibraryContext,challenge:UUID) async throws -> SSHResult {
        try context.requireCurrent(attachment:context.attachment,sessionID:context.sessionID)
        let command=try SNESPowerInputCommand.read(challenge:challenge,context:context.sha256,hwid:context.installation.expected.hwid)
        return try await executeSNESLibraryRead(command,maximumBytes:4096,binary:true,timeoutMilliseconds:210000,powerReadyChallenge:challenge)
    }
    func readSNESResetInput(_ context:SNESLibraryContext,challenge:UUID) async throws -> SSHResult {
        try context.requireCurrent(attachment:context.attachment,sessionID:context.sessionID)
        let command=try SNESCompatibilityInputCommand.read(challenge:challenge,context:context.sha256,hwid:context.installation.expected.hwid)
        return try await executeSNESLibraryRead(command,maximumBytes:SNESCompatibilityInputFrame.maximumBytes,binary:true,timeoutMilliseconds:90000)
    }
    func readSNESFrontendSupport(_ context:SNESLibraryContext,challenge:UUID) async throws -> SSHResult {
        try context.requireCurrent(attachment:context.attachment,sessionID:context.sessionID)
        let command=try SNESFrontendSupportCommand.read(challenge:challenge,context:context.sha256,hwid:context.installation.expected.hwid)
        return try await executeSNESLibraryRead(command,maximumBytes:SNESFrontendSupportFrame.maximumBytes,binary:true,timeoutMilliseconds:180000)
    }
    func readSNESLibrarySpace(_ context: SNESLibraryContext, selection: SNESLibraryInventory.Selection, challenge: UUID) async throws -> SSHResult {
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        return try await executeSNESLibraryRead(SNESLibraryInventoryCommands.space(contextSHA256: context.sha256,
            hwid: context.installation.expected.hwid, runtimeSHA256: context.installation.expected.runtimeSHA256,
            selection: selection, challenge: challenge), maximumBytes: 1024)
    }
    func readSNESLibraryChunk(_ context: SNESLibraryContext, file: SNESLibraryInventory.File, offset: Int, challenge: UUID) async throws -> SSHResult {
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        return try await executeSNESLibraryRead(SNESLibraryBackupCommands.script(contextSHA256: context.sha256,
            hwid: context.installation.expected.hwid, runtimeSHA256: context.installation.expected.runtimeSHA256,
            file: file, offset: offset, challenge: challenge), maximumBytes: SNESLibraryBackupChunk.maximumBytes + 2048,
            binary: true, timeoutMilliseconds: 30000)
    }
    func readSNESIncludedGameChunk(_ context: SNESLibraryContext, entry: SNESOriginalGamesFrame.Entry, offset: Int, challenge: UUID) async throws -> SSHResult {
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        return try await executeSNESLibraryRead(SNESIncludedGameCopy.command(context: context, entry: entry, offset: offset, challenge: challenge),
            maximumBytes: SNESIncludedGameCopy.chunkSize + 2048, binary: true, timeoutMilliseconds: 30000)
    }
    func copySNESLibrary(_ context: SNESLibraryContext, plan: SNESLibrarySyncPlan, permit: SNESLibraryCopyPermit, before: SNESLibraryInventory) async throws -> SSHResult {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        try SNESLibraryJournalPolicy.requireOperation(permit.operation)
        try plan.requireOwner(context); try permit.require(plan)
        guard before.excludedMenuID == nil, before.stateSHA256 == plan.before.stateSHA256,
              before.contextSHA256 == context.sha256, before.hwid == plan.before.hwid else { throw SNESLibraryInventory.failure() }
        let request = try SNESLibraryCopyCommands.prepare(menu: plan.material.menu, before: before,
            runtimeSHA256: context.installation.expected.runtimeSHA256, challenge: permit.challenge)
        let stream = try request.stream()
        let result = try await executeCommand(stream.command, maximumBytes: 4096, binary: false, timeoutMilliseconds: 600000, input: stream.input)
        try plan.requireOwner(context); try permit.require(plan)
        guard result.succeeded, result.stderr.isEmpty else { throw SNESLibraryInventory.failure() }
        _ = try SNESLibraryCopyReceipt(result.stdoutData, request: request)
        return result
    }
    func restoreSNESLibrarySelection(_ context:SNESLibraryContext,plan:SNESLibrarySyncPlan,permit:SNESLibraryRollbackPermit,before:SNESLibraryInventory) async throws->SSHResult {
        guard leaseID==nil else {throw LegacyInspectionError.busy}
        try SNESLibraryJournalPolicy.requireOperation(permit.operation)
        try plan.requireOwner(context);try permit.require(plan,attachment:context.attachment)
        guard before.contextSHA256==context.sha256,before.stateSHA256==permit.expectedStateSHA256 else {throw SNESLibraryInventory.failure()}
        try SNESLibraryActiveCheck.require(plan,inventory:before,preserveProfiles:false)
        let request=try SNESLibraryRollbackCommands.prepare(menu:plan.material.menu,previous:plan.before.selection,current:before,runtimeSHA256:context.installation.expected.runtimeSHA256,challenge:permit.challenge,recoverPending:permit.allowsPendingRecovery)
        try permit.claimDispatch()
        let result=try await executeSNESLibraryRead(request.script,maximumBytes:4096)
        try plan.requireOwner(context);try permit.require(plan,attachment:context.attachment)
        guard result.succeeded,result.stderr.isEmpty else {throw SNESLibraryInventory.failure()}
        _=try SNESLibraryRollbackReceipt(result.stdoutData,request:request);return result
    }
    func inspectSNESLibraryRollback(_ context:SNESLibraryContext,plan:SNESLibrarySyncPlan,challenge:UUID) async throws->SSHResult {
        guard leaseID==nil else {throw LegacyInspectionError.busy}
        try plan.requireOwner(context)
        let request=try SNESLibraryRollbackPendingCommands.prepare(id:plan.material.menu.id,context:context.sha256,hwid:plan.before.hwid,runtime:context.installation.expected.runtimeSHA256,challenge:challenge)
        let result=try await executeSNESLibraryRead(request.script,maximumBytes:4096)
        try plan.requireOwner(context)
        guard result.succeeded,result.stderr.isEmpty else {throw SNESLibraryInventory.failure()}
        _=try SNESLibraryRollbackPendingReceipt(result.stdoutData,request:request);return result
    }
    func saveSNESLibrarySelection(_ context: SNESLibraryContext, plan: SNESLibrarySyncPlan, permit: SNESLibrarySelectionPermit, before: SNESLibraryInventory) async throws -> SSHResult {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        try SNESLibraryJournalPolicy.requireOperation(permit.operation)
        try plan.requireOwner(context); try permit.require(plan, attachment: context.attachment)
        guard before.contextSHA256 == context.sha256 else { throw SNESLibraryInventory.failure() }
        try SNESLibraryInactiveCheck.require(plan, inventory: before)
        let request = try SNESLibrarySelectionCommands.prepare(menu: plan.material.menu, before: before,
            runtimeSHA256: context.installation.expected.runtimeSHA256, challenge: permit.challenge)
        let result = try await executeSNESLibraryRead(request.script, maximumBytes: 4096)
        try plan.requireOwner(context); try permit.require(plan, attachment: context.attachment)
        guard result.succeeded, result.stderr.isEmpty else { throw SNESLibraryInventory.failure() }
        _ = try SNESLibrarySelectionReceipt(result.stdoutData, request: request)
        return result
    }
    func previewSNESLibraryCleanup(_ context: SNESLibraryContext, plan: SNESLibrarySyncPlan, scope: SNESLibraryCleanupPlan, challenge: UUID) async throws -> SSHResult {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        try plan.requireOwner(context); try scope.validateSources()
        guard scope.syncReviewSHA256 == plan.reviewSHA256, scope.hwid == context.installation.expected.hwid else { throw SNESLibraryInventory.failure() }
        let request = try SNESLibraryCleanupCommands.preview(scope: scope, contextSHA256: context.sha256,
            runtimeSHA256: context.installation.expected.runtimeSHA256, challenge: challenge)
        let stream = try request.stream()
        let result = try await executeCommand(stream.command, maximumBytes: 2 * 1024 * 1024, binary: false, timeoutMilliseconds: 180000, input: stream.input)
        try plan.requireOwner(context); try scope.validateSources()
        guard result.succeeded, result.stderr.isEmpty else { throw SNESLibraryInventory.failure() }
        _ = try SNESLibraryCleanupObservation(result.stdoutData, scope: scope, challenge: challenge, contextSHA256: context.sha256)
        return result
    }
    func removeSNESLibraryTemporary(_ context: SNESLibraryContext, plan: SNESLibrarySyncPlan, scope: SNESLibraryCleanupPlan,
                                   preview: SNESLibraryCleanupObservation, permit: SNESLibraryCleanupPermit) async throws -> SSHResult {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        try SNESLibraryJournalPolicy.requireOperation(permit.operation)
        try plan.requireOwner(context); try permit.require(plan: plan, scope: scope, preview: preview)
        guard preview.contextSHA256 == context.sha256 else { throw SNESLibraryInventory.failure() }
        let request = try SNESLibraryCleanupCommands.remove(scope: scope, preview: preview,
            runtimeSHA256: context.installation.expected.runtimeSHA256, challenge: permit.challenge), stream = try request.stream()
        let result = try await executeCommand(stream.command, maximumBytes: 4096, binary: false, timeoutMilliseconds: 180000, input: stream.input)
        try plan.requireOwner(context); try permit.require(plan: plan, scope: scope, preview: preview)
        guard result.succeeded, result.stderr.isEmpty else { throw SNESLibraryInventory.failure() }
        _ = try SNESLibraryCleanupReceipt(result.stdoutData, request: request, scope: scope)
        return result
    }
    func readSNESLibraryDiscardUpload(_ context: SNESLibraryContext, plan: SNESLibrarySyncPlan,
                                      reconciliation: SNESLibraryReconciliationPermit, challenge: UUID) async throws -> SSHResult {
        try plan.requireOwner(context); try reconciliation.requireOwner(context)
        guard reconciliation.id == plan.material.menu.id, reconciliation.reviewSHA256 == plan.reviewSHA256,
              reconciliation.excludedMenuID == plan.material.menu.id else { throw SNESLibraryInventory.failure() }
        let request = try SNESLibraryDiscardUploadCommands.prepare(plan: plan, contextSHA256: context.sha256,
            runtimeSHA256: context.installation.expected.runtimeSHA256, challenge: challenge)
        let result = try await executeSNESLibraryRead(request.script, maximumBytes: 2048)
        try plan.requireOwner(context); try reconciliation.requireOwner(context)
        guard result.succeeded, result.stderr.isEmpty else { throw SNESLibraryInventory.failure() }
        _ = try SNESLibraryDiscardUploadInspection(result.stdoutData, request: request)
        return result
    }
    func previewSNESLibraryDiscard(_ context: SNESLibraryContext, plan: SNESLibrarySyncPlan, scope: SNESLibraryDiscardPlan, challenge: UUID) async throws -> SSHResult {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        try plan.requireOwner(context); try scope.validateSources()
        guard scope.syncReviewSHA256 == plan.reviewSHA256, scope.hwid == context.installation.expected.hwid else { throw SNESLibraryInventory.failure() }
        let request = try SNESLibraryCleanupCommands.preview(scope: scope, contextSHA256: context.sha256,
            runtimeSHA256: context.installation.expected.runtimeSHA256, challenge: challenge)
        let stream = try request.stream()
        let result = try await executeCommand(stream.command, maximumBytes: 2 * 1024 * 1024, binary: false, timeoutMilliseconds: 180000, input: stream.input)
        try plan.requireOwner(context); try scope.validateSources()
        guard result.succeeded, result.stderr.isEmpty else { throw SNESLibraryInventory.failure() }
        _ = try SNESLibraryCleanupObservation(result.stdoutData, scope: scope, challenge: challenge, contextSHA256: context.sha256)
        return result
    }
    func discardSNESLibraryCopy(_ context: SNESLibraryContext, plan: SNESLibrarySyncPlan, scope: SNESLibraryDiscardPlan,
                                   preview: SNESLibraryCleanupObservation, permit: SNESLibraryDiscardPermit) async throws -> SSHResult {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        try SNESLibraryJournalPolicy.requireOperation(permit.operation)
        try plan.requireOwner(context); try permit.require(plan: plan, scope: scope, preview: preview)
        guard preview.contextSHA256 == context.sha256 else { throw SNESLibraryInventory.failure() }
        let request = try SNESLibraryCleanupCommands.remove(scope: scope, preview: preview,
            runtimeSHA256: context.installation.expected.runtimeSHA256, challenge: permit.challenge), stream = try request.stream()
        guard permit.attachment == context.attachment else { throw SNESLibraryInventory.failure() }
        try permit.claimDispatch()
        let result = try await executeCommand(stream.command, maximumBytes: 4096, binary: false, timeoutMilliseconds: 180000, input: stream.input)
        try plan.requireOwner(context); try permit.require(plan: plan, scope: scope, preview: preview)
        guard result.succeeded, result.stderr.isEmpty else { throw SNESLibraryInventory.failure() }
        _ = try SNESLibraryCleanupReceipt(result.stdoutData, request: request, scope: scope)
        return result
    }
    private func executeSNESLibraryRead(_ script: String, maximumBytes: Int, binary: Bool = false, timeoutMilliseconds: Int = 180000, powerReadyChallenge:UUID? = nil) async throws -> SSHResult {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        let input = Data(script.trimmingCharacters(in: .newlines).utf8)
        guard !input.isEmpty, input.count <= 65536, !input.contains(0) else { throw LegacyInspectionError.outputLimit }
        let hash = BackupManifest.digest(input)
        let command = "B=/mnt/swifthakchi/busybox; s=$(\"$B\" head -c " + String(input.count) + "); h=$(printf '%s' \"$s\" | \"$B\" sha256sum); [ \"${h%% *}\" = '" + hash + "' ] || exit 1; eval \"$s\" </dev/null"
        return try await executeCommand(command, maximumBytes: maximumBytes, binary: binary, timeoutMilliseconds: timeoutMilliseconds, input: input, powerReadyChallenge:powerReadyChallenge)
    }
    /// Fixed stock-asset reader; script input is length/hash checked before the daemon evaluates it.
    func readSNESOriginalGames(binding: SNESRuntimeBinding, challenge: UUID) async throws -> SSHResult {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        let script = try SNESOriginalGamesCommand.script(binding: binding, challenge: challenge).trimmingCharacters(in: .newlines)
        let input = Data(script.utf8)
        guard !input.isEmpty, input.count <= 65536, !input.contains(0) else { throw LegacyInspectionError.outputLimit }
        let hash = BackupManifest.digest(input)
        let command = "B=/mnt/swifthakchi/busybox; s=$(\"$B\" head -c " + String(input.count) + "); h=$(printf '%s' \"$s\" | \"$B\" sha256sum); [ \"${h%% *}\" = '" + hash + "' ] || exit 1; eval \"$s\" </dev/null"
        return try await executeCommand(command, maximumBytes: SNESOriginalGamesFrame.maximumSize, binary: true, timeoutMilliseconds: 120000, input: input)
    }
    /// The only game-copy command is generated from an immutable reviewed menu.
    func preflightSNESOneGame(_ material:SNESOneGameMaterial,challenge:UUID) async throws->SSHResult {
        try material.validate()
        return try await executeSNESOneGameScript(SNESOneGameStageCommands.preflight(menu:material.menu,originals:material.originals.frame,binding:material.accepted.material.trial.candidate.material.binding,challenge:challenge))
    }
    func inspectSNESOneGame(_ material:SNESOneGameMaterial,challenge:UUID,includeProcesses:Bool=false) async throws->SSHResult {
        try material.validate()
        return try await executeSNESOneGameScript(SNESOneGameStageCommands.inspect(menu:material.menu,originals:material.originals.frame,binding:material.accepted.material.trial.candidate.material.binding,challenge:challenge,includeProcesses:includeProcesses),maximumBytes:16384)
    }
    func verifySNESOneGame(_ material:SNESOneGameMaterial,challenge:UUID) async throws->SSHResult {
        try material.validate()
        return try await executeSNESOneGameScript(SNESOneGameStageCommands.verify(menu:material.menu,binding:material.accepted.material.trial.candidate.material.binding,challenge:challenge))
    }
    func copySNESOneGame(_ material:SNESOneGameMaterial,permit:SNESOneGameCopyPermit) async throws->SSHResult {
        try permit.require(material)
        return try await executeSNESOneGameScript(SNESOneGameStageCommands.copy(menu:material.menu,originals:material.originals.frame,binding:material.accepted.material.trial.candidate.material.binding,challenge:permit.challenge),bundle:material.bundle)
    }
    func startSNESOneGameMenuTrial(_ m:SNESOneGameMaterial,permit:SNESOneGameMenuTrialPermit) async throws->SSHResult {
        try permit.require(m)
        return try await executeSNESOneGameScript(SNESOneGameMenuTrialCommands.start(menu:m.menu,originals:m.originals.frame,binding:m.accepted.material.trial.candidate.material.binding,challenge:permit.challenge))
    }
    func readSNESOneGameMenuState(_ m:SNESOneGameMaterial,challenge:UUID,original:Bool) async throws->SSHResult {
        try m.validate()
        return try await executeSNESOneGameScript(SNESOneGameMenuTrialCommands.state(menu:m.menu,originals:m.originals.frame,binding:m.accepted.material.trial.candidate.material.binding,challenge:challenge,original:original))
    }
    func readSNESOneGameMenuTrialStartup(_ m:SNESOneGameMaterial,challenge:UUID) async throws->SSHResult {
        try m.validate();return try await executeSNESOneGameScript(SNESOneGameMenuTrialCommands.startupReport(m,challenge:challenge),maximumBytes:16384)
    }
    func inspectSNESMenuSelection(_ m:SNESMenuSelectionMaterial,challenge:UUID) async throws->SSHResult {
        try m.validate()
        return try await executeSNESOneGameScript(SNESMenuSelectionCommands.inspect(menu:m.game.menu,originals:m.game.originals.frame,binding:m.binding,operation:m.id,challenge:challenge))
    }
    func publishSNESMenuSelection(_ m:SNESMenuSelectionMaterial,permit:SNESMenuSelectionPermit) async throws->SSHResult {
        try permit.require(m)
        return try await executeSNESOneGameScript(SNESMenuSelectionCommands.publish(menu:m.game.menu,originals:m.game.originals.frame,binding:m.binding,operation:m.id,challenge:permit.challenge))
    }
    private func executeSNESOneGameScript(_ source:String,bundle:Data=Data(),maximumBytes:Int=4096) async throws->SSHResult {
        guard leaseID==nil else {throw LegacyInspectionError.busy}
        let stream=try SNESOneGameStream(script:source,body:bundle)
        // The fixed copy script consumes exact lengths and END; it never waits for stdin EOF.
        return try await executeCommand(stream.command,maximumBytes:maximumBytes,binary:false,timeoutMilliseconds:120000,input:stream.input)
    }
    func startTemporarySNESMenu(_ request: SNESTemporaryMenuStartRequest, timeoutMilliseconds: Int = 120_000) async throws -> SSHResult {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        try request.validateCurrent()
        return try await executeCommand(request.command, maximumBytes: 65536, binary: false, timeoutMilliseconds: timeoutMilliseconds)
    }
    /// Releases preparation only. The menu remains blocked until a durable checkpoint yields a launch request.
    func checkpointOriginalSNESMenu(_ menu: PreparedSNESOriginalMenu, challenge: UUID, timeoutMilliseconds: Int = 120_000) async throws -> SSHResult {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        try menu.validateCurrent()
        return try await executeCommand("exec /probe/busybox sh /probe/checkpoint " + challenge.uuidString,
            maximumBytes: 65536, binary: true, timeoutMilliseconds: timeoutMilliseconds)
    }
    func launchOriginalSNESMenu(_ request: SNESOriginalMenuLaunchRequest, timeoutMilliseconds: Int = 30_000) async throws -> SSHResult {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        try request.validateCurrent()
        return try await executeCommand(request.command, maximumBytes: 65536, binary: true, timeoutMilliseconds: timeoutMilliseconds)
    }
    func checkpointSNESAlienTrial(_ trial: PreparedSNESAlienTrial, challenge: UUID, timeoutMilliseconds: Int = 120_000) async throws -> SSHResult {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        try trial.validateCurrent()
        return try await executeCommand("exec /probe/busybox sh /probe/checkpoint " + challenge.uuidString,
                                        maximumBytes: 65536, binary: true, timeoutMilliseconds: timeoutMilliseconds)
    }
    func launchSNESAlienTrial(_ request: SNESAlienTrialLaunchRequest, timeoutMilliseconds: Int = 30_000) async throws -> SSHResult {
        guard leaseID == nil else { throw LegacyInspectionError.busy }
        try request.validateCurrent()
        return try await executeCommand(request.command, maximumBytes: 65536, binary: true, timeoutMilliseconds: timeoutMilliseconds)
    }
    func reserveForChange() throws -> LegacySessionLease {
        guard connected else { throw LegacyInspectionError.disconnected }
        guard !busy, leaseID == nil else { throw LegacyInspectionError.busy }
        let id = UUID(); leaseID = id
        return LegacySessionLease(client: self, id: id)
    }
    func releaseLease(_ id: UUID) {
        guard leaseID == id else { return }
        if busy { pendingLeaseRelease = id } else { leaseID = nil }
    }
    func executeLeased(_ request: LegacyReadRequest, lease: UUID, timeoutMilliseconds: Int) async throws -> SSHResult {
        guard leaseID == lease else { throw LegacyInspectionError.disconnected }
        return try await executeCommand(request.command, maximumBytes: request.maximumOutputBytes, binary: request.isBinary, timeoutMilliseconds: timeoutMilliseconds)
    }
    func performChange(_ request: LegacyChangeRequest, lease: UUID) async throws -> SSHResult {
        guard leaseID == lease else { throw LegacyInspectionError.disconnected }
        let script = try request.command.trimmingCharacters(in: .newlines)
        let input = Data(script.utf8)
        guard input.count <= 65536, !input.contains(0) else { throw LegacyInspectionError.outputLimit }
        // Old daemon exec_new_connection echoes commands into a 1024-byte stack buffer.
        // Receive the entire bounded script in memory and verify it before evaluation.
        let hash = BackupManifest.digest(input)
        // Do not send protocol stdin EOF: this daemon closes the descriptor both
        // on EOF and again during cleanup, potentially closing a newer pipe.
        let bootstrap = "s=$(head -c " + String(input.count) + "); [ \"$(printf '%s' \"$s\" | sha256sum | cut -d ' ' -f 1)\" = '" + hash + "' ] || exit 1; eval \"$s\" </dev/null"
        return try await executeCommand(bootstrap, maximumBytes: request.maximumOutputBytes, binary: false,
                                        timeoutMilliseconds: 120_000, input: input)
    }
    func uploadLeasedFile(_ file: URL, operationID: UUID, expectedSHA256: String,
                          expectedBytes: Int64, lease: UUID, timeoutMilliseconds: Int,
                          progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> SSHResult {
        guard leaseID == lease else { throw LegacyInspectionError.disconnected }
        guard timeoutMilliseconds > 0, timeoutMilliseconds <= 600_000 else { throw LegacyInspectionError.timeout }
        let command = try LegacyStageTransfer.command(operationID: operationID, sha256: expectedSHA256, bytes: expectedBytes)
        let source = try LegacySyncPlan.SourceFile.capture(file)
        guard source.byteCount == expectedBytes, source.sha256 == expectedSHA256 else {
            throw SyncPlanError.invalidInput("The staged archive changed after review. No USB command was sent.")
        }
        let result = try await executeCommand(command, maximumBytes: 1024, binary: false,
                                              timeoutMilliseconds: timeoutMilliseconds, fileInput: source,
                                              inputProgress: progress)
        try LegacyStageTransfer.requireReceipt(result, operationID: operationID,
                                               sha256: expectedSHA256, bytes: expectedBytes)
        return result
    }
    private func executeCommand(_ command: String, maximumBytes: Int, binary: Bool,
                                timeoutMilliseconds: Int, input: Data = Data(),
                                fileInput: LegacySyncPlan.SourceFile? = nil,
                                inputProgress: (@Sendable (Int64, Int64) -> Void)? = nil,
                                powerReadyChallenge:UUID? = nil) async throws -> SSHResult {
        guard !busy else { throw LegacyInspectionError.busy }
        guard connected else { throw LegacyInspectionError.disconnected }
        guard timeoutMilliseconds > 0 else { throw LegacyInspectionError.timeout }
        guard command.utf8.count < 1020 else { throw LegacyInspectionError.outputLimit }
        busy = true
        defer {
            busy = false
            if pendingLeaseRelease == leaseID { leaseID = nil; pendingLeaseRelease = nil }
        }
        guard fileInput == nil || input.isEmpty else { throw LegacyInspectionError.invalidResponse }
        let fileHandle = try fileInput.map { try FileHandle(forReadingFrom: $0.url) }
        defer { try? fileHandle?.close() }
        let inputCount = fileInput?.byteCount ?? Int64(input.count)
        var streamedHash = SHA256()
        func nextChunk(offset: Int64, count: Int) throws -> Data {
            if let fileHandle {
                var chunk = Data()
                while chunk.count < count {
                    let more = try fileHandle.read(upToCount: count - chunk.count) ?? Data()
                    guard !more.isEmpty else { throw LegacyInspectionError.invalidResponse }
                    chunk.append(more)
                }
                streamedHash.update(data: chunk)
                return chunk
            }
            return Data(input[Int(offset)..<Int(offset) + count])
        }
        let token = generation
        let clock = ContinuousClock(); let deadline = clock.now.advanced(by: .milliseconds(timeoutMilliseconds))
        var connectionID: UInt8?
        var inputOffset: Int64 = 0
        var inputClosed = inputCount == 0
        partialOutput = (Data(), Data())
        var stdout = Data(), stderr = Data()
        var stdoutEOF = false, stderrEOF = false
        var powerReadyReported=false
        var exitCode: Int?
        do {
            try check(token)
            try await send(ClovershellFrame(command: 9, connectionID: 0, payload: Data(command.utf8)))
            var decoder = ClovershellFrameDecoder()
            var awaitingInputAck = false
            let outputLimit = min(maximumOutputBytes, maximumBytes)
            while clock.now < deadline {
                try check(token)
                let data = try await transport.read(maximumBytes: readPacketSize, timeoutMilliseconds: 100)
                try check(token)
                guard clock.now < deadline else { throw LegacyInspectionError.timeout }
                var ackInRead = false
                for frame in try decoder.feed(data) {
                    try check(token)
                    if frame.command == 0 { try await pong(frame); continue }
                    if frame.command == 10 {
                        guard connectionID == nil else { throw LegacyInspectionError.invalidResponse }
                        connectionID = frame.connectionID
                        if inputCount > 0 {
                            let payload = try nextChunk(offset: 0, count: Int(min(512, inputCount)))
                            try await send(ClovershellFrame(command: 12, connectionID: frame.connectionID, payload: payload))
                            inputOffset = Int64(payload.count); awaitingInputAck = true
                            inputProgress?(inputOffset, inputCount)
                        }
                        continue
                    }
                    guard let connectionID, frame.connectionID == connectionID else { continue }
                    switch frame.command {
                    case 18:
                        guard !ackInRead, awaitingInputAck, !inputClosed, frame.payload.count == 8 else { throw LegacyInspectionError.invalidResponse }
                        ackInRead = true
                        func integer(_ offset: Int) -> Int {
                            Int(Int32(bitPattern: frame.payload[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }))
                        }
                        let queued = integer(0), capacity = integer(4)
                        guard queued >= 0, capacity >= 512, capacity <= 64 * 1024 * 1024, queued <= capacity else { throw LegacyInspectionError.invalidResponse }
                        if inputOffset == inputCount {
                            if let fileInput {
                                let digest = streamedHash.finalize().map { String(format: "%02x", $0) }.joined()
                                guard digest == fileInput.sha256 else { throw LegacyInspectionError.invalidResponse }
                            }
                            inputClosed = true; awaitingInputAck = false
                        } else {
                            let count = Int(min(512, inputCount - inputOffset))
                            if capacity - queued >= count {
                                let payload = try nextChunk(offset: inputOffset, count: count)
                                try await send(ClovershellFrame(command: 12, connectionID: connectionID, payload: payload))
                                inputOffset += Int64(payload.count)
                                inputProgress?(inputOffset, inputCount)
                            } else {
                                try await Task.sleep(for: .milliseconds(10)); try check(token)
                                try await send(ClovershellFrame(command: 19, connectionID: connectionID, payload: Data()))
                            }
                        }
                    case 13:
                        guard !stdoutEOF else { throw LegacyInspectionError.invalidResponse }
                        if frame.payload.isEmpty { stdoutEOF = true } else { stdout.append(frame.payload) }
                    case 14:
                        guard !stderrEOF else { throw LegacyInspectionError.invalidResponse }
                        if frame.payload.isEmpty { stderrEOF = true } else {
                            stderr.append(frame.payload)
                            if !powerReadyReported,let challenge=powerReadyChallenge,SNESPowerInputCommand.hasReadyMarker(stderr,challenge:challenge) {
                                powerReadyReported=true
                                FileHandle.standardError.write(Data("POWER_CAPTURE_READY\n".utf8))
                            }
                        }
                    case 15:
                        guard exitCode == nil, frame.payload.count == 1 || frame.payload.count == 4 else { throw LegacyInspectionError.invalidResponse }
                        let value = frame.payload.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
                        exitCode = Int(Int32(bitPattern: value))
                    default: break
                    }
                    guard stdout.count <= outputLimit, stderr.count <= outputLimit - stdout.count else { throw LegacyInspectionError.outputLimit }
                }
                try check(token)
                guard clock.now < deadline else { throw LegacyInspectionError.timeout }
                if let exitCode, stdoutEOF, stderrEOF {
                    guard inputClosed else { throw LegacyInspectionError.invalidResponse }
                    return SSHResult(stdout: binary ? "" : String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self), stdoutData: stdout, exitCode: exitCode)
                }
            }
            throw LegacyInspectionError.timeout
        } catch {
            if retainIncompleteOutput { partialOutput = (Data(stdout.prefix(65536)), Data(stderr.prefix(65536))) }
            if let diagnosticsURL {
                let fields: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()),
                    "error": error.localizedDescription, "inputBytes": inputCount, "inputSent": inputOffset,
                    "inputClosed": inputClosed, "stdoutBytes": stdout.count, "stderrBytes": stderr.count,
                    "stdoutEOF": stdoutEOF, "stderrEOF": stderrEOF, "exitSeen": exitCode != nil,
                    "connectionOpened": connectionID != nil, "timeoutMilliseconds": timeoutMilliseconds]
                if let data = try? JSONSerialization.data(withJSONObject: fields, options: .sortedKeys) {
                    try? FileManager.default.createDirectory(at: diagnosticsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if let handle = try? FileHandle(forWritingTo: diagnosticsURL) {
                        defer { try? handle.close() }
                        _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data + Data([10]))
                    } else { try? (data + Data([10])).write(to: diagnosticsURL, options: .atomic) }
                }
            }
            generation += 1
            connected = false; leaseID = nil; pendingLeaseRelease = nil
            await transport.close()
            throw error
        }
    }
    private func check(_ token: Int) throws {
        try Task.checkCancellation()
        guard generation == token else { throw LegacyInspectionError.disconnected }
    }
    private func send(_ frame: ClovershellFrame) async throws {
        try await transport.write(frame.encoded(), timeoutMilliseconds: 1000)
    }
    private func pong(_ frame: ClovershellFrame) async throws {
        try await send(ClovershellFrame(command: 1, connectionID: frame.connectionID, payload: frame.payload))
    }
}
