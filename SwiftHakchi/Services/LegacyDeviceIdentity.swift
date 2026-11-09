import Foundation
import SwiftHakchiCore

/// Reads the same four SID words as the FEL recovery probe from the old core.
/// This is a read-only identity gate, not an authorization to mutate games.
enum LegacyDeviceIdentity {
    static func read(client: any LegacyRequestExecuting) async throws -> String {
        let result = try await client.execute(.chipID, timeoutMilliseconds: 10_000)
        guard result.succeeded else { throw LegacyInspectionError.invalidResponse }
        return try parse(result.stdoutData)
    }

    static func parse(_ data: Data) throws -> String {
        guard data.count <= 1024, let text = String(data: data, encoding: .ascii) else {
            throw LegacyInspectionError.invalidResponse
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == 7, lines[0] == "SWIFTHAKCHI_CHIP_ID_V1", lines[5] == "END",
              lines[6].isEmpty else { throw LegacyInspectionError.invalidResponse }
        var words: [String] = []
        for line in lines[1...4] {
            guard line.hasPrefix("0x"), line.count == 10,
                  line.dropFirst(2).utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
                throw LegacyInspectionError.invalidResponse
            }
            words.append(String(line.dropFirst(2)).lowercased())
        }
        let id = words.joined()
        guard id.contains(where: { $0 != "0" }) else { throw LegacyInspectionError.invalidResponse }
        return id
    }

    static func matches(_ id: String, fingerprint: String) -> Bool {
        id.count == 32 && id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            && BackupManifest.digest(Data(id.utf8)) == fingerprint
    }

    static func requireOperationIdentity(_ id: String, fingerprint: String?) throws {
        guard let fingerprint else {
            throw LegacyChangeError.refused("This older operation has no verified NES identity. Review the original NES before continuing.")
        }
        guard matches(id, fingerprint: fingerprint) else { throw LegacyInspectionError.invalidBackup }
    }

    /// A valid unbound ID permits inspection only; false means the original
    /// console has not been established and no recovery write is authorized.
    static func requireReadOnlyInspection(_ id: String, fingerprint: String?) throws -> Bool {
        guard id.contains(where: { $0 != "0" }),
              matches(id, fingerprint: BackupManifest.digest(Data(id.utf8))) else {
            throw LegacyInspectionError.invalidResponse
        }
        guard let fingerprint else { return false }
        try requireOperationIdentity(id, fingerprint: fingerprint)
        return true
    }
}
