import Foundation
import SwiftHakchiCore

/// Frozen prior inventories. Component bytes remain diagnostic data, never a boot capability.
struct SNESOriginalComponentSource: Sendable {
    struct Expected: Sendable { let path: String, count: Int, digest: String }
    let material: SNESMenuSupportMaterial
    let expected: [Expected]
    private struct Seal: Sendable { let url: URL, files: [String: Data] }
    private let seals: [Seal]
    var evidenceDirectories:[URL] {seals.map(\.url)}
    init(material: SNESMenuSupportMaterial) throws {
        // Material is already fully reconstructed by its private loader. Audit
        // the base once, then pin all transitive bytes instead of recursively
        // rebuilding the same object graph before every USB operation.
        try material.setup.revalidate()
        let kernel = try LegacyBootImageBuilder.inspect(material.setup.stock).kernel
        guard kernel.count == 1_899_024,
              BackupManifest.digest(kernel) == "512d0d6d4610721589acf7b0fed1668de3e141a0a2cb759e8885662e1652b7da" else { throw SNESOriginalComponentFrame.failure() }
        var expected: [Expected] = []
        for path in SNESOriginalComponentFrame.paths {
            let records = path == "usr/bin/clover-mcp" ? material.frame.records : material.source.preparation.startup.records
            guard let record = records.first(where: { $0.path == path }),
                  record.kind == (path == "usr/bin/clover-mcp" ? "B" : "M"),
                  (1...262144).contains(record.count), record.digest.count == 64, SNESRuntimeBinding.hex(record.digest) else { throw SNESOriginalComponentFrame.failure() }
            expected.append(.init(path: path, count: record.count, digest: record.digest))
        }
        guard expected.reduce(0, { $0 + $1.count }) < SNESOriginalComponentFrame.maximumSize else { throw SNESOriginalComponentFrame.failure() }
        let prep = material.source.preparation, base = prep.source
        let setupDirectory = try RestoreDirectory(material.setup.directoryURL)
        let setupManifest = try setupDirectory.read("manifest.json", maximum: 65536)
        guard BackupManifest.digest(setupManifest) == material.setup.manifestSHA256 else { throw SNESOriginalComponentFrame.failure() }
        var setupFiles = ["manifest.json": setupManifest, "active-boot2.img": material.setup.stock,
            "boot1.bin": base.boot1, "partitions.txt": base.partitions, "data-header.bin": base.header]
        if try setupDirectory.names().contains("backup-boot2.img") { setupFiles["backup-boot2.img"] = try setupDirectory.read("backup-boot2.img") }
        func manifest(_ url: URL, hash: String) throws -> Data {
            let bytes = try RestoreDirectory(url).read("manifest.json", maximum: 65536)
            guard BackupManifest.digest(bytes) == hash else { throw SNESOriginalComponentFrame.failure() }; return bytes
        }
        let prepFiles = ["manifest.json": try manifest(material.source.directoryURL, hash: material.source.manifestSHA256),
            "stock.img": material.setup.stock, "boot1.bin": base.boot1, "partitions.txt": base.partitions,
            "data-header.bin": prep.header, "startup.frame": prep.startup.raw]
        let supportFiles = ["manifest.json": try manifest(material.directoryURL, hash: material.manifestSHA256), "support.frame": material.frame.raw]
        self.material = material; self.expected = expected
        seals = [.init(url: material.setup.directoryURL, files: setupFiles), .init(url: material.source.directoryURL, files: prepFiles), .init(url: material.directoryURL, files: supportFiles)]
        try revalidate(); try material.setup.revalidate()
    }
    func revalidate() throws {
        for seal in seals {
            let dir = try RestoreDirectory(seal.url)
            for (name, expected) in seal.files {
                guard try dir.read(name, maximum: max(expected.count, 1)) == expected else { throw SNESOriginalComponentFrame.failure() }
            }
            try dir.check()
        }
    }
    /// This capture permits only the recovery profile's RAM/system mounts and
    /// the single read-only original root. Data mounted anywhere is refused.
    func requireObservation(_ observation: RecoveryProbeObservation) throws {
        try material.source.preparation.source.requireObservation(observation)
        let pseudo = ["/": "rootfs", "/dev": "devtmpfs", "/proc": "proc",
            "/sys": "sysfs", "/dev/pts": "devpts", "/dev/shm": "tmpfs"]
        var seen: Set<String> = []
        for mount in observation.mounts {
            let fields = mount.split(separator: " ").map(String.init)
            guard fields.count == 6, seen.insert(fields[1]).inserted else { throw SNESOriginalComponentFrame.failure() }
            if fields[1] == "/newroot" {
                guard fields[2] == "squashfs" else { throw SNESOriginalComponentFrame.failure() }
            } else {
                guard let type = pseudo[fields[1]], fields[2] == type,
                      fields[0] == (fields[1] == "/sys" ? "sys" : type) else { throw SNESOriginalComponentFrame.failure() }
            }
        }
    }
    func validate(_ frame: SNESOriginalComponentFrame) throws {
        guard frame.records.count == expected.count else { throw SNESOriginalComponentFrame.failure() }
        for (record, pin) in zip(frame.records, expected) {
            guard record.path == pin.path, record.count == pin.count, record.digest == pin.digest else { throw SNESOriginalComponentFrame.failure() }
        }
    }
}
struct SNESOriginalComponentResult: Sendable {
    let source: SNESOriginalComponentSource, frame: SNESOriginalComponentFrame
    let before: RecoveryProbeUSBDevice, after: RecoveryProbeUSBDevice, observation: RecoveryProbeObservation
    func checkedExport() throws -> (files: [String: Data], manifest: Data) {
        try Task.checkCancellation(); try source.revalidate()
        let checked = try SNESOriginalComponentFrame(frame.raw); try source.validate(checked)
        try source.requireObservation(observation)
        guard try RecoveryProbePolicy.after([after], original: before) == after else { throw SNESOriginalComponentFrame.failure() }
        struct Manifest: Encodable {
            let schemaVersion = 1, complete = true, firmwareWritten = false, firmwareRestoreEligible = false
            let scope = "snes-original-components-capture", matchingReadCount = 2
            let binding: SNESRuntimeBinding
            let preparation: String, preparationManifestSHA256: String, support: String, supportManifestSHA256: String, frameSHA256: String
            let before: RecoveryProbeUSBDevice, after: RecoveryProbeUSBDevice, observation: RecoveryProbeObservation
        }
        let material = source.material
        let manifest = Manifest(binding: material.setup.runtimeBinding,
            preparation: material.source.directoryURL.lastPathComponent, preparationManifestSHA256: material.source.manifestSHA256,
            support: material.directoryURL.lastPathComponent, supportManifestSHA256: material.manifestSHA256,
            frameSHA256: BackupManifest.digest(frame.raw), before: before, after: after, observation: observation)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try source.revalidate()
        return (["components.frame": frame.raw], try encoder.encode(manifest))
    }
}
struct SNESOriginalComponentMaterial: Sendable {
    let source: SNESOriginalComponentSource, frame: SNESOriginalComponentFrame, directoryURL: URL, manifestSHA256: String
    private struct Manifest: Decodable { let before: RecoveryProbeUSBDevice, after: RecoveryProbeUSBDevice, observation: RecoveryProbeObservation }
    static func load(source: SNESOriginalComponentSource, directory url: URL) throws -> Self {
        try source.revalidate()
        let dir = try RestoreDirectory(url), prefix = "SNES-Original-Components-"
        guard dir.url.lastPathComponent.hasPrefix(prefix), UUID(uuidString: String(dir.url.lastPathComponent.dropFirst(prefix.count))) != nil else { throw SNESOriginalComponentFrame.failure() }
        let raw = try dir.read("manifest.json", maximum: 65536), saved = try JSONDecoder().decode(Manifest.self, from: raw)
        let frame = try SNESOriginalComponentFrame(dir.read("components.frame", maximum: SNESOriginalComponentFrame.maximumSize))
        let result = SNESOriginalComponentResult(source: source, frame: frame, before: saved.before, after: saved.after, observation: saved.observation)
        let checked = try result.checkedExport()
        guard let actual = try JSONSerialization.jsonObject(with: checked.manifest) as? NSDictionary,
              let expected = try JSONSerialization.jsonObject(with: raw) as? [String: Any], actual.isEqual(to: expected) else { throw SNESOriginalComponentFrame.failure() }
        try dir.check(); try source.revalidate()
        return Self(source: source, frame: frame, directoryURL: dir.url, manifestSHA256: BackupManifest.digest(raw))
    }
    func revalidate() throws {
        let current = try Self.load(source: source, directory: directoryURL)
        guard current.manifestSHA256 == manifestSHA256, current.frame.raw == frame.raw else { throw SNESOriginalComponentFrame.failure() }
    }
}
struct SNESOriginalComponentFailure: Error, LocalizedError, Sendable {
    let source: SNESOriginalComponentSource, stage: String, frame: Data, log: Data
    var errorDescription: String? { "The original component check stopped. Private details were saved on this Mac; nothing was installed." }
    init(source: SNESOriginalComponentSource, stage: String, frame: Data, log: Data = Data()) {
        self.source = source; self.stage = stage; self.frame = Data(frame.prefix(SNESOriginalComponentFrame.maximumSize)); self.log = Data(log.prefix(16384))
    }
    func checkedExport() throws -> (files: [String: Data], manifest: Data) {
        let material = source.material, binding = material.setup.runtimeBinding
        try binding.validate()
        struct Manifest: Encodable {
            let schemaVersion = 1, complete = false, firmwareWritten = false, firmwareRestoreEligible = false
            let scope = "snes-original-components-diagnostic"
            let binding: SNESRuntimeBinding
            let preparation: String, preparationManifestSHA256: String, support: String, supportManifestSHA256: String, stage: String
            let frameBytes: Int, frameSHA256: String, stageLogBytes: Int, stageLogSHA256: String
        }
        let hash = BackupManifest.digest(frame), logHash = BackupManifest.digest(log)
        let manifest = Manifest(binding: binding,
            preparation: material.source.directoryURL.lastPathComponent, preparationManifestSHA256: material.source.manifestSHA256,
            support: material.directoryURL.lastPathComponent, supportManifestSHA256: material.manifestSHA256, stage: stage,
            frameBytes: frame.count, frameSHA256: hash, stageLogBytes: log.count, stageLogSHA256: logHash)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (["rejected.frame": Data("SWIFTHAKCHI_REJECTED_COMPONENTS_V1 \(frame.count) \(hash)\n".utf8) + frame,
                 "stages.log": Data("SWIFTHAKCHI_COMPONENT_LOG_V1 \(log.count) \(logHash)\n".utf8) + log], try encoder.encode(manifest))
    }
}
