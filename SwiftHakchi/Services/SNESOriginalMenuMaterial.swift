import Foundation
import SwiftHakchiCore

/// ELF metadata only. Original code is never executed or mapped on the Mac.
struct SNESOriginalModuleMetadata: Sendable {
    let name: String, parameterPermissions: [Int]
    init(_ data: Data) throws {
        func fail() -> RecoveryProbeError { SNESRuntimeBinding.failure() }
        let b = Array(data)
        guard (52...262144).contains(b.count), b.prefix(7).elementsEqual([127,69,76,70,1,1,1]) else { throw fail() }
        func half(_ p: Int) -> Int { Int(b[p]) | Int(b[p+1]) << 8 }
        func word(_ p: Int) -> Int { (0..<4).reduce(0) { $0 | Int(b[p+$1]) << ($1*8) } }
        guard half(16) == 1, half(18) == 40, word(20) == 1, word(36) == 0x05000000,
              half(40) == 52, half(46) == 40 else { throw fail() }
        let offset = word(32), count = half(48), stringsIndex = half(50)
        guard (1...512).contains(count), stringsIndex > 0, stringsIndex < count,
              offset >= 52, offset <= b.count, count <= (b.count-offset)/40 else { throw fail() }
        func section(_ index: Int) throws -> Data {
            let p = offset+index*40, start = word(p+16), size = word(p+20)
            guard start <= b.count, size <= b.count-start else { throw fail() }
            return Data(b[start..<start+size])
        }
        let strings = try section(stringsIndex)
        var sections: [String: Data] = [:]
        for index in 0..<count {
            let at = offset+index*40, start = word(at)
            guard start < strings.count, let end = strings[start...].firstIndex(of: 0),
                  strings[start..<end].allSatisfy({ (32...126).contains($0) }) else { throw fail() }
            let name = String(decoding: strings[start..<end], as: UTF8.self)
            if [".modinfo", "__param", ".gnu.linkonce.this_module"].contains(name) {
                guard sections[name] == nil, word(at+4) == 1 else { throw fail() }
                sections[name] = try section(index)
            }
        }
        guard let metadata = sections[".modinfo"], metadata.count <= 8192,
              let module = sections[".gnu.linkonce.this_module"], module.count == 268,
              let end = module[12..<68].firstIndex(of: 0),
              let parameters = sections["__param"], parameters.count > 0, parameters.count % 16 == 0 else { throw fail() }
        let fields = metadata.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        guard fields.filter({ $0.hasPrefix("vermagic=") }) == ["vermagic=3.4.113 SMP preempt mod_unload ARMv7 "],
              fields.filter({ $0.hasPrefix("depends=") }) == ["depends="] else { throw fail() }
        let name = String(decoding: module[12..<end], as: UTF8.self)
        let permissions = stride(from: 0, to: parameters.count, by: 16).map { Int(parameters[$0+8]) | Int(parameters[$0+9]) << 8 }
        let expected = ["clvcon": [0], "mali": [292,292,292,292,292,292,436,436], "sunxi_keyboard": [420], "sunxi_knob": [436]]
        guard expected[name] == permissions else { throw fail() }
        self.name = name; parameterPermissions = permissions
    }
}

/// An audited original-component input set, separate from the old custom-kernel recipe.
struct SNESOriginalMenuMaterial: Sendable {
    let components: SNESOriginalComponentMaterial, runtime: SNESRuntimeMaterial
    let kernel: Data, drivers: [String: Data]
    private let runtimeDirectory: URL, runtimeFiles: [String: Data]
    var binding: SNESRuntimeBinding { components.source.material.setup.runtimeBinding }
    var support: SNESMenuSupportMaterial { components.source.material }
    init(components: SNESOriginalComponentMaterial, runtime: SNESRuntimeMaterial) throws {
        try components.revalidate(); try runtime.revalidate(source: components.source.material.setup)
        try components.source.material.requireRecipeInputs()
        guard runtime.binding == components.source.material.setup.runtimeBinding, let runtimeDirectory = runtime.directoryURL else { throw SNESRuntimeBinding.failure() }
        let pins = [
            ("clvcon.ko", "clvcon", "0c41deaa23584a86822f6083f024c4a61686f2380470eca2c057a433e6727f12"),
            ("mali.ko", "mali", "60137b270bbcecff871323858009104130c8df174f6b3cd74ccbfb11dbd2227a"),
            ("sunxi-keyboard.ko", "sunxi_keyboard", "1ed3d81adb3e964df9904df0ef9a3e331c885e41634453fd98c14c0b0f365a67"),
            ("sunxi-knob.ko", "sunxi_knob", "e50262274baf4feef644adc5f89a9ce8bea068b80351c02e798a89b1ca5e0f43")]
        var drivers: [String: Data] = [:]
        for (record,pin) in zip(components.frame.records.dropLast(),pins) {
            guard record.path.split(separator: "/").last.map(String.init) == pin.0, record.digest == pin.2,
                  try SNESOriginalModuleMetadata(record.data).name == pin.1 else { throw SNESRuntimeBinding.failure() }
            drivers[pin.0] = record.data
        }
        guard drivers.count == 4, let mcp = components.frame.records.last,
              mcp.path == "usr/bin/clover-mcp", mcp.digest == "dff55752d9c101ff175a9d6b9c31022e1dd6304392a190cdd6e3be36f013946c" else { throw SNESRuntimeBinding.failure() }
        let elf = try ARMRuntimeELF(data: mcp.data)
        guard elf.type == 2, elf.interpreter == "/lib/ld-linux-armhf.so.3",
              Set(elf.dependencies) == Set(["libSDL2.so", "libpthread.so.0", "libdl.so.2", "libEGL.so", "libGLESv2.so", "libMali.so", "libGLESv1_CM.so", "librt.so.1", "libstdc++.so.6", "libm.so.6", "libgcc_s.so.1", "libc.so.6"]) else { throw SNESRuntimeBinding.failure() }
        let kernel = try LegacyBootImageBuilder.inspect(components.source.material.setup.stock).kernel
        guard kernel.count == 1_899_024, BackupManifest.digest(kernel) == "512d0d6d4610721589acf7b0fed1668de3e141a0a2cb759e8885662e1652b7da" else { throw SNESRuntimeBinding.failure() }
        let dir = try RestoreDirectory(runtimeDirectory)
        let runtimeFiles = ["manifest.json": try dir.read("manifest.json", maximum: 65536),
            "runtime.frame": runtime.frame.encoded, "loader.bin": runtime.frame.loader, "libc.bin": runtime.frame.libc]
        self.components = components; self.runtime = runtime; self.kernel = kernel; self.drivers = drivers
        self.runtimeDirectory = runtimeDirectory; self.runtimeFiles = runtimeFiles
        try revalidate()
        try runtime.revalidate(source: components.source.material.setup)
    }
    func revalidate() throws {
        try Task.checkCancellation(); try components.revalidate()
        let dir = try RestoreDirectory(runtimeDirectory)
        for (name,bytes) in runtimeFiles { guard try dir.read(name, maximum: max(bytes.count,1)) == bytes else { throw SNESRuntimeBinding.failure() } }
        try dir.check()
    }
}
