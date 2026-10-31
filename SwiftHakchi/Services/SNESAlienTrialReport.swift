import Foundation

/// Evidence that the expected emulator process is alive, not evidence of gameplay.
struct SNESAlienTrialReport: Sendable {
    let pid: Int
    init(_ raw: Data, nonce: UUID, challenge: UUID, expectedExecutableSHA256: String) throws {
        func fail() -> Error { SNESRuntimeBinding.failure() }
        guard expectedExecutableSHA256.count == 64,
              expectedExecutableSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              raw.count <= 1024, raw.last == 10,
              raw.allSatisfy({ $0 == 10 || (32...126).contains($0) }),
              let text = String(data: raw, encoding: .utf8) else { throw fail() }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count == 9, lines[0] == "SWIFTHAKCHI_SNES_TRIAL_V1",
              lines[1] == "NONCE=" + nonce.uuidString,
              lines[2] == "CHALLENGE=" + challenge.uuidString,
              lines[3] == "STATUS=running", lines[4].hasPrefix("TRIAL_PID="),
              lines[5].hasPrefix("DAEMON_PID="), lines[6] == "EXEC_SHA=" + expectedExecutableSHA256,
              lines[7] == "END", lines[8].isEmpty else { throw fail() }
        func readPID(_ line: String, prefix: String) -> Int? {
            let value = String(line.dropFirst(prefix.count))
            guard let number = Int(value), String(number) == value, (2...4_194_304).contains(number) else { return nil }
            return number
        }
        guard let trial = readPID(lines[4], prefix: "TRIAL_PID="),
              let daemon = readPID(lines[5], prefix: "DAEMON_PID="), trial != daemon else { throw fail() }
        self.pid = trial
    }
}
