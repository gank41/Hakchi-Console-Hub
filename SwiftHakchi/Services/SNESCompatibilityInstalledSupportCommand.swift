import Foundation

/// Read-only inventory of a separately verified helper's expected support
/// files. The receipt provides no authority to install or launch anything.
struct SNESCompatibilityInstalledSupportCommand: Sendable {
    let command: String
    private static let receipt = Data("COMPATIBILITY SUPPORT MATCHES\nConsole launch is not enabled.\n".utf8)

    static func prepare(helperSHA256: String) throws -> Self {
        guard SNESDataSnapshotChunk.isDigest(helperSHA256) else { throw SNESLibraryMenu.failure() }
        let command = "B=/mnt/swifthakchi/busybox; P=/mnt/swifthakchi/snes-compat/preflight; [ -f \"$P\" ] && [ ! -L \"$P\" ] || exit 1; h=$(\"$B\" sha256sum \"$P\") || exit 1; [ \"${h%% *}\" = '" + helperSHA256 + "' ] || exit 1; \"$P\" --check-compatibility-support"
        guard command.utf8.count < 1020 else { throw SNESLibraryMenu.failure() }
        return .init(command: command)
    }

    func validateReceipt(_ raw: Data) throws -> Bool {
        guard raw == Self.receipt else { throw SNESLibraryMenu.failure() }
        return true
    }
}
