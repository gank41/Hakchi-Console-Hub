import Foundation

/// Read-only evidence from an already verified Mac backup. It never authorizes a
/// console write or recovery by itself. The caller must authenticate the live
/// pre-launch observation and retain exclusive access across its use.
struct SNESCompatibilityBackupEvidence: Sendable {
    enum Original: Equatable, Sendable { case absent, present(Data) }
    struct SavePair: Equatable, Sendable { let battery: Original, clock: Original }
    let gameCode: String, romSHA256: String, backupManifestSHA256: String, snapshotSHA256: String
    let session: Data, epoch: UInt64, original: Original, clockOriginal: Original
    private let reviewedRequest: SNESCompatibilityLaunchRequest, verifiedBackup: SNESLibraryBackup

    private static func failure() -> RecoveryProbeError {
        .refused("The saved console backup or game no longer matches. Prepare a new review; the console has not been changed.")
    }

    static func capture(backup: SNESLibraryBackup, current: SNESLibraryInventory,
                        request: SNESCompatibilityLaunchRequest) throws -> Self {
        // The frame is data until the caller authenticates its originating
        // session; parse it again instead of trusting a reconstructed request.
        let frame = Array(request.frame)
        guard frame.count == 107, Array(frame[0..<8]) == Array("HCLREQ1\0".utf8),
              let code = String(bytes: frame[8..<19], encoding: .ascii),
              SNESRecoveryBinding.validGameCode(code),
              let digest = String(bytes: frame[19..<83], encoding: .ascii),
              digest == request.source.sha256, SNESDataSnapshotChunk.isDigest(digest),
              request.source.directory.standardizedFileURL.lastPathComponent == code else { throw failure() }
        let token = Data(frame[83..<99])
        var epoch: UInt64 = 0
        for (index, byte) in frame[99..<107].enumerated() { epoch |= UInt64(byte) << (index * 8) }
        guard token.contains(where: { $0 != 0 }), epoch > 0,
              !backup.inventory.incompleteNamespace, backup.inventory.excludedMenuID == nil,
              !current.incompleteNamespace, current.excludedMenuID == nil,
              backup.inventory.hwid == current.hwid,
              backup.inventory.catalogSHA256 == current.catalogSHA256,
              backup.inventory.contextSHA256 == current.contextSHA256,
              backup.inventory.snapshotSHA256 == current.snapshotSHA256 else { throw failure() }
        try request.verifySource(); try backup.validate()
        let base = "clover/profiles/0/\(code)/hakchi/\(SNESCompatibilityCorePackage.engineID)/\(digest)"
        func original(at path: String) throws -> Original {
            // A directory at the file path or a file in a parent position is
            // a conflict rather than proof of absence for either save.
            guard !backup.inventory.directories.contains(where: { $0.path == path }) else { throw failure() }
            var parent = path
            while let slash = parent.lastIndex(of: "/") {
                parent = String(parent[..<slash])
                guard !backup.inventory.files.contains(where: { $0.path == parent }) else { throw failure() }
            }
            if let file = backup.inventory.files.first(where: { $0.path == path }) {
                guard (1...128 * 1024).contains(file.byteCount) else { throw failure() }
                return .present(try backup.read(path: path))
            }
            return .absent
        }
        let battery = try original(at: base + "/battery.srm")
        let clock = try original(at: base + "/battery.rtc")
        try backup.validate(); try request.verifySource()
        return Self(gameCode: code, romSHA256: digest, backupManifestSHA256: backup.manifestSHA256,
                    snapshotSHA256: current.snapshotSHA256, session: token, epoch: epoch, original: battery, clockOriginal: clock,
                    reviewedRequest: request, verifiedBackup: backup)
    }

    /// A retained value is still read-only evidence. Recheck the original
    /// sealed backup and exact reviewed source before using it in a binding.
    func validate(request: SNESCompatibilityLaunchRequest) throws {
        guard request.frame == reviewedRequest.frame,
              request.source.directory.standardizedFileURL == reviewedRequest.source.directory.standardizedFileURL,
              request.source.filename == reviewedRequest.source.filename,
              request.source.sha256 == romSHA256 else { throw Self.failure() }
        try verifiedBackup.validate(); try reviewedRequest.verifySource(); try request.verifySource(); try verifiedBackup.validate()
    }
}
