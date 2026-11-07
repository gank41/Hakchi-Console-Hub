import Foundation
import SwiftHakchiCore

/// Reviewed bytes for local compatibility preparation. The probe has not been
/// exercised on a console and this package does not enable transfer or launch.
struct SNESCompatibilityProbePackage: Sendable {
    static let byteCount = 5_428
    static let sha256 = "fa7240e655e7592d08ee87fdf68b25e5e0a9f3046f9e3192ce63d9ef68d7993e"
    static let sourceSHA256 = "7844d7971c7da6a28998497916e9eaee16575596e8a5ab018475e06ecbdd9ebd"

    let executable: Data
    let source: Data
    let inspection: ARMRuntimeELF

    static func loadBundled() throws -> Self {
        guard let root = Bundle.module.url(forResource: "SNESCompatibilityProbe", withExtension: nil) else {
            throw failure()
        }
        return try Self(executable: Data(contentsOf: root.appendingPathComponent("size-probe")),
                        source: Data(contentsOf: root.appendingPathComponent("core-size-probe.c")))
    }

    init(executable: Data, source: Data) throws {
        guard executable.count == Self.byteCount, BackupManifest.digest(executable) == Self.sha256,
              source.count == 4_399, BackupManifest.digest(source) == Self.sourceSHA256 else { throw Self.failure() }
        let inspected = try ARMRuntimeELF(data: executable)
        guard inspected.type == 2, inspected.interpreter == "/lib/ld-linux-armhf.so.3" else { throw Self.failure() }
        self.executable = executable
        self.source = source
        self.inspection = inspected
    }

    private static func failure() -> Error {
        RecoveryProbeError.refused("The optional save-size probe or its source does not match the reviewed build. Nothing was installed.")
    }
}
