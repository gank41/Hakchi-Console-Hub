import Foundation
import SwiftHakchiCore

/// The fixed-purpose ARM launcher is data on the Mac; only the checked RAM recipe may execute it.
enum SNESMenuLaunchHelper {
    static let byteCount=1680
    static let sha256="ffab13eb1a1132062872764f62e5fde0125fc00df06b0ed9eb1ecd116a8ccbcd"
    static func load() throws -> Data {
        guard let url=Bundle.module.url(forResource:"snes-menu-launch",withExtension:nil) else {throw SNESRuntimeBinding.failure()}
        let bytes=try Data(contentsOf:url,options:.mappedIfSafe)
        try validate(bytes);return bytes
    }
    static func validate(_ bytes:Data) throws {
        guard bytes.count==byteCount,BackupManifest.digest(bytes)==sha256 else {throw SNESRuntimeBinding.failure()}
        let elf=try ARMRuntimeELF(data:bytes)
        guard elf.type==2,elf.interpreter==nil,elf.dependencies.isEmpty else {throw SNESRuntimeBinding.failure()}
    }
}
