import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@Suite(.serialized)
struct SNESStartupAdapterSourceTests {
    @Test func checkedHookPreservesOriginalStartupAndRejectsChangedSources() throws {
        guard let material = try privateOriginalMenuMaterial() else { return }
        let stock = material.support.setup.stock, startup = material.support.source.preparation.startup
        let checked = try SNESStartupAdapterSource(stock: stock, startup: startup)
        let original = try LegacyBootImageBuilder.inspect(stock)
        let initData = try #require(original.archive.entries.first { $0.name == "sbin/init" }?.data)
        let hook = Data("/swifthakchi/busybox sh /swifthakchi/prepare || /bin/echo 'Swift Hakchi: using original startup without the Mac connection'\n".utf8)
        let hooked = try checked.hookedInit()
        let insertion = try #require(hooked.range(of: hook))
        var restored = hooked; restored.removeSubrange(insertion)
        #expect(restored == initData && checked.originalInit == initData)
        #expect(hooked[insertion.upperBound...].starts(with: Data("/bin/mount --move /dev /newroot/dev\n".utf8)))
        #expect(checked.originalUSB.count == 2002)
        let checks = String(decoding: checked.rootChecks, as: UTF8.self).split(separator: "\n")
        #expect(checks.count == 13)
        for line in checks {
            let pair = line.components(separatedBy: "  ")
            #expect(pair.count == 2 && pair[0].count == 64 && pair[1].hasPrefix("/newroot/"))
        }
        // A reviewed startup script changing must refuse before a candidate is built.
        for name in ["etc/inittab", "etc/init.d/rcS", "etc/init.d/rcK", "etc/init.d/S90usb-gadget", "etc/init.d/S79clvcon"] {
            let record = try #require(startup.records.first { $0.path == name })
            let payload = try #require(record.data), corrupted = payload + Data("# changed\n".utf8)
            var frame = startup.raw
            let block = Data("F \(name) \(payload.count) \(record.digest)\n".utf8) + payload + Data([10])
            let replacement = Data("F \(name) \(corrupted.count) \(BackupManifest.digest(corrupted))\n".utf8) + corrupted + Data([10])
            frame.replaceSubrange(try #require(frame.range(of: block)), with: replacement)
            let altered = try SNESStartupFrame(frame)
            #expect(throws: (any Error).self) { try SNESStartupAdapterSource(stock: stock, startup: altered) }
        }
        let busybox = try #require(startup.records.first { $0.path == "bin/busybox" })
        let changedRecord = "B bin/busybox \(busybox.count) \(String(repeating: "1", count: 64))"
        let recordText = "B bin/busybox \(busybox.count) \(busybox.digest)"
        let binaryChanged = try SNESStartupFrame(Data(String(decoding: startup.raw, as: UTF8.self).replacingOccurrences(of: recordText, with: changedRecord).utf8))
        #expect(throws: (any Error).self) { try SNESStartupAdapterSource(stock: stock, startup: binaryChanged) }
        var damaged = stock; damaged[2048] ^= 1
        #expect(throws: (any Error).self) { try SNESStartupAdapterSource(stock: damaged, startup: startup) }
    }
}
