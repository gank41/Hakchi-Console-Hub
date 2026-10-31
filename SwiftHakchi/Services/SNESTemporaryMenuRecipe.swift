import Foundation
import SwiftHakchiCore

/// This sealed value permits one temporary RAM boot only; no firmware writer consumes it.
struct PreparedSNESTemporaryMenu: Sendable {
    let image: Data, base: PreparedSNESRAMProbe, support: SNESMenuSupportMaterial
    let drivers: SNESMenuDrivers
    let filesSHA256: String, sourceFilesSHA256: String
    fileprivate let imageSHA256: String
    var nonce: String { base.nonce }
    var binding: SNESRuntimeBinding { base.binding }
    var fes1: Data { base.fes1 }
    var uboot: Data { base.uboot }
    fileprivate init(image: Data, base: PreparedSNESRAMProbe, support: SNESMenuSupportMaterial,
                     drivers: SNESMenuDrivers, files: Data, sourceFiles: Data) {
        self.image = image; self.base = base; self.support = support; self.drivers = drivers
        imageSHA256 = BackupManifest.digest(image); filesSHA256 = BackupManifest.digest(files)
        sourceFilesSHA256 = BackupManifest.digest(sourceFiles)
    }
    func validateCurrent() throws {
        try Task.checkCancellation(); try base.validateCurrent(); try support.revalidate(); try support.requireRecipeInputs()
        guard binding == support.setup.runtimeBinding, imageSHA256 == BackupManifest.digest(image),
              drivers.archive.count == 99217, BackupManifest.digest(drivers.archive) == SNESMenuDrivers.archiveSHA256 else { throw SNESRuntimeBinding.failure() }
        _ = try LegacyBootImageBuilder.inspect(image)
    }
    fileprivate struct Manifest: Codable {
        let schemaVersion: Int, complete: Bool, firmwareWritten: Bool, firmwareRestoreEligible: Bool
        let scope: String, setupPath: String, preparationPath: String, supportPath: String, runtimePath: String
        let setupSHA256: String, supportSHA256: String, nonce: String, imageSHA256: String, baseImageSHA256: String
    }
    func checkedExport() throws -> (files: [String: Data], manifest: Data) {
        try validateCurrent()
        guard let runtime = base.runtime.directoryURL else { throw SNESRuntimeBinding.failure() }
        let m = Manifest(schemaVersion: 1, complete: true, firmwareWritten: false, firmwareRestoreEligible: false,
            scope: "snes-temporary-menu-image", setupPath: support.setup.directoryURL.path,
            preparationPath: support.source.directoryURL.path, supportPath: support.directoryURL.path,
            runtimePath: runtime.path, setupSHA256: support.setup.manifestSHA256, supportSHA256: support.manifestSHA256,
            nonce: nonce, imageSHA256: imageSHA256, baseImageSHA256: BackupManifest.digest(base.image))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (["menu.img": image, "base.img": base.image, "drivers.hmod": drivers.archive], try encoder.encode(m))
    }
}
enum SNESTemporaryMenuRecipe {
    static func prepare(base originalBase: PreparedSNESRAMProbe, support: SNESMenuSupportMaterial,
                        drivers: SNESMenuDrivers, nonce: UUID = UUID()) throws -> PreparedSNESTemporaryMenu {
        let base = try SNESRAMProbeRecipe.withNonce(originalBase, nonce: nonce)
        try base.validateCurrent(); try support.revalidate(); try support.requireRecipeInputs()
        guard base.binding == support.setup.runtimeBinding else { throw SNESRuntimeBinding.failure() }
        let contents = try LegacyBootImageBuilder.inspect(base.image)
        func member(_ name: String) throws -> Data {
            guard let e = contents.archive.entries.first(where: { $0.name == name }), e.fields[1] & 0xf000 == 0x8000 else { throw SNESRuntimeBinding.failure() }
            return e.data
        }
        let scripts = try SNESRAMProbeScripts(binding: base.binding, nonce: base.nonce,
            loaderSHA256: BackupManifest.digest(member("probe/ld-linux-armhf.so.3")),
            libcSHA256: BackupManifest.digest(member("probe/libc.so.6")), daemonSHA256: SNESRAMProbeRecipe.daemonSHA256)
        var payload = try SNESTemporaryMenuScripts.assets(base: scripts, sourceFiles: support.sourceFiles)
        for (name, data) in drivers.files { payload["probe/" + name] = data }
        var all = Dictionary(uniqueKeysWithValues: contents.archive.entries.filter { $0.fields[1] & 0xf000 == 0x8000 && $0.name != "probe/files.sha256" }.map { ($0.name, $0.data) })
        all.merge(payload) { _, new in new }
        let checks = Data(all.keys.sorted().map { BackupManifest.digest(all[$0]!) + "  /" + $0 + "\n" }.joined().utf8)
        payload["probe/files.sha256"] = checks
        let existing = Set(contents.archive.entries.map(\.name))
        var additions: [NewcEntry] = []
        func entry(_ name: String, mode: UInt32, data: Data) -> NewcEntry {
            let inode = UInt32(20000 + additions.count)
            return .init(name: name, fields: [inode, mode, 0, 0, mode & 0xf000 == 0x4000 ? 2 : 1, 0, UInt32(data.count), 0, 0, 0, 0, UInt32(name.utf8.count + 1), 0], data: data)
        }
        for dir in ["probe/rules", "probe/empty-rules"] { additions.append(entry(dir, mode: 0o40700, data: Data())) }
        for path in payload.keys.sorted() where !existing.contains(path) {
            let executable = ["probe/run", "probe/shutdown"].contains(path)
            additions.append(entry(path, mode: executable ? 0o100700 : 0o100600, data: payload[path]!))
        }
        let archive = try contents.archive.updating(replacements: payload.filter { existing.contains($0.key) }, additions: additions)
        var image = try LegacyBootImageBuilder.build(source: base.image, kernel: contents.kernel, archive: archive)
        image.replaceSubrange(64..<576, with: contents.header[64..<576])
        let checked = try LegacyBootImageBuilder.inspect(image)
        guard checked.archive == archive, checked.kernel == contents.kernel else { throw SNESRuntimeBinding.failure() }
        let original = try LegacyBootImageBuilder.inspect(support.setup.stock)
        for e in original.archive.entries where e.name != "init" {
            var expected = e
            if e.name == "." { expected.fields[4] += 1 } // One new top-level test directory.
            guard checked.archive.entries.first(where: { $0.name == e.name }) == expected else { throw SNESRuntimeBinding.failure() }
        }
        try base.validateCurrent(); try support.revalidate()
        return .init(image: image, base: base, support: support, drivers: drivers,
            files: checks, sourceFiles: Data(support.sourceFiles.utf8))
    }
    static func load(directory url: URL, recovery: RecoveryBootInputs) throws -> PreparedSNESTemporaryMenu {
        let dir = try RestoreDirectory(url)
        let prefix = "SNES-Temporary-Menu-"
        guard dir.url.lastPathComponent.hasPrefix(prefix), UUID(uuidString: String(dir.url.lastPathComponent.dropFirst(prefix.count))) != nil else { throw SNESRuntimeBinding.failure() }
        let m = try JSONDecoder().decode(PreparedSNESTemporaryMenu.Manifest.self, from: dir.read("manifest.json", maximum: 65536))
        guard m.schemaVersion == 1, m.complete, !m.firmwareWritten, !m.firmwareRestoreEligible, m.scope == "snes-temporary-menu-image",
              [m.setupPath, m.preparationPath, m.supportPath, m.runtimePath].allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4096 }) else { throw SNESRuntimeBinding.failure() }
        let source = try SNESOfflineSource.load(snapshot: URL(fileURLWithPath: m.setupPath))
        let supportSource = try SNESMenuSupportSource.load(setup: source, preparation: URL(fileURLWithPath: m.preparationPath))
        let support = try SNESMenuSupportMaterial.load(source: supportSource, directory: URL(fileURLWithPath: m.supportPath))
        let runtime = try SNESRuntimeMaterial.load(directory: URL(fileURLWithPath: m.runtimePath), source: source)
        let image = try dir.read("menu.img"), baseBytes = try dir.read("base.img")
        guard m.setupSHA256 == source.manifestSHA256, m.supportSHA256 == support.manifestSHA256,
              m.imageSHA256 == BackupManifest.digest(image), m.baseImageSHA256 == BackupManifest.digest(baseBytes) else { throw SNESRuntimeBinding.failure() }
        let base = try SNESRAMProbeRecipe.reconstruct(image: baseBytes, source: source, runtime: runtime, recovery: recovery, nonce: m.nonce)
        guard let nonce = UUID(uuidString: m.nonce) else { throw SNESRuntimeBinding.failure() }
        let result = try prepare(base: base, support: support, drivers: SNESMenuDrivers(dir.read("drivers.hmod", maximum: 100000)), nonce: nonce)
        guard result.image == image else { throw SNESRuntimeBinding.failure() }
        try dir.check(); return result
    }
}
