import Foundation
import SWCompression

private final class PayloadResourceAnchor: NSObject {}

/// Loads and caches binary payloads needed for FEL boot:
/// fes1.bin (DRAM init SPL), uboot.bin (U-Boot), boot.img (kernel)
/// These are extracted from hakchi.hmod (a tar.gz archive).
actor PayloadService {
    static let shared = PayloadService()

    private var cachedFes1: Data?
    private var cachedUboot: Data?
    private var cachedBootImg: Data?
    private var cachedBaseHmods: Data?
    private var cachedHakchiHmod: Data?

    private init() {}

    /// Offline recovery validation ignores all caches and uses only pinned bundled bytes.
    func recoveryEvidence() async throws -> RecoveryPayloadEvidence {
        try RecoveryPayloadValidator.validate(
            fes1: loadBundledResource("fes1", ext: "bin", expectedSize: 14048),
            hmod: loadBundledResource("hakchi", ext: "hmod", expectedSize: 9340382),
            baseHmods: loadBundledResource("basehmods", ext: "tar", expectedSize: 1740800))
    }

    /// Raw pinned recovery bytes only; never consult cache/latest or AppConfig.
    func pinnedRecoveryInputs() throws -> RecoveryBootInputs {
        let fes1 = try loadBundledResource("fes1", ext: "bin", expectedSize: 14048)
        let hmod = try loadBundledResource("hakchi", ext: "hmod", expectedSize: 9340382)
        let base = try loadBundledResource("basehmods", ext: "tar", expectedSize: 1740800)
        _ = try RecoveryPayloadValidator.validate(fes1: fes1, hmod: hmod, baseHmods: base)
        let entries = try TarContainer.open(container: GzipArchive.unarchive(archive: hmod))
        return try RecoveryBootInputs(fes1: fes1,
            uboot: RecoveryPayloadValidator.member("boot/uboot.bin", entries: entries),
            bootImage: RecoveryPayloadValidator.member("boot/boot.img", entries: entries))
    }

    /// fes1.bin — Allwinner DRAM init SPL, loaded from bundled resource
    func fes1() throws -> Data {
        if let cached = cachedFes1 { return cached }
        let data = try loadBundledResource("fes1", ext: "bin")
        cachedFes1 = data
        print("[Payload] fes1.bin: \(data.count) bytes")
        return data
    }

    /// uboot.bin — U-Boot binary, extracted from hakchi.hmod
    func uboot() throws -> Data {
        if let cached = cachedUboot { return cached }
        let data = try extractFromHmod(path: "boot/uboot.bin")
        cachedUboot = data
        print("[Payload] uboot.bin: \(data.count) bytes")
        return data
    }

    /// boot.img — Custom recovery kernel image from hakchi.hmod; not an original stock kernel.
    /// FELService patches the cmdline to add "hakchi-shell" which starts the
    /// RNDIS gadget. Same boot.img as the upstream Windows client uses.
    func bootImg() throws -> Data {
        if let cached = cachedBootImg { return cached }
        let data = try extractFromHmod(path: "boot/boot.img")
        cachedBootImg = data
        print("[Payload] boot.img (from hmod): \(data.count) bytes")
        return data
    }

    /// basehmods.tar — Bundle of base hmods to install
    func baseHmods() throws -> Data {
        if let cached = cachedBaseHmods { return cached }
        let data = try loadBundledResource("basehmods", ext: "tar")
        cachedBaseHmods = data
        print("[Payload] basehmods.tar: \(data.count) bytes")
        return data
    }

    /// hakchi.hmod — The full hmod archive
    func hakchiHmod() throws -> Data {
        if let cached = cachedHakchiHmod { return cached }

        // Try cached download first
        let cachedPath = AppConfig.shared.dataDirectory
            .appendingPathComponent("hakchi-latest.hmod")
        if FileManager.default.fileExists(atPath: cachedPath.path),
           let data = try? Data(contentsOf: cachedPath), !data.isEmpty {
            cachedHakchiHmod = data
            print("[Payload] hakchi.hmod (cached): \(data.count) bytes")
            return data
        }

        // Fall back to bundled
        let data = try loadBundledResource("hakchi", ext: "hmod")
        cachedHakchiHmod = data
        print("[Payload] hakchi.hmod (bundled): \(data.count) bytes")
        return data
    }

    /// Extract a file from the hakchi.hmod tar.gz archive
    private func extractFromHmod(path: String) throws -> Data {
        let hmodData = try hakchiHmod()

        // Decompress gzip
        let tarData = try GzipArchive.unarchive(archive: hmodData)

        // Parse tar and find the entry
        let entries = try TarContainer.open(container: tarData)
        let searchPaths = [path, "./" + path]

        for entry in entries {
            let name = entry.info.name
            if searchPaths.contains(name) {
                guard let data = entry.data else {
                    throw PayloadError.emptyEntry(path)
                }
                return data
            }
        }

        throw PayloadError.entryNotFound(path)
    }

    /// Load a file from the app bundle's Resources directory.
    /// SPM bundles resources via Bundle.module if a resource processing
    /// rule is in Package.swift, but we're using a flat copy, so we
    /// look relative to the executable.
    private func loadBundledResource(_ name: String, ext: String, expectedSize: Int? = nil) throws -> Data {
        func read(_ url: URL) throws -> Data {
            if let expectedSize { return try RecoveryMaterialReader.readFile(at: url, maximumBytes: expectedSize, exactBytes: expectedSize) }
            return try Data(contentsOf: url)
        }
        let filename = "\(name).\(ext)"

        // Try Bundle.main first
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            print("[Payload] Found \(filename) in Bundle.main")
            return try read(url)
        }

        // Try the SPM resource bundle inside Bundle.main (app bundle layout)
        if let resBundle = Bundle.main.url(forResource: "SwiftHakchi_SwiftHakchi", withExtension: "bundle"),
           let nested = Bundle(url: resBundle),
           let url = nested.url(forResource: name, withExtension: ext) {
            print("[Payload] Found \(filename) in nested SPM bundle")
            return try read(url)
        }

        // A test runner is not our executable. Resolve resources beside the module's
        // actual image too, without invoking Bundle.module's fatal missing-bundle fallback.
        let module = Bundle(for: PayloadResourceAnchor.self)
        for root in [module.resourceURL, module.bundleURL.deletingLastPathComponent()] {
            guard let root,
                  let bundle = Bundle(url: root.appendingPathComponent("SwiftHakchi_SwiftHakchi.bundle")),
                  let url = bundle.url(forResource: name, withExtension: ext) else { continue }
            return try read(url)
        }

        // Try next to the executable (SPM debug builds via `swift run`)
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let spmBundle = execURL.appendingPathComponent("SwiftHakchi_SwiftHakchi.bundle")
            .appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: spmBundle.path) {
            print("[Payload] Found \(filename) next to executable")
            return try read(spmBundle)
        }

        // Try the source Resources directory (development builds)
        let sourceRes = execURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SwiftHakchi/Resources")
            .appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: sourceRes.path) {
            print("[Payload] Found \(filename) in source Resources")
            return try read(sourceRes)
        }

        print("[Payload] ERROR: \(filename) not found in any search path")
        throw PayloadError.resourceNotFound(filename)
    }
}

enum PayloadError: Error, LocalizedError {
    case resourceNotFound(String)
    case entryNotFound(String)
    case emptyEntry(String)

    var errorDescription: String? {
        switch self {
        case .resourceNotFound(let name):
            return "Resource not found: \(name)"
        case .entryNotFound(let path):
            return "Entry not found in hmod archive: \(path)"
        case .emptyEntry(let path):
            return "Empty entry in hmod archive: \(path)"
        }
    }
}
