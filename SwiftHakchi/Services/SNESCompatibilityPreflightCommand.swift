import Foundation

/// A bounded read-only command for a future verified compatibility install.
/// The helper hash must come from the installation's independently verified
/// material. This does not install a helper, copy games or authorize a launch.
struct SNESCompatibilityPreflightCommand: Sendable {
    let command: String
    let input: Data
    let expectedReceipt: Data
    let request: SNESCompatibilityLaunchRequest

    static func prepare(request: SNESCompatibilityLaunchRequest, helperSHA256: String) throws -> Self {
        let f = Array(request.frame)
        guard f.count == 107, f.prefix(8).elementsEqual("HCLREQ1\0".utf8),
              let game = String(bytes: f[8..<19], encoding: .ascii), SNESRecoveryBinding.validGameCode(game),
              let digest = String(bytes: f[19..<83], encoding: .ascii), digest == request.source.sha256,
              SNESDataSnapshotChunk.isDigest(digest), SNESDataSnapshotChunk.isDigest(helperSHA256),
              request.source.directory.lastPathComponent == game,
              f[83..<99].contains(where: { $0 != 0 }) else { throw SNESLibraryMenu.failure() }
        let epoch = (0..<8).reduce(UInt64(0)) { $0 | UInt64(f[99 + $1]) << (8 * $1) }
        guard epoch > 0 else { throw SNESLibraryMenu.failure() }
        let ext = URL(fileURLWithPath: request.source.filename).pathExtension.lowercased()
        guard ["sfc", "smc"].contains(ext) else { throw SNESLibraryMenu.failure() }
        try request.verifySource()
        let session = f[83..<99].map { String(format: "%02x", $0) }.joined()
        let receipt = Data("HCK_PREFLIGHT_1\nGAME=\(game)\nROM=\(digest)\nSESSION=\(session)\nEPOCH=\(epoch)\nEND\nConsole launch is not enabled.\n".utf8)
        // Both variable components are constrained to ASCII hex or validated game codes.
        let folder = "/var/lib/swifthakchi/snes-compat/games/" + game
        let file = digest + "." + ext
        let command = "B=/mnt/swifthakchi/busybox; P=/mnt/swifthakchi/snes-compat/preflight; [ -f \"$P\" ] && [ ! -L \"$P\" ] || exit 1; h=$(\"$B\" sha256sum \"$P\") || exit 1; [ \"${h%% *}\" = '" + helperSHA256 + "' ] || exit 1; \"$B\" head -c 107 | \"$P\" --check-request '" + folder + "' '" + file + "'"
        guard command.utf8.count < 1020 else { throw SNESLibraryMenu.failure() }
        return .init(command: command, input: request.frame, expectedReceipt: receipt, request: request)
    }
    func validateReceipt(_ raw: Data) throws -> Bool {
        guard raw == expectedReceipt else { throw SNESLibraryMenu.failure() }
        return true
    }
}

/// A bounded read-only command. A matching helper hash and session frame are
/// correlation checks, not proof of console identity or stopped writers.
struct SNESCompatibilityRecoveryCommand: Sendable {
    let command: String, input: Data
    static func prepare(request: SNESCompatibilityLaunchRequest, helperSHA256: String) throws -> Self {
        let checked = try SNESCompatibilityPreflightCommand.prepare(request: request, helperSHA256: helperSHA256)
        let command = "B=/mnt/swifthakchi/busybox; P=/mnt/swifthakchi/snes-compat/preflight; [ -f \"$P\" ] && [ ! -L \"$P\" ] || exit 1; h=$(\"$B\" sha256sum \"$P\") || exit 1; [ \"${h%% *}\" = '" + helperSHA256 + "' ] || exit 1; \"$B\" head -c 107 | \"$P\" --observe-recovery"
        guard command.utf8.count < 1020 else { throw SNESLibraryMenu.failure() }
        return .init(command: command, input: checked.input)
    }
    static func prepareCurrent(request: SNESCompatibilityLaunchRequest, helperSHA256: String,
                               region: SNESRecoveryRegion) throws -> Self {
        let checked = try prepare(request: request, helperSHA256: helperSHA256)
        let suffix = "--observe-recovery"
        guard checked.command.hasSuffix(suffix) else { throw SNESLibraryMenu.failure() }
        return .init(command: String(checked.command.dropLast(suffix.count)) + "--observe-recovery-save " + region.rawValue,
                     input: checked.input)
    }
    static func prepareRetainedState(request: SNESCompatibilityLaunchRequest, helperSHA256: String,
                                     paired: Bool) throws -> Self {
        let checked = try prepare(request: request, helperSHA256: helperSHA256)
        let suffix = "--observe-recovery"
        guard checked.command.hasSuffix(suffix) else { throw SNESLibraryMenu.failure() }
        return .init(command: String(checked.command.dropLast(suffix.count)) + "--observe-retained-state " + (paired ? "paired" : "save"),
                     input: checked.input)
    }
    static func prepareRetainedImage(request: SNESCompatibilityLaunchRequest, helperSHA256: String,
                                     paired: Bool, retired: Bool = false) throws -> Self {
        let checked = try prepare(request: request, helperSHA256: helperSHA256)
        let suffix = "--observe-recovery"
        guard checked.command.hasSuffix(suffix) else { throw SNESLibraryMenu.failure() }
        return .init(command: String(checked.command.dropLast(suffix.count)) + (retired ? "--observe-retired-image " : "--observe-retained-image ") + (paired ? "paired" : "image"),
                     input: checked.input)
    }
    static func prepareRetainedTime(request: SNESCompatibilityLaunchRequest, helperSHA256: String) throws -> Self {
        let checked = try prepare(request: request, helperSHA256: helperSHA256)
        let suffix = "--observe-recovery"
        guard checked.command.hasSuffix(suffix) else { throw SNESLibraryMenu.failure() }
        return .init(command: String(checked.command.dropLast(suffix.count)) + "--observe-retained-time", input: checked.input)
    }
    static func prepareStateArchive(request: SNESCompatibilityLaunchRequest, helperSHA256: String) throws -> Self {
        let checked = try prepare(request: request, helperSHA256: helperSHA256)
        let suffix = "--observe-recovery"
        guard checked.command.hasSuffix(suffix) else { throw SNESLibraryMenu.failure() }
        return .init(command: String(checked.command.dropLast(suffix.count)) + "--observe-state-archive", input: checked.input)
    }
}

/// Read-only workspace selection inspection. It does not verify the supplied
/// save bytes, authenticate the console, stop writers or authorize a restore.
struct SNESBatteryRecoveryInspection: Sendable {
    let command: String, input: Data, expectedReceipt: Data
    static func prepare(plan: SNESBatteryRecoveryPlan, helperSHA256: String) throws -> Self {
        guard SNESDataSnapshotChunk.isDigest(helperSHA256) else { throw SNESLibraryMenu.failure() }
        let input = try plan.encodedRequest()
        let command = "B=/mnt/swifthakchi/busybox; P=/mnt/swifthakchi/snes-compat/preflight; [ -f \"$P\" ] && [ ! -L \"$P\" ] || exit 1; h=$(\"$B\" sha256sum \"$P\") || exit 1; [ \"${h%% *}\" = '" + helperSHA256 + "' ] || exit 1; \"$B\" head -c \(input.count) | \"$P\" --inspect-battery-recovery"
        guard command.utf8.count < 1020 else { throw SNESLibraryMenu.failure() }
        let receipt = Data("HC-BATTERY-INSPECT-1\n\(plan.workspace) \(plan.originalPresent ? 1 : 2)\nEND\n".utf8)
        return .init(command: command, input: input, expectedReceipt: receipt)
    }
    func validateReceipt(_ data: Data) throws -> Bool {
        guard data == expectedReceipt else { throw SNESLibraryMenu.failure() }; return true
    }
    static func capture(plan: SNESBatteryRecoveryPlan, helperSHA256: String,
                        validate: @Sendable () async throws -> Void,
                        read: @Sendable () async throws -> Data) async throws -> Data {
        let expected = try prepare(plan: plan, helperSHA256: helperSHA256)
        try await validate(); let first = try await read()
        guard first.count <= 128 else { throw SNESLibraryMenu.failure() }
        try await validate(); let second = try await read(); try await validate()
        guard first == second, try expected.validateReceipt(second),
              try prepare(plan: plan, helperSHA256: helperSHA256).input == expected.input else { throw SNESLibraryMenu.failure() }
        try await validate()
        guard try plan.encodedRequest() == expected.input else { throw SNESLibraryMenu.failure() }
        return second
    }
}

struct SNESClockRecoveryInspection: Sendable {
    let command: String, input: Data, expectedReceipt: Data
    static func prepare(plan: SNESClockRecoveryPlan, helperSHA256: String) throws -> Self {
        guard SNESDataSnapshotChunk.isDigest(helperSHA256) else { throw SNESLibraryMenu.failure() }
        let input = try plan.encodedRequest()
        let command = "B=/mnt/swifthakchi/busybox; P=/mnt/swifthakchi/snes-compat/preflight; [ -f \"$P\" ] && [ ! -L \"$P\" ] || exit 1; h=$(\"$B\" sha256sum \"$P\") || exit 1; [ \"${h%% *}\" = '" + helperSHA256 + "' ] || exit 1; \"$B\" head -c \(input.count) | \"$P\" --inspect-clock-recovery"
        guard command.utf8.count < 1020 else { throw SNESLibraryMenu.failure() }
        let receipt = Data("HC-CLOCK-INSPECT-1\n\(plan.workspace) \(plan.originalPresent ? 1 : 2)\nEND\n".utf8)
        return .init(command: command, input: input, expectedReceipt: receipt)
    }
    func validateReceipt(_ data: Data) throws -> Bool {
        guard data == expectedReceipt else { throw SNESLibraryMenu.failure() }; return true
    }
    static func capture(plan: SNESClockRecoveryPlan, helperSHA256: String,
                        validate: @Sendable () async throws -> Void,
                        read: @Sendable () async throws -> Data) async throws -> Data {
        let expected = try prepare(plan: plan, helperSHA256: helperSHA256)
        try await validate(); let first = try await read()
        guard first.count <= 128 else { throw SNESLibraryMenu.failure() }
        try await validate(); let second = try await read(); try await validate()
        guard first == second, try expected.validateReceipt(second),
              try prepare(plan: plan, helperSHA256: helperSHA256).input == expected.input else { throw SNESLibraryMenu.failure() }
        // Revalidate the attachment after the receipt and local plan checks.
        // The result remains a read-only observation, not write authority.
        try await validate()
        guard try plan.encodedRequest() == expected.input else { throw SNESLibraryMenu.failure() }
        return second
    }
}
