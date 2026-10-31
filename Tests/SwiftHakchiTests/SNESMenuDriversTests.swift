import Foundation
import Testing
import SWCompression
@testable import SwiftHakchi

struct SNESMenuDriversTests {
    @Test func pinnedArchiveSelectsOnlyTheFourCompatibleDrivers() throws {
        guard let path = ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_DRIVERS"] else { return }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let drivers = try SNESMenuDrivers(bytes)
        #expect(Set(drivers.files.keys) == ["clovercon.ko", "mali.ko", "sunxi-keyboard.ko", "sunxi-knob.ko"])
        #expect(drivers.files["mali.ko"]?.count == 165736)
        #expect(drivers.files["clovercon.ko"]?.count == 16280)
        var bad = bytes; bad[100] ^= 1
        #expect(throws: (any Error).self) { _ = try SNESMenuDrivers(bad) }
        #expect(throws: (any Error).self) { _ = try SNESMenuDrivers(Data(count: 99218)) }
    }
    @Test(arguments: ["machine", "type", "endian", "version", "truncated"])
    func moduleFormatAndReleaseMustMatch(fault: String) throws {
        guard let path = ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_DRIVERS"] else { return }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let entries = try TarContainer.open(container: GzipArchive.unarchive(archive: bytes))
        var module = try RecoveryPayloadValidator.member("lib/modules/3.4.112.madmonkey/extra/clovercon.ko", entries: entries)
        switch fault {
        case "machine": module[18] = 62
        case "type": module[16] = 3
        case "endian": module[5] = 2
        case "version":
            let marker = Data("vermagic=3.4.112.madmonkey".utf8)
            let offset = try #require(module.range(of: marker)).lowerBound + 9
            module[offset] = 52
        default: module = Data(module.prefix(51))
        }
        #expect(throws: (any Error).self) { try SNESMenuDrivers.validateModule(module) }
    }
}
