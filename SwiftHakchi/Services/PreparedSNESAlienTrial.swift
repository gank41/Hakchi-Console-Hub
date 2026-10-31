import Foundation
import SwiftHakchiCore

/// A specific memory-only developer trial tied to validated original SNES material.
/// Construction is not permission to boot it; the coordinator must perform its
/// own checkpoint, release and report verification.
struct PreparedSNESAlienTrial: Sendable {
    let base: PreparedSNESOriginalMenu
    let image: Data
    let frontendSHA256: String
    let expectation: SNESOriginalMenuExpectation
    private let imageSHA256: String

    init(base: PreparedSNESOriginalMenu, payload: [String: Data], report: Data) throws {
        try base.validateCurrent()
        let result = try SNESAlienTrialImageBuilder.build(source: base.image, payload: payload, report: report)
        self.base = base
        guard let frontend = payload["retroarch"] else { throw SNESRuntimeBinding.failure() }
        self.frontendSHA256 = BackupManifest.digest(frontend)
        self.image = result.image
        self.imageSHA256 = BackupManifest.digest(result.image)
        self.expectation = .init(binding: base.material.binding, nonce: base.nonce, filesSHA256: result.filesSHA256,
                                 sourceFilesSHA256: base.sourceFilesSHA256, componentsSHA256: base.componentsSHA256)
        try validateCurrent()
    }
    func validateCurrent() throws {
        try Task.checkCancellation()
        try base.validateCurrent()
        try expectation.validate()
        guard BackupManifest.digest(image) == imageSHA256,
              try LegacyBootImageBuilder.inspect(image).kernel == base.material.kernel else { throw SNESRuntimeBinding.failure() }
    }
}
