import Foundation
import SwiftHakchiCore

/// Inert bundled helper bytes. Loading them grants no console-write authority.
struct SNESReplacementSaveHelper: Sendable {
    static let byteCount = 17_544
    static let sha256 = "926c6b5e436f5b4e9e4e7c5973f7fa466c702464b19fbfe9cb63984bc48a64a0"
    let bytes: Data

    static func bundled() throws -> Self {
        guard let url = Bundle.appBundle.url(forResource: "snes-save-profile-switch", withExtension: nil,
                                            subdirectory: "SNESPortableHelpers") else { throw SNESLibraryInventory.failure() }
        return try validate(RecoveryMaterialReader.readFile(at: url, maximumBytes: byteCount, exactBytes: byteCount))
    }

    static func validate(_ data: Data) throws -> Self {
        guard data.count == byteCount, BackupManifest.digest(data) == sha256,
              data.range(of: Data("/Users/".utf8)) == nil,
              data.range(of: Data("/Development/NES".utf8)) == nil else { throw SNESLibraryInventory.failure() }
        let elf = try ARMRuntimeELF(data: data)
        guard elf.type == 2, elf.interpreter == nil, elf.dependencies.isEmpty else { throw SNESLibraryInventory.failure() }
        func word(_ n: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(data[n + $1]) << ($1 * 8) } }
        let start = Int(word(28)), count = Int(data[44]) | Int(data[45]) << 8, entry = UInt64(word(24))
        var executableEntry = false, nonExecutableStack = false
        for i in 0..<count {
            let p = start + i * 32, type = word(p), flags = word(p + 24)
            guard flags & 3 != 3 else { throw SNESLibraryInventory.failure() }
            if type == 1 {
                let address = UInt64(word(p + 8)), size = UInt64(word(p + 16))
                if flags & 1 != 0, entry >= address, entry - address < size { executableEntry = true }
            }
            if type == 0x6474e551 { nonExecutableStack = flags & 1 == 0 }
        }
        guard executableEntry, nonExecutableStack else { throw SNESLibraryInventory.failure() }
        return .init(bytes: data)
    }
}
