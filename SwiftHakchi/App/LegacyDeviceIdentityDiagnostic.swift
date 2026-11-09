import Foundation
import SwiftHakchiCore

/// A normal-boot, read-only identity check. A caller may compare against
/// reviewed evidence, but merely identifying a console requires no device pin.
enum LegacyDeviceIdentityDiagnostic {
    static func run(client: any LegacyRequestExecuting,
                    expectedFingerprint: String? = nil) async throws -> String {
        let id = try await LegacyDeviceIdentity.read(client: client)
        if let expectedFingerprint, !LegacyDeviceIdentity.matches(id, fingerprint: expectedFingerprint) {
            throw LegacyChangeError.refused("This legacy console's chip identity does not match the reviewed NES. No game upload was started.")
        }
        var fields: [String: Any] = ["mode": "read-legacy-identity", "identityRead": true,
                                    "USBOpened": true, "gamesChanged": false]
        if expectedFingerprint != nil { fields["identityMatched"] = true }
        return String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }
}
