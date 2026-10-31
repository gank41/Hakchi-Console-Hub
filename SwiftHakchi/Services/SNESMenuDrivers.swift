import Foundation
import SWCompression
import SwiftHakchiCore

/// Exact retained driver bytes, selected in memory. No package scripts are executed.
struct SNESMenuDrivers: Sendable {
    static let archiveSHA256 = "f52a47db1be5a5e6754ff400a65ac5aa21244f00d8bba0b02d832d6dee711b14"
    let archive: Data
    let files: [String: Data]
    init(_ archive: Data) throws {
        guard archive.count == 99217, BackupManifest.digest(archive) == Self.archiveSHA256 else { throw SNESRuntimeBinding.failure() }
        let entries = try TarContainer.open(container: GzipArchive.unarchive(archive: archive))
        var files: [String: Data] = [:]
        for (path, count, digest) in [
            ("extra/clovercon.ko", 16280, "7b46a3772494bb7d4c49f0f53db89405325cab46dc44a1da153a0ccc89932e1d"),
            ("extra/mali.ko", 165736, "c615229a8c99f52f3b6e2316cd8eff21e8d61b95797c2b6d06e47371c998cc42"),
            ("kernel/drivers/input/keyboard/sunxi-keyboard.ko", 6900, "5ac62b172af5d8f19104a32e24cdd45ed0a019da53b3dd18e4a12d41d4dfc0f7"),
            ("kernel/drivers/input/keyboard/sunxi-knob.ko", 7108, "569a7a1e8348619296e3c3a88e8ba20963af57247e92cde6ce8cc17c7d9095e2")
        ] {
            let bytes = try RecoveryPayloadValidator.member("lib/modules/3.4.112.madmonkey/" + path, entries: entries)
            guard bytes.count == count, BackupManifest.digest(bytes) == digest else { throw SNESRuntimeBinding.failure() }
            try Self.validateModule(bytes)
            files[String(path.split(separator: "/").last!)] = bytes
        }
        self.archive = archive; self.files = files
    }
    static func validateModule(_ bytes: Data) throws {
        func fail() -> RecoveryProbeError { SNESRuntimeBinding.failure() }
        guard (52...8*1024*1024).contains(bytes.count), bytes.prefix(7) == Data([0x7f,69,76,70,1,1,1]) else { throw fail() }
        func half(_ p: Int) -> Int { Int(bytes[p]) | Int(bytes[p+1]) << 8 }
        func word(_ p: Int) -> Int { (0..<4).reduce(0) { $0 | Int(bytes[p+$1]) << ($1*8) } }
        guard half(16) == 1, half(18) == 40, word(20) == 1, half(40) == 52, half(46) == 40 else { throw fail() }
        let offset = word(32), count = half(48), names = half(50)
        guard (1...512).contains(count), names > 0, names < count, offset >= 52,
              offset <= bytes.count, count <= (bytes.count-offset)/40 else { throw fail() }
        func section(_ index: Int) throws -> Data {
            let p = offset+index*40, start = word(p+16), size = word(p+20)
            guard start <= bytes.count, size <= bytes.count-start else { throw fail() }
            return Data(bytes[start..<start+size])
        }
        let strings = try section(names)
        var metadata: Data?
        for index in 0..<count {
            let nameOffset = word(offset+index*40)
            guard nameOffset < strings.count, let end = strings[nameOffset...].firstIndex(of: 0) else { throw fail() }
            if strings[nameOffset..<end] == Data(".modinfo".utf8) {
                guard metadata == nil, word(offset+index*40+4) == 1 else { throw fail() }
                metadata = try section(index)
            }
        }
        guard let metadata, metadata.count <= 65536 else { throw fail() }
        let fields = metadata.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        guard fields.filter({ $0.hasPrefix("vermagic=") }) == ["vermagic=3.4.112.madmonkey SMP preempt mod_unload modversions ARMv7 "],
              fields.filter({ $0.hasPrefix("depends=") }) == ["depends="] else { throw fail() }
    }
}
