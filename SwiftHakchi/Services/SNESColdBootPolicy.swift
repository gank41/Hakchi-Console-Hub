import Foundation
import SwiftHakchiCore

/// The audited stock bootloader reads 32 physical 128 KiB units before boota.
enum SNESColdBootPolicy {
    static func require(boot1:Data,image:Data) throws {
        try require(boot1:boot1,imageByteCount:image.count)
        try requireSupportedImage(image)
    }
    /// The exact audited original 3.4.113 kernel has only the LZO initramfs decoder.
    /// Keep historical XZ artifacts readable, but never execute them with this kernel.
    static func requireSupportedImage(_ image:Data) throws {
        let layout=try LegacyAndroidBootImage(data:image)
        guard image.subdata(in:layout.ramdiskRange).starts(with:[0x89,0x4c,0x5a,0x4f,0,13,10,26,10]) else {
            throw RecoveryProbeError.refused("These startup files use an unsupported format. Create updated startup files; nothing was sent to the console.")
        }
        let checked=try LegacyBootImageBuilder.inspect(image)
        guard checked.kernel.count==1899024,BackupManifest.digest(checked.kernel)=="512d0d6d4610721589acf7b0fed1668de3e141a0a2cb759e8885662e1652b7da" else {
            throw RecoveryProbeError.refused("This console's original startup version has not been checked yet. Nothing was sent to the console.")
        }
    }
    static func require(boot1:Data,imageByteCount:Int) throws {
        // Model/version evidence, never a unique console or owner identity.
        guard boot1.count==573440,BackupManifest.digest(boot1)=="ac7ff6437420c589717c0f1108b43ecc87aa441ee232af9016620226a5cbd1e0" else {
            throw RecoveryProbeError.refused("This console's startup version has not been checked yet. No firmware was sent.")
        }
        guard imageByteCount>0,imageByteCount<=4*1024*1024 else {
            throw RecoveryProbeError.refused("These startup files are too large for normal startup. Create updated startup files before installing; no firmware was sent.")
        }
    }
}
