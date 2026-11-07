import Foundation
import SwiftHakchiCore

/// Immutable Mac-side support material. This describes files only: it does
/// not install them, provide a console launcher, or authorize a sync.
struct SNESCompatibilitySupportPayload: Sendable {
    struct File: Sendable {
        let relativePath: String
        let bytes: Data
        let sha256: String
        var byteCount: Int { bytes.count }
    }

    static let root = "/mnt/swifthakchi/snes-compat"
    let files: [File]
    /// Expected location while running; this is not a writable-install claim.
    var runtimeRoot: String { Self.root }
    var totalBytes: Int { files.reduce(0) { $0 + $1.byteCount } }

    init(controller: SNESCompatibilityControllerProfile.Prepared,
         core: SNESCompatibilityCorePackage,
         frontend: SNESCompatibilityFrontendPackage) throws {
        try SNESCompatibilityControllerProfile.validate(controller.bytes)
        guard controller.name == SNESCompatibilityControllerProfile.consoleName else {
            throw SNESLibraryMenu.failure()
        }
        let probe = try SNESCompatibilityProbePackage.loadBundled()
        let entries: [(String, Data)] = [
            ("autoconfig/" + controller.name, controller.bytes),
            ("retroarch", frontend.frontend),
            ("snes9x2010_libretro.so", core.core),
            ("size-probe", probe.executable)
        ]
        files = entries.map { File(relativePath: $0.0, bytes: $0.1, sha256: BackupManifest.digest($0.1)) }
    }
}
