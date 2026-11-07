import Foundation
import SwiftHakchiCore
import SWCompression

/// Purpose-specific original-kernel RAM capability. No firmware writer or legacy menu accepts it.
struct PreparedSNESOriginalMenu: Sendable {
    let image: Data, fes1: Data, uboot: Data, material: SNESOriginalMenuMaterial, nonce: String
    let filesSHA256: String, sourceFilesSHA256: String, componentsSHA256: String
    fileprivate let imageSHA256: String
    fileprivate init(image: Data, recovery: PreparedRecoveryBoot, material: SNESOriginalMenuMaterial,
                     nonce: String, files: Data, sourceFiles: Data, components: Data) {
        self.image = image; fes1 = recovery.fes1; uboot = recovery.uboot; self.material = material; self.nonce = nonce
        imageSHA256 = BackupManifest.digest(image); filesSHA256 = BackupManifest.digest(files)
        sourceFilesSHA256 = BackupManifest.digest(sourceFiles); componentsSHA256 = BackupManifest.digest(components)
    }
    /// Only for the separately approved, RAM-only compatibility-menu trial.
    init(temporaryCompatibilityTrial trial: SNESRAMCompatibilityMenuBuilder.Result,
         basedOn original: PreparedSNESOriginalMenu) throws {
        try original.validateCurrent()
        guard try LegacyBootImageBuilder.inspect(trial.image).kernel == original.material.kernel else {
            throw SNESRuntimeBinding.failure()
        }
        image = trial.image; fes1 = original.fes1; uboot = original.uboot
        material = original.material; nonce = original.nonce
        imageSHA256 = BackupManifest.digest(trial.image); filesSHA256 = trial.filesSHA256
        sourceFilesSHA256 = original.sourceFilesSHA256; componentsSHA256 = original.componentsSHA256
        try validateCurrent()
    }
    func validateCurrent() throws {
        try Task.checkCancellation(); try material.revalidate()
        guard BackupManifest.digest(image) == imageSHA256,
              BackupManifest.digest(fes1) == RecoveryPayloadValidator.fes1SHA256,
              try LegacyBootImageBuilder.inspect(image).kernel == material.kernel else { throw SNESRuntimeBinding.failure() }
    }
    fileprivate struct Manifest: Codable {
        let schemaVersion: Int, complete: Bool, firmwareWritten: Bool, firmwareRestoreEligible: Bool
        let scope: String, setupPath: String, preparationPath: String, supportPath: String, componentsPath: String, runtimePath: String
        let setupSHA256: String, componentManifestSHA256: String, imageSHA256: String, nonce: String
    }
    func checkedExport() throws -> (files: [String: Data], manifest: Data) {
        try validateCurrent()
        guard let runtime = material.runtime.directoryURL else { throw SNESRuntimeBinding.failure() }
        let support = material.support
        let m = Manifest(schemaVersion: 1, complete: true, firmwareWritten: false, firmwareRestoreEligible: false,
            scope: "snes-original-menu-image", setupPath: support.setup.directoryURL.path,
            preparationPath: support.source.directoryURL.path, supportPath: support.directoryURL.path,
            componentsPath: material.components.directoryURL.path, runtimePath: runtime.path,
            setupSHA256: support.setup.manifestSHA256, componentManifestSHA256: material.components.manifestSHA256,
            imageSHA256: imageSHA256, nonce: nonce)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (["original-menu.img": image], try encoder.encode(m))
    }
}
enum SNESOriginalMenuRecipe {
    static func prepare(material: SNESOriginalMenuMaterial, daemonHmod: Data, busybox: Data,
                        recovery: RecoveryBootInputs, nonce: UUID = UUID()) throws -> PreparedSNESOriginalMenu {
        guard daemonHmod.count <= 1024*1024, BackupManifest.digest(daemonHmod) == "04029161cb7e14b625de3f16edf5485d72e3cc80f9936c38b5a98d7414f4e0fd" else { throw SNESRuntimeBinding.failure() }
        let tar = daemonHmod.starts(with: [31,139]) ? try GzipArchive.unarchive(archive: daemonHmod) : daemonHmod
        let daemon = try RecoveryPayloadValidator.member("bin/clovershell", entries: TarContainer.open(container: tar))
        return try assemble(material: material, daemon: daemon, busybox: busybox, recovery: recovery, nonce: nonce)
    }
    /// Rebuilds with current scripts, using only the independently pinned helper
    /// binaries from an archived temporary image. No old image is booted.
    static func prepare(material: SNESOriginalMenuMaterial, archivedImage: Data,
                        recovery: RecoveryBootInputs, nonce: UUID = UUID()) throws -> PreparedSNESOriginalMenu {
        let archive = try LegacyBootImageBuilder.inspect(archivedImage).archive
        func regular(_ name: String) throws -> Data {
            guard let entry = archive.entries.first(where: { $0.name == name }),
                  entry.fields[1] & 0xf000 == 0x8000 else { throw SNESRuntimeBinding.failure() }
            return entry.data
        }
        return try assemble(material: material, daemon: regular("probe/clovershell"), busybox: regular("probe/busybox"), recovery: recovery, nonce: nonce)
    }
    private static func assemble(material: SNESOriginalMenuMaterial, daemon: Data, busybox: Data,
                                 recovery: RecoveryBootInputs, nonce: UUID) throws -> PreparedSNESOriginalMenu {
        try material.revalidate()
        guard daemon.count == 23740, BackupManifest.digest(daemon) == SNESRAMProbeRecipe.daemonSHA256,
              busybox.count == 1_427_376, BackupManifest.digest(busybox) == SNESRAMProbeScripts.busyboxSHA256 else { throw SNESRuntimeBinding.failure() }
        let daemonELF = try ARMRuntimeELF(data: daemon, allowedRPath: "-nostartfiles"), bbELF = try ARMRuntimeELF(data: busybox)
        guard daemonELF.interpreter == "/lib/ld-linux-armhf.so.3",
              Set(daemonELF.dependencies) == Set(["libc.so.6", "ld-linux-armhf.so.3"]),
              bbELF.interpreter == nil, bbELF.dependencies.isEmpty else { throw SNESRuntimeBinding.failure() }
        let prepared = try recovery.prepare()
        let stock = try LegacyBootImageBuilder.inspect(material.support.setup.stock)
        let scripts = try SNESRAMProbeScripts(binding: material.binding, nonce: nonce.uuidString,
            loaderSHA256: BackupManifest.digest(material.runtime.frame.loader), libcSHA256: BackupManifest.digest(material.runtime.frame.libc),
            daemonSHA256: SNESRAMProbeRecipe.daemonSHA256)
        var files = try SNESOriginalMenuScripts.assets(base: scripts, sourceFiles: material.support.sourceFiles)
        files["init"] = Data(scripts.entryPoint.utf8)
        files["probe/busybox"] = busybox; files["probe/clovershell"] = daemon
        files["probe/ld-linux-armhf.so.3"] = material.runtime.frame.loader; files["probe/libc.so.6"] = material.runtime.frame.libc
        files["probe/nonce"] = Data((nonce.uuidString + "\n").utf8)
        for (name,bytes) in material.drivers { files["probe/" + name] = bytes }
        let components = Data(material.drivers.keys.sorted().map { BackupManifest.digest(material.drivers[$0]!) + "  /probe/" + $0 + "\n" }.joined().utf8)
        files["probe/components.sha256"] = components
        var checkedFiles = Dictionary(uniqueKeysWithValues: stock.archive.entries.filter { $0.fields[1] & 0xf000 == 0x8000 }.map { ($0.name, $0.data) })
        checkedFiles.merge(files) { _, replacement in replacement }
        let checks = Data(checkedFiles.keys.sorted().map { BackupManifest.digest(checkedFiles[$0]!) + "  /" + $0 + "\n" }.joined().utf8)
        files["probe/files.sha256"] = checks
        let existing = Set(stock.archive.entries.map(\.name))
        var additions: [NewcEntry] = []
        func add(_ name: String, mode: UInt32, data: Data) {
            additions.append(.init(name: name, fields: [UInt32(30000+additions.count), mode, 0, 0,
                mode & 0xf000 == 0x4000 ? 2 : 1, 0, UInt32(data.count), 0, 0, 0, 0, UInt32(name.utf8.count+1), 0], data: data))
        }
        for name in ["probe", "probe/rules", "probe/empty-rules"] { guard !existing.contains(name) else { throw SNESRuntimeBinding.failure() }; add(name, mode: 0o40700, data: Data()) }
        let executable = Set(["probe/busybox", "probe/ld-linux-armhf.so.3", "probe/clovershell", "probe/early-init", "probe/checkpoint", "probe/launch", "probe/report", "probe/diagnostics", "probe/run", "probe/shutdown"])
        for name in files.keys.sorted() where name != "init" {
            guard !existing.contains(name) else { throw SNESRuntimeBinding.failure() }
            add(name, mode: executable.contains(name) ? 0o100700 : 0o100600, data: files[name]!)
        }
        let archive = try stock.archive.updating(replacements: ["init": files["init"]!], additions: additions)
        var image = try LegacyBootImageBuilder.build(source: material.support.setup.stock, kernel: material.kernel, archive: archive)
        let command = String(decoding: stock.header[64..<576].prefix { $0 != 0 }, as: UTF8.self)
        let trace = Data(try SNESRAMProbeRecipe.consoleTraceCommandLine(command).utf8)
        image.replaceSubrange(64..<576, with: trace + Data(count: 512-trace.count))
        let checked = try LegacyBootImageBuilder.inspect(image)
        guard checked.kernel == material.kernel, checked.archive == archive else { throw SNESRuntimeBinding.failure() }
        for entry in stock.archive.entries where entry.name != "init" {
            var expected = entry; if entry.name == "." { expected.fields[4] += 1 }
            guard checked.archive.entries.first(where: { $0.name == entry.name }) == expected else { throw SNESRuntimeBinding.failure() }
        }
        try material.revalidate()
        return .init(image: image, recovery: prepared, material: material, nonce: nonce.uuidString,
            files: checks, sourceFiles: Data(material.support.sourceFiles.utf8), components: components)
    }
    static func load(directory url: URL, recovery: RecoveryBootInputs) throws -> PreparedSNESOriginalMenu {
        let dir = try RestoreDirectory(url), prefix = "SNES-Original-Menu-"
        guard dir.url.lastPathComponent.hasPrefix(prefix), UUID(uuidString: String(dir.url.lastPathComponent.dropFirst(prefix.count))) != nil else { throw SNESRuntimeBinding.failure() }
        let raw = try dir.read("manifest.json", maximum: 65536), m = try JSONDecoder().decode(PreparedSNESOriginalMenu.Manifest.self, from: raw)
        guard m.schemaVersion == 1, m.complete, !m.firmwareWritten, !m.firmwareRestoreEligible, m.scope == "snes-original-menu-image",
              [m.setupPath,m.preparationPath,m.supportPath,m.componentsPath,m.runtimePath].allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4096 }),
              let nonce = UUID(uuidString: m.nonce), nonce.uuidString == m.nonce else { throw SNESRuntimeBinding.failure() }
        let setup = try SNESOfflineSource.load(snapshot: URL(fileURLWithPath: m.setupPath))
        let supportSource = try SNESMenuSupportSource.load(setup: setup, preparation: URL(fileURLWithPath: m.preparationPath))
        let support = try SNESMenuSupportMaterial.load(source: supportSource, directory: URL(fileURLWithPath: m.supportPath))
        let components = try SNESOriginalComponentMaterial.load(source: SNESOriginalComponentSource(material: support), directory: URL(fileURLWithPath: m.componentsPath))
        let runtime = try SNESRuntimeMaterial.load(directory: URL(fileURLWithPath: m.runtimePath), source: setup)
        let material = try SNESOriginalMenuMaterial(components: components, runtime: runtime)
        let image = try dir.read("original-menu.img"), contents = try LegacyBootImageBuilder.inspect(image)
        func member(_ name: String) throws -> Data {
            guard let e = contents.archive.entries.first(where: { $0.name == name }), e.fields[1] & 0xf000 == 0x8000 else { throw SNESRuntimeBinding.failure() }; return e.data
        }
        let result = try assemble(material: material, daemon: member("probe/clovershell"), busybox: member("probe/busybox"), recovery: recovery, nonce: nonce)
        let checked = try result.checkedExport()
        guard result.image == image, let actual = try JSONSerialization.jsonObject(with: checked.manifest) as? NSDictionary,
              let expected = try JSONSerialization.jsonObject(with: raw) as? [String: Any], actual.isEqual(to: expected) else { throw SNESRuntimeBinding.failure() }
        try dir.check(); return result
    }
}
