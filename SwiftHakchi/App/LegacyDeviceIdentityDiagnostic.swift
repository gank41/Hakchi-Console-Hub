import Foundation
import SwiftHakchiCore

/// A normal-boot, read-only comparison with the private FEL identity.
enum LegacyDeviceIdentityDiagnostic {
    static func run(client: any LegacyRequestExecuting,
                    expectedFingerprint: String = LegacyBoot2ActivationPlan.supportedHWIDSHA256) async throws -> String {
        let id = try await LegacyDeviceIdentity.read(client: client)
        guard LegacyDeviceIdentity.matches(id, fingerprint: expectedFingerprint) else {
            throw LegacyChangeError.refused("This legacy console's chip identity does not match the reviewed NES. No game upload was started.")
        }
        let fields: [String: Any] = ["mode": "read-legacy-identity", "identityMatched": true,
                                     "USBOpened": true, "gamesChanged": false]
        return String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }
}
