import Foundation
import SwiftHakchiCore

/// Immutable, inspected core data. This partial package has no frontend, console
/// dependency proof or tested save bridge, and grants no installation/launch authority.
struct SNESCompatibilityCorePackage: Sendable {
    static let engineID="snes9x2010-fe690dd3-armhf-glibc223"
    let core:Data
    let notice:Data
    let manifest:Data
    let inspection:SNESCompatibilityELF

    private struct Artifact:Encodable {
        let byteCount:Int
        let sha256:String
    }
    private struct Source:Encodable {
        let repository:String
        let commit:String
        let archiveByteCount:Int
        let archiveSHA256:String
    }
    private struct Manifest:Encodable {
        let version:Int
        let scope:String
        let engineID:String
        let libretroABI:Int
        let target:String
        let core:Artifact
        let source:Source
        let notice:Artifact
        let dependencies:[String]
        let requiredGLIBCVersions:[String]
    }

    /// Load bundled, reviewed data for Mac-side preparation only.
    /// This does not authorize installing or launching the core.
    static func loadBundled() throws -> Self {
        guard let root = Bundle.appBundle.url(forResource: "SNESCompatibilityCore", withExtension: nil) else {
            throw RecoveryProbeError.refused("The optional emulator core resources are missing. Nothing was installed.")
        }
        return try Self(core: Data(contentsOf: root.appendingPathComponent("core.so")),
                        sourceArchive: Data(contentsOf: root.appendingPathComponent("source.tar.gz")),
                        notice: Data(contentsOf: root.appendingPathComponent("LICENSE.txt")))
    }

    init(core:Data,sourceArchive:Data,notice:Data) throws {
        // Pins come from the separately recorded unchanged-source and byte-identical
        // rebuild audit. A caller-supplied manifest cannot authorize a different build.
        let corePin=Artifact(byteCount:3_385_720,sha256:"ea4fab232ce2479c61099240d20196172051027fb7f55a9eabf2c5d9c4342286")
        let archivePin=Artifact(byteCount:1_219_151,sha256:"7d2d2a21c2c00e6c5a83c8b51c18fccb6a9b3764584aa5ceb4b231e3a7c0ab6c")
        let noticePin=Artifact(byteCount:6_100,sha256:"2d5875c99c5895e9e8d104dd777dc7fdeee0fd96bed0bca38e83b90b480d2523")
        func matches(_ bytes:Data,_ pin:Artifact)->Bool {
            bytes.count==pin.byteCount && BackupManifest.digest(bytes)==pin.sha256
        }
        guard matches(core,corePin), matches(sourceArchive,archivePin), matches(notice,noticePin) else {
            throw RecoveryProbeError.refused("The optional emulator core, original source or license file does not match its reviewed build. Nothing was installed.")
        }
        let inspection=try SNESCompatibilityELF(data:core)
        let record=Manifest(version:1,scope:"validated-snes-core-only",engineID:Self.engineID,
            libretroABI:1,target:"arm-linux-gnueabihf.2.23/cortex_a7",core:corePin,
            source:.init(repository:"https://github.com/libretro/snes9x2010",commit:"fe690dd321fa5a46b5234a2bde089d2518c62b0e",
                archiveByteCount:archivePin.byteCount,archiveSHA256:archivePin.sha256),notice:noticePin,
            dependencies:inspection.dependencies,requiredGLIBCVersions:inspection.requiredVersions.sorted())
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        self.manifest=try encoder.encode(record)
        self.core=core;self.notice=notice;self.inspection=inspection
    }
}
