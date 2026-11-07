import Foundation
import SwiftHakchiCore

/// Checked frontend data for Mac-side review. Loading it does not prove the
/// connected console's libraries, authorize transfer or enable gameplay.
struct SNESCompatibilityFrontendPackage: Sendable {
    static let byteCount = 2_657_408
    static let sha256 = "2aa763b0ccd4a783bcb88bdd8e012e38cd8b60c2d5ece7f4db847a71d941f972"

    let frontend: Data
    let patch: Data
    let license: Data
    let inspection: ARMRuntimeELF

    static func loadBundled() throws -> Self {
        guard let root = Bundle.module.url(forResource: "SNESCompatibilityFrontend", withExtension: nil) else {
            throw failure()
        }
        return try Self(frontend: Data(contentsOf: root.appendingPathComponent("retroarch")),
                        patch: Data(contentsOf: root.appendingPathComponent("frontend.patch")),
                        license: Data(contentsOf: root.appendingPathComponent("COPYING")))
    }

    init(frontend: Data, patch: Data, license: Data) throws {
        guard frontend.count == Self.byteCount,
              BackupManifest.digest(frontend) == Self.sha256,
              patch.count == 3945,
              BackupManifest.digest(patch) == "c2eca527410551290c0ed72933d082214abf8a49cf55a805cde744a0388291ee",
              license.count == 35_147,
              BackupManifest.digest(license) == "8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903" else {
            throw Self.failure()
        }
        let inspected = try ARMRuntimeELF.reviewedCompatibilityFrontend(data: frontend)
        guard inspected.type == 2, inspected.interpreter == "/lib/ld-linux-armhf.so.3" else { throw Self.failure() }
        self.frontend = frontend
        self.patch = patch
        self.license = license
        self.inspection = inspected
    }

    private static func failure() -> Error {
        RecoveryProbeError.refused("The optional emulator frontend or its source notice does not match the reviewed build. Nothing was installed.")
    }
}
