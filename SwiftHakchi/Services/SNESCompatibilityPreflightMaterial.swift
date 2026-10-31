import Foundation
import SwiftHakchiCore

/// Inert Mac-side bytes for a future read-only preflight. The expected helper
/// hash must come from an independently verified build, and the console ABI,
/// dependencies, free space and copy protocol still need separate checks.
/// This material contains no emulator, and does not authorize installation.
struct SNESCompatibilityPreflightMaterial: Sendable {
    let helper: Data
    let rom: Data
    let helperSHA256: String
    let remoteROMName: String
    let command: SNESCompatibilityPreflightCommand

    static func prepare(request: SNESCompatibilityLaunchRequest, helper: Data,
                        expectedHelperSHA256: String) throws -> Self {
        guard (52...2 * 1024 * 1024).contains(helper.count),
              SNESDataSnapshotChunk.isDigest(expectedHelperSHA256),
              BackupManifest.digest(helper) == expectedHelperSHA256 else { throw SNESLibraryMenu.failure() }
        let b = Array(helper.prefix(52))
        guard b[0..<7].elementsEqual([0x7f, 0x45, 0x4c, 0x46, 1, 1, 1]),
              b[16] == 2, b[17] == 0, b[18] == 40, b[19] == 0,
              Array(b[36..<40]) == [0, 4, 0, 5] else { throw SNESLibraryMenu.failure() }
        let command = try SNESCompatibilityPreflightCommand.prepare(request: request, helperSHA256: expectedHelperSHA256)
        let (captured, bytes) = try SNESLibraryROMSource.capture(directory: request.source.directory, filename: request.source.filename)
        guard captured.sha256 == request.source.sha256, captured.byteCount == request.source.byteCount else { throw SNESLibraryMenu.failure() }
        try request.verifySource()
        let ext = URL(fileURLWithPath: request.source.filename).pathExtension.lowercased()
        guard ["sfc", "smc"].contains(ext) else { throw SNESLibraryMenu.failure() }
        return .init(helper: helper, rom: bytes, helperSHA256: expectedHelperSHA256,
                     remoteROMName: captured.sha256 + "." + ext, command: command)
    }
}
