import Foundation
import SwiftHakchiCore
import SWCompression

/// A purpose-specific, non-Codable capability; edited manifest flags cannot construct it.
struct PreparedSNESRAMProbe: Sendable {
    let image: Data, fes1: Data, uboot: Data
    let nonce: String
    let binding: SNESRuntimeBinding
    let hashes: [String: String]
    let source: SNESOfflineSource, runtime: SNESRuntimeMaterial
    fileprivate let imageSHA256: String
    fileprivate let recoveryInputs: RecoveryBootInputs
    fileprivate init(image: Data, recovery: PreparedRecoveryBoot, nonce: String, source: SNESOfflineSource,
                     runtime: SNESRuntimeMaterial, hashes: [String: String], rawRecovery: RecoveryBootInputs) {
        self.image = image; fes1 = recovery.fes1; uboot = recovery.uboot; self.nonce = nonce
        self.source = source; self.runtime = runtime; binding = source.runtimeBinding; self.hashes = hashes
        imageSHA256 = BackupManifest.digest(image); recoveryInputs = rawRecovery
    }
    func validateCurrent() throws {
        try source.revalidate(); try runtime.revalidate(source: source)
        guard binding == runtime.binding, BackupManifest.digest(image) == imageSHA256,
              BackupManifest.digest(fes1) == RecoveryPayloadValidator.fes1SHA256 else { throw SNESRuntimeBinding.failure() }
        _ = try LegacyBootImageBuilder.inspect(image)
    }
    fileprivate struct Manifest: Codable {
        let schemaVersion: Int, complete: Bool, firmwareRestoreEligible: Bool
        let scope: String, sourcePath: String, runtimePath: String
        let sourceManifestSHA256: String, runtimeFrameSHA256: String, nonce: String, imageSHA256: String
    }
    func checkedExport() throws -> (files: [String: Data], manifest: Data) {
        try validateCurrent()
        guard let directory = runtime.directoryURL else { throw SNESRuntimeBinding.failure() }
        let m = Manifest(schemaVersion: 1, complete: true, firmwareRestoreEligible: false, scope: "snes-isolated-ram-probe",
            sourcePath: source.directoryURL.path, runtimePath: directory.path, sourceManifestSHA256: source.manifestSHA256,
            runtimeFrameSHA256: BackupManifest.digest(runtime.frame.encoded), nonce: nonce, imageSHA256: imageSHA256)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (["probe.img": image], try encoder.encode(m))
    }
}

enum SNESRAMProbeRecipe {
    static let daemonSHA256 = "8d36e4c280c7a8f5ce7a4639ffb103947dc4eee7f261230a0cda6b8092e2dfee"
    /// Fixed temporary diagnostic output only; never accepts a new root or entry point.
    static func consoleTraceCommandLine(_ command: String) throws -> String {
        let tokens = command.split(separator: " ").map(String.init)
        guard command.utf8.allSatisfy({ (32...126).contains($0) }), tokens.contains("ro"),
              tokens.filter({ $0.hasPrefix("root=") }) == ["root=/dev/nandb"],
              tokens.allSatisfy({ $0 != "rw" && !$0.hasPrefix("rdinit=") && !$0.contains("hakchi-") &&
                  (!$0.hasPrefix("init=") || $0 == "init=/init") }) else { throw SNESRuntimeBinding.failure() }
        let result = (tokens.filter { !$0.hasPrefix("loglevel=") && $0 != "console=tty0" } + ["console=tty0", "loglevel=7"]).joined(separator: " ")
        guard result.utf8.count < 512 else { throw SNESRuntimeBinding.failure() }
        return result
    }
    static func prepare(source: SNESOfflineSource, runtime: SNESRuntimeMaterial, kernel: Data, hmod: Data,
                        busybox: Data, recovery: RecoveryBootInputs, nonce: String) throws -> PreparedSNESRAMProbe {
        guard hmod.count <= 1024*1024,
              BackupManifest.digest(hmod) == "04029161cb7e14b625de3f16edf5485d72e3cc80f9936c38b5a98d7414f4e0fd" else { throw SNESRuntimeBinding.failure() }
        let archive = hmod.starts(with: [0x1f, 0x8b]) ? try GzipArchive.unarchive(archive: hmod) : hmod
        let daemon = try RecoveryPayloadValidator.member("bin/clovershell", entries: TarContainer.open(container: archive))
        return try assemble(source: source, runtime: runtime, kernel: kernel, daemon: daemon, busybox: busybox,
                            recovery: recovery, nonce: nonce)
    }
    private static func assemble(source: SNESOfflineSource, runtime: SNESRuntimeMaterial, kernel: Data,
                                 daemon: Data, busybox: Data, recovery: RecoveryBootInputs, nonce: String) throws -> PreparedSNESRAMProbe {
        try Task.checkCancellation(); try source.revalidate(); try runtime.revalidate(source: source)
        guard runtime.binding == source.runtimeBinding, kernel.count == 2_624_208,
              BackupManifest.digest(kernel) == SNESOfflineImageBuild.kernelSHA256,
              daemon.count == 23740, BackupManifest.digest(daemon) == daemonSHA256,
              busybox.count == 1_427_376, BackupManifest.digest(busybox) == SNESRAMProbeScripts.busyboxSHA256 else { throw SNESRuntimeBinding.failure() }
        // The hash-pinned daemon contains this literal build-option RPATH. Startup
        // explicitly inhibits its RPATH; captured libraries accept no RPATH at all.
        let daemonELF = try ARMRuntimeELF(data: daemon, allowedRPath: "-nostartfiles"), busyboxELF = try ARMRuntimeELF(data: busybox)
        guard daemonELF.interpreter == "/lib/ld-linux-armhf.so.3",
              Set(daemonELF.dependencies) == Set(["libc.so.6", "ld-linux-armhf.so.3"]),
              busyboxELF.interpreter == nil, busyboxELF.dependencies.isEmpty else { throw SNESRuntimeBinding.failure() }
        for applet in ["sha256sum", "devmem", "awk", "sleep", "mkdir", "mount", "cat", "uname", "sh"] {
            guard busybox.range(of: Data((applet + "\0").utf8)) != nil else { throw SNESRuntimeBinding.failure() }
        }
        let prepared = try recovery.prepare()
        let original = try LegacyBootImageBuilder.inspect(source.stock)
        let command = String(decoding: original.header[64..<576].prefix { $0 != 0 }, as: UTF8.self).split(separator: " ")
        guard command.contains("ro"), command.allSatisfy({ token in
            token != "rw" && !token.hasPrefix("rdinit=") && !token.contains("hakchi-") &&
            (!token.hasPrefix("init=") || token == "init=/init") && (!token.hasPrefix("root=") || token == "root=/dev/nandb")
        }) else { throw SNESRuntimeBinding.failure() }
        let scripts = try SNESRAMProbeScripts(binding: source.runtimeBinding, nonce: nonce,
            loaderSHA256: BackupManifest.digest(runtime.frame.loader), libcSHA256: BackupManifest.digest(runtime.frame.libc),
            daemonSHA256: daemonSHA256)
        var files: [String: Data] = ["probe/busybox": busybox, "probe/ld-linux-armhf.so.3": runtime.frame.loader,
            "probe/libc.so.6": runtime.frame.libc, "probe/clovershell": daemon,
            "probe/nonce": Data((nonce + "\n").utf8), "probe/early-init": Data(scripts.earlyInit.utf8), "probe/report": Data(scripts.report.utf8)]
        let checks = (["init": Data(scripts.entryPoint.utf8)] .merging(files) { _, new in new }).keys.sorted().map { name in
            let bytes = name == "init" ? Data(scripts.entryPoint.utf8) : files[name]!
            return BackupManifest.digest(bytes) + "  /" + name + "\n"
        }.joined()
        files["probe/files.sha256"] = Data(checks.utf8)
        func entry(_ name: String, mode: UInt32, data: Data, inode: UInt32) -> NewcEntry {
            .init(name: name, fields: [inode, mode, 0, 0, mode & 0xf000 == 0x4000 ? 2 : 1, 0, UInt32(data.count), 0, 0, 0, 0, UInt32(name.utf8.count+1), 0], data: data)
        }
        var additions = [entry("probe", mode: 0o40700, data: Data(), inode: 10000)]
        for (index, name) in files.keys.sorted().enumerated() {
            let executable = ["probe/busybox", "probe/ld-linux-armhf.so.3", "probe/clovershell", "probe/early-init", "probe/report"].contains(name)
            additions.append(entry(name, mode: executable ? 0o100700 : 0o100600, data: files[name]!, inode: UInt32(10001+index)))
        }
        let modified = try original.archive.updating(replacements: ["init": Data(scripts.entryPoint.utf8)], additions: additions)
        guard modified.entries.first(where: { $0.name == "key-file" }) == original.archive.entries.first(where: { $0.name == "key-file" }) else { throw SNESRuntimeBinding.failure() }
        var image = try LegacyBootImageBuilder.build(source: source.stock, kernel: kernel, archive: modified)
        let originalCommand = String(decoding: original.header[64..<576].prefix { $0 != 0 }, as: UTF8.self)
        let traceCommand = Data(try consoleTraceCommandLine(originalCommand).utf8)
        image.replaceSubrange(64..<576, with: traceCommand + Data(count: 512-traceCommand.count))
        let checked = try LegacyBootImageBuilder.inspect(image)
        guard checked.archive == modified, checked.kernel == kernel else { throw SNESRuntimeBinding.failure() }
        var hashes: [String: String] = [:]
        for (label, name) in [("INIT_SHA", "probe/early-init"), ("REPORT_SHA", "probe/report"), ("LOADER_SHA", "probe/ld-linux-armhf.so.3"),
                              ("LIBC_SHA", "probe/libc.so.6"), ("DAEMON_SHA", "probe/clovershell"), ("BUSYBOX_SHA", "probe/busybox")] {
            hashes[label] = BackupManifest.digest(files[name]!)
        }
        return PreparedSNESRAMProbe(image: image, recovery: prepared, nonce: nonce, source: source, runtime: runtime, hashes: hashes, rawRecovery: recovery)
    }
    /// New temporary purposes receive a fresh nonce while retaining the same exact pinned materials.
    static func withNonce(_ probe: PreparedSNESRAMProbe, nonce: UUID) throws -> PreparedSNESRAMProbe {
        try probe.validateCurrent()
        if probe.nonce == nonce.uuidString { return probe }
        let image = try LegacyBootImageBuilder.inspect(probe.image)
        func member(_ name: String) throws -> Data {
            guard let e = image.archive.entries.first(where: { $0.name == name }), e.fields[1] & 0xf000 == 0x8000 else { throw SNESRuntimeBinding.failure() }
            return e.data
        }
        // assemble needs the raw pinned recovery inputs, not the previously patched U-Boot.
        return try assemble(source: probe.source, runtime: probe.runtime, kernel: image.kernel,
            daemon: member("probe/clovershell"), busybox: member("probe/busybox"),
            recovery: probe.recoveryInputs, nonce: nonce.uuidString)
    }
    /// Reconstruct a saved base image from its original pinned inputs, never editable flags.
    static func reconstruct(image: Data, source: SNESOfflineSource, runtime: SNESRuntimeMaterial,
                            recovery: RecoveryBootInputs, nonce: String) throws -> PreparedSNESRAMProbe {
        let contents = try LegacyBootImageBuilder.inspect(image)
        func member(_ name: String) throws -> Data {
            guard let e = contents.archive.entries.first(where: { $0.name == name }), e.fields[1] & 0xf000 == 0x8000 else { throw SNESRuntimeBinding.failure() }
            return e.data
        }
        let result = try assemble(source: source, runtime: runtime, kernel: contents.kernel,
            daemon: member("probe/clovershell"), busybox: member("probe/busybox"), recovery: recovery, nonce: nonce)
        guard result.image == image else { throw SNESRuntimeBinding.failure() }
        return result
    }
    static func load(directory url: URL, recovery: RecoveryBootInputs) throws -> PreparedSNESRAMProbe {
        let directory = try RestoreDirectory(url)
        guard directory.url.lastPathComponent.hasPrefix("SNES-RAM-Probe-") else { throw SNESRuntimeBinding.failure() }
        let m = try JSONDecoder().decode(PreparedSNESRAMProbe.Manifest.self, from: directory.read("manifest.json", maximum: 65536))
        guard m.schemaVersion == 1, m.complete, !m.firmwareRestoreEligible, m.scope == "snes-isolated-ram-probe",
              [m.sourcePath, m.runtimePath].allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4096 }) else { throw SNESRuntimeBinding.failure() }
        let source = try SNESOfflineSource.load(snapshot: URL(fileURLWithPath: m.sourcePath))
        let runtime = try SNESRuntimeMaterial.load(directory: URL(fileURLWithPath: m.runtimePath), source: source)
        let image = try directory.read("probe.img")
        guard m.sourceManifestSHA256 == source.manifestSHA256,
              m.runtimeFrameSHA256 == BackupManifest.digest(runtime.frame.encoded), m.imageSHA256 == BackupManifest.digest(image) else { throw SNESRuntimeBinding.failure() }
        let contents = try LegacyBootImageBuilder.inspect(image)
        func member(_ path: String) throws -> Data {
            guard let entry = contents.archive.entries.first(where: { $0.name == path }), entry.fields[1] & 0xf000 == 0x8000 else { throw SNESRuntimeBinding.failure() }
            return entry.data
        }
        let result = try assemble(source: source, runtime: runtime, kernel: contents.kernel,
            daemon: member("probe/clovershell"), busybox: member("probe/busybox"), recovery: recovery, nonce: m.nonce)
        guard result.image == image else { throw SNESRuntimeBinding.failure() }
        try directory.check(); return result
    }
}
