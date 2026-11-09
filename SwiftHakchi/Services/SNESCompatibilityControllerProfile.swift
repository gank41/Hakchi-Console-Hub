import Foundation
import SwiftHakchiCore

/// Reviewed controller data for the experimental SNES compatibility engine.
/// Loading this resource does not install it or enable console sync or launch.
enum SNESCompatibilityControllerProfile {
    static let byteCount = 1459
    static let sha256 = "55018944a935bd04858d80f0f99d5a7ecfb61353565ba565eedd0075a55d2c35"
    static let consoleName = "clovercon.cfg"

    struct Prepared {
        let name: String
        let bytes: Data
    }

    /// Mac-only preparation; the console destination remains separately gated.
    static func prepare() throws -> Prepared {
        Prepared(name: consoleName, bytes: try load())
    }

    static func load() throws -> Data {
        guard let url = Bundle.appBundle.url(forResource: "SNESCompatibilityController", withExtension: "cfg") else {
            throw SNESRuntimeBinding.failure()
        }
        let data = try Data(contentsOf: url)
        try validate(data)
        return data
    }

    static func validate(_ data: Data) throws {
        guard data.count == byteCount, BackupManifest.digest(data) == sha256 else {
            throw SNESRuntimeBinding.failure()
        }
    }
}
