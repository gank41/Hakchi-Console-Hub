import Foundation
import SwiftHakchiCore

/// Private inert component bytes. Parsing this frame never grants boot eligibility.
struct SNESOriginalComponentFrame: Sendable {
    static let maximumSize = 512 * 1024
    static let paths = ["lib/modules/3.4.113/extra/clvcon.ko", "lib/modules/3.4.113/extra/mali.ko",
        "lib/modules/3.4.113/kernel/drivers/input/keyboard/sunxi-keyboard.ko",
        "lib/modules/3.4.113/kernel/drivers/input/keyboard/sunxi-knob.ko", "usr/bin/clover-mcp"]
    struct Record: Sendable {
        let path: String, count: Int, digest: String, data: Data
    }
    let raw: Data, records: [Record]
    static func failure() -> RecoveryProbeError {
        .refused("The original SNES component check did not pass. Nothing was installed.")
    }
    init(_ raw: Data) throws {
        guard raw.count <= Self.maximumSize else { throw Self.failure() }
        var cursor = 0
        func line() throws -> String {
            let limit = min(raw.count, cursor+1024)
            guard cursor < limit, let end = raw[cursor..<limit].firstIndex(of: 10),
                  raw[cursor..<end].allSatisfy({ (32...126).contains($0) }) else { throw Self.failure() }
            let value = String(decoding: raw[cursor..<end], as: UTF8.self); cursor = end+1; return value
        }
        guard try line() == "SWIFTHAKCHI_SNES_ORIGINAL_COMPONENTS_V1" else { throw Self.failure() }
        var result: [Record] = []
        for path in Self.paths {
            let fields = try line().components(separatedBy: " ")
            guard fields.count == 4, fields[0] == "F", fields[1] == path,
                  let n = Int(fields[2]), (1...262144).contains(n), String(n) == fields[2],
                  fields[3].count == 64, SNESRuntimeBinding.hex(fields[3]), n < raw.count-cursor else { throw Self.failure() }
            let bytes = Data(raw[cursor..<cursor+n]); cursor += n
            guard raw[cursor] == 10, BackupManifest.digest(bytes) == fields[3] else { throw Self.failure() }
            cursor += 1
            result.append(.init(path: path, count: n, digest: fields[3], data: bytes))
        }
        guard try line() == "END", cursor == raw.count else { throw Self.failure() }
        self.raw = raw; records = result
    }
}
