import Foundation
import SWCompression
import SwiftHakchiCore

struct RecoveryPayloadEvidence: Sendable {
    let bootImageSHA256: String
    let ubootSHA256: String
    let hmodSHA256: String
}

/// Recovery never uses an unversioned downloaded module. Pins describe audited bytes,
/// not a claim that booting or flashing those bytes has passed hardware validation.
enum RecoveryPayloadValidator {
    static let fes1SHA256 = "2ccd22b8db392153643ba06e9189a81df7a11412044fabb092368a25c31685da"
    static let bootImageSHA256 = "9e921c326be65aa4a3100270e86fdb15fe4b8563d586941b9f6c640eef064e4c"
    static let ubootSHA256 = "5cfacb297b962a388d947e3be553692bb1e9df9edc1125ca5a769166d3a89564"

    static func validateBootInputs(fes1: Data, uboot: Data, bootImage: Data) throws {
        try check(fes1, size: 14048, sha: fes1SHA256, name: "fes1.bin")
        try check(bootImage, size: 4585472, sha: bootImageSHA256, name: "custom recovery boot.img")
        try check(uboot, size: 761856, sha: ubootSHA256, name: "U-Boot")
        _ = try LegacyAndroidBootImage(data: bootImage)
        _ = try bootCommandRange(in: uboot)
    }

    static func validate(fes1: Data, hmod: Data, baseHmods: Data) throws -> RecoveryPayloadEvidence {
        try check(fes1, size: 14048, sha: fes1SHA256, name: "fes1.bin")
        try check(hmod, size: 9340382, sha: "003994b46504959895f40b0b9e91b16951ef4a638feb6312314c8fc4fdbff592", name: "hakchi.hmod")
        try check(baseHmods, size: 1740800, sha: "a64a50a57906c5bfc4d886f0d6b4b80cd6a3d4fe9f869b9b3db1fb16a1778ebe", name: "basehmods.tar")
        // Exact size/hash checks precede decompression, so untrusted gzip sizes are not used.
        let entries = try TarContainer.open(container: GzipArchive.unarchive(archive: hmod))
        let boot = try member("boot/boot.img", entries: entries)
        let uboot = try member("boot/uboot.bin", entries: entries)
        try validateBootInputs(fes1: fes1, uboot: uboot, bootImage: boot)
        return RecoveryPayloadEvidence(bootImageSHA256: bootImageSHA256, ubootSHA256: ubootSHA256, hmodSHA256: BackupManifest.digest(hmod))
    }

    static func check(_ data: Data, size: Int, sha: String, name: String) throws {
        guard data.count == size, BackupManifest.digest(data) == sha else {
            throw RecoveryImageError.invalid("\(name) differs from the pinned recovery material. Restore the audited bundled copy; downloaded latest modules are not used for recovery.")
        }
    }

    static func member(_ path: String, entries: [TarEntry]) throws -> Data {
        let matches = entries.filter { $0.info.name == path || $0.info.name == "./" + path }
        guard matches.count == 1, let entry = matches.first, entry.info.type == .regular,
              let data = entry.data, !data.isEmpty else {
            throw RecoveryImageError.invalid("Recovery archive needs exactly one ordinary \(path) member.")
        }
        return data
    }

    static func bootCommandRange(in data: Data) throws -> Range<Int> {
        guard data.count <= 1024 * 1024 else { throw RecoveryImageError.invalid("U-Boot is oversized.") }
        let bytes = Array(data), marker = Array("bootcmd=".utf8)
        guard bytes.count >= marker.count else { throw RecoveryImageError.invalid("U-Boot has no bootcmd value.") }
        var matches: [Int] = []
        for i in 0...(bytes.count - marker.count) where bytes[i..<(i + marker.count)].elementsEqual(marker) {
            matches.append(i + marker.count)
        }
        guard matches.count == 1, let start = matches.first,
              let end = bytes[start...].firstIndex(of: 0), end - start >= "boota 47400000".utf8.count,
              bytes[start..<end].allSatisfy({ $0 >= 32 && $0 <= 126 }) else {
            throw RecoveryImageError.invalid("U-Boot needs one bounded bootcmd value with room for the transfer command.")
        }
        return start..<end
    }
}
