import Foundation
import SwiftHakchiCore

/// Inert, source-built ARM helpers for a future guided SNES setup.
/// Loading these bytes does not authorize a boot, upload, or firmware write.
struct SNESPortableHelpers: Sendable {
    struct Identity: Sendable {
        let byteCount: Int
        let sha256: String
    }
    // Keep shipped identities here when selecting a newer bundled build. Old
    // recovery journals must continue to open with their original helper bytes.
    enum Version: CaseIterable, Sendable {
        case v1
        var reader: Identity { .init(byteCount: 2_560, sha256: "15d3cf5a75cc2ce3ef0cdf830ee6ec5251a5014f45fc8fac1fa26c8d783e0952") }
        var writer: Identity { .init(byteCount: 31_512, sha256: "0cc4f84437c0028e041e05b67de2369d4cbd636d8c4a071a16d63b06a92a8494") }
        func identity(_ kind: Kind) -> Identity { kind == .reader ? reader : writer }
    }
    static let currentVersion = Version.v1
    static func recognizes(kind: Kind, byteCount: Int, sha256: String) -> Bool {
        Version.allCases.contains { let id = $0.identity(kind); return id.byteCount == byteCount && id.sha256 == sha256 }
    }
    static func recognizes(kind: Kind, sha256: String) -> Bool {
        Version.allCases.contains { $0.identity(kind).sha256 == sha256 }
    }
    enum Kind: String, CaseIterable, Sendable {
        case reader, writer

        var filename: String { self == .reader ? "bounded-nand-read" : "bounded-nand-write" }
        var byteCount: Int { SNESPortableHelpers.currentVersion.identity(self).byteCount }
        var sha256: String { SNESPortableHelpers.currentVersion.identity(self).sha256 }
    }

    let kind: Kind
    let bytes: Data
    var firmwareWriteAuthorized: Bool { false }

    static func bundled(_ kind: Kind) throws -> Self {
        let url = try resourceURL(kind)
        let bytes = try RecoveryMaterialReader.readFile(at: url, maximumBytes: kind.byteCount, exactBytes: kind.byteCount)
        return try validate(bytes, as: kind)
    }

    static func bundledReader() throws -> SNESBoundedReadHelper {
        let helper = try SNESBoundedReadHelper.load(resourceURL(.reader))
        guard helper.digest == Kind.reader.sha256 else { throw failure() }
        return helper
    }

    static func bundledWriter() throws -> SNESBoundedWriteHelper {
        let helper = try SNESBoundedWriteHelper.load(resourceURL(.writer))
        guard helper.digest == Kind.writer.sha256 else { throw failure() }
        return helper
    }

    private static func resourceURL(_ kind: Kind) throws -> URL {
        guard let url = Bundle.appBundle.url(forResource: kind.filename, withExtension: nil,
                                             subdirectory: "SNESPortableHelpers") else { throw failure() }
        return url
    }

    static func validate(_ data: Data, as kind: Kind) throws -> Self {
        guard data.count == kind.byteCount, BackupManifest.digest(data) == kind.sha256,
              data.range(of: Data("/Users/".utf8)) == nil,
              data.range(of: Data("/Development/NES".utf8)) == nil else { throw failure() }
        let elf = try ARMRuntimeELF(data: data)
        guard elf.type == 2, elf.interpreter == nil, elf.dependencies.isEmpty else { throw failure() }
        func word(_ n: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(data[n + $1]) << ($1 * 8) } }
        let start = Int(word(28)), count = Int(data[44]) | Int(data[45]) << 8, entry = UInt64(word(24))
        var executableEntry = false, nonExecutableStack = false
        for i in 0..<count {
            let p = start + i * 32, type = word(p), flags = word(p + 24)
            guard flags & 3 != 3 else { throw failure() }
            if type == 1 {
                let address = UInt64(word(p + 8)), size = UInt64(word(p + 16))
                if flags & 1 != 0, entry >= address, entry - address < size { executableEntry = true }
            }
            if type == 0x6474e551 { nonExecutableStack = flags & 1 == 0 }
        }
        guard executableEntry, nonExecutableStack else { throw failure() }
        return .init(kind: kind, bytes: data)
    }

    private static func failure() -> RecoveryProbeError {
        .refused("The bundled SNES setup helper is missing or does not match its checked build. No console operation was started.")
    }
}
