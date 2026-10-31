import Foundation
import SwiftHakchiCore

/// Audited stock startup inputs only; this value cannot boot or write a console.
struct SNESStartupAdapterSource: Sendable {
    let originalInit: Data
    let originalUSB: Data
    let originalMenu: Data
    let rootChecks: Data
    static let hook = "/swifthakchi/busybox sh /swifthakchi/prepare || /bin/echo 'Swift Hakchi: using original startup without the Mac connection'\n"
    static let pins = [
        "etc/fstab":"934cd3ee10ba126d944b90849e82398b023a3176049a0883f4315e01ee04d17b",
        "etc/inittab":"f164eb562f29743c5a89eaf2abcb60b3223b0125a85f1c2b4fcf72c1808a4104",
        "etc/init.d/rcS":"dc1615df9f2012b20b81ffad8e07e16293039ba7fd897854ca3646d6cfea0c0f",
        "etc/init.d/rcK":"29f26aa195e47ceaf9b505961f47227675127ce9837ff1b0139a5b49ba43e266",
        "etc/init.d/S01prefetchui":"26decaec3c5bd7f71225202b207ebcbd733212875c8f78c00121d8cb54d5e0cb",
        "etc/init.d/S10udev":"e56b6f1b77b9de6acb430ea363bab38fd0cdac7e201fcb1c1b756394b1a6189b",
        "etc/init.d/S50softkeys":"6dea050d7744fd7f2bc45831b1013cec8e023d310576c8d43a3881b2386aa873",
        "etc/init.d/S79clvcon":"44aa9048e4131ef41d5fcd387c4a525aeb8832521c5e772763bdf71f7b20fe8b",
        "etc/init.d/S80mali":"ed3691c2394f956bae104961cc9f66746ef1a42ceab09c5b57d4a41f42dca1d7",
        "etc/init.d/S81clover-mcp":"d6dfdbf88c1c93af5d25f870f5eb7d198bef9ae17289f2b854b603fb47a35d10",
        "etc/init.d/S90usb-gadget":"cd43b2b8c4ad7ea2468d4b015da5d7e79368c4157d826a4998b1b826cb500e03",
        "etc/init.d/S99clover-production-tests":"409b7fe54f1e5eda1fb276586ea5e6b9ac973fc12910dfb7fc3f0da3faae3b35"]
    init(stock: Data, startup: SNESStartupFrame) throws {
        guard BackupManifest.digest(stock) == SNESOfflineSource.stockSHA256 else { throw SNESRuntimeBinding.failure() }
        let image = try LegacyBootImageBuilder.inspect(stock)
        guard let original = image.archive.entries.first(where: { $0.name == "sbin/init" }),
              original.fields[1] & 0xf000 == 0x8000,
              BackupManifest.digest(original.data) == "930b7de99b99e6b3d87b6677f28048c7cb3872dbdc3f939697d08a18a05a05f1",
              Set(startup.records.filter { $0.path.hasPrefix("etc/init.d/") }.map(\.path)) == Set(Self.pins.keys.filter { $0.hasPrefix("etc/init.d/") }) else {
            throw SNESRuntimeBinding.failure()
        }
        for (name,digest) in Self.pins {
            guard let record = startup.records.first(where: { $0.path == name }), record.kind == "F",
                  let bytes = record.data, bytes.count == record.count, record.digest == digest,
                  BackupManifest.digest(bytes) == digest else { throw SNESRuntimeBinding.failure() }
        }
        let busyboxSHA = "e933bac5cd6d89af48b0426c3743afb1b5d68c452a3b1d6be8a997f7fe2d31bc"
        guard let busybox = startup.records.first(where: { $0.path == "bin/busybox" }),
              busybox.kind == "B", busybox.count == 199420, busybox.digest == busyboxSHA,
              startup.records.first(where: { $0.path == "bin/sh" })?.data == Data("busybox".utf8),
              startup.records.first(where: { $0.path == "sbin/init" })?.data == Data("../bin/busybox".utf8) else { throw SNESRuntimeBinding.failure() }
        originalInit = original.data
        originalUSB = startup.records.first { $0.path == "etc/init.d/S90usb-gadget" }!.data!
        originalMenu = startup.records.first { $0.path == "etc/init.d/S81clover-mcp" }!.data!
        rootChecks = Data(Self.pins.keys.sorted().map { Self.pins[$0]! + "  /newroot/" + $0 + "\n" }.joined().utf8) + Data((busyboxSHA + "  /newroot/bin/busybox\n").utf8)
        _ = try hookedInit()
    }
    func hookedInit() throws -> Data {
        let marker = "/bin/mount --move /dev /newroot/dev\n"
        guard let text = String(data: originalInit, encoding: .ascii), text.components(separatedBy: marker).count == 2,
              !text.contains("swifthakchi") else { throw SNESRuntimeBinding.failure() }
        return Data(text.replacingOccurrences(of: marker, with: Self.hook + marker).utf8)
    }
}
