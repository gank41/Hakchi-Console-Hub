import Foundation
import Testing
import SWCompression
import USBBridge
@testable import SwiftHakchi
@testable import SwiftHakchiCore

struct PinnedFELInputs: Sendable {
    let fes1: Data
    let uboot: Data
    let bootImage: Data
    private static let stored: Result<PinnedFELInputs, any Error> = Result {
        let resources = RecoveryPreflightTests.resources
        let entries = try TarContainer.open(container: GzipArchive.unarchive(archive: Data(contentsOf: resources.appendingPathComponent("hakchi.hmod"))))
        return try PinnedFELInputs(fes1: Data(contentsOf: resources.appendingPathComponent("fes1.bin")),
                                  uboot: RecoveryPayloadValidator.member("boot/uboot.bin", entries: entries),
                                  bootImage: RecoveryPayloadValidator.member("boot/boot.img", entries: entries))
    }
    static func load() throws -> Self { try stored.get() }
}

private func imageWithCommandLine(_ text: String) -> Data {
    var bytes = Data(repeating: 0, count: 6144)
    bytes.replaceSubrange(0..<8, with: Data("ANDROID!".utf8))
    for (offset, word): (Int, UInt32) in [(8,100), (16,200), (36,2048)] {
        for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: word >> (i * 8)) }
    }
    let text = Data(text.utf8)
    bytes.replaceSubrange(64..<(64 + text.count), with: text)
    return bytes
}
private func commandLineText(_ data: Data) -> String {
    String(decoding: data[64..<576].prefix(while: { $0 != 0 }), as: UTF8.self)
}

struct PreparedRecoveryBootTests {
    @Test func embeddedHakchiFlagsAreRefusedBecauseRecoveryMatchesSubstrings() {
        for argument in ["key=hakchi-install", "prefix-hakchi-usb-host", "mode=hakchi-clovershell"] {
            #expect(throws: (any Error).self) { try RecoveryBootPatcher.commandLine(in: imageWithCommandLine("ro " + argument)) }
        }
    }

    @Test func realPinnedInputsProduceOnlyBoundedPreparedCopies() throws {
        let raw = try PinnedFELInputs.load()
        let originalBootSHA = BackupManifest.digest(raw.bootImage), originalUbootSHA = BackupManifest.digest(raw.uboot)
        let prepared = try PreparedRecoveryBoot(fes1: raw.fes1, uboot: raw.uboot, bootImage: raw.bootImage)
        #expect(prepared.fes1 == raw.fes1)
        #expect(prepared.bootImage.count == raw.bootImage.count && prepared.uboot.count == raw.uboot.count)
        #expect(commandLineText(prepared.bootImage).hasSuffix("hakchi-shell hakchi-memboot"))
        let slot = try RecoveryPayloadValidator.bootCommandRange(in: raw.uboot)
        let expected = "boota " + String(UInt32(TRANSFER_BASE_M), radix: 16)
        #expect(String(decoding: prepared.uboot[slot], as: UTF8.self).trimmingCharacters(in: .whitespaces) == expected)
        #expect(prepared.uboot[slot.upperBound] == 0)
        #expect(prepared.uboot[..<slot.lowerBound] == raw.uboot[..<slot.lowerBound])
        #expect(prepared.uboot[slot.upperBound...] == raw.uboot[slot.upperBound...])
        #expect(BackupManifest.digest(raw.bootImage) == originalBootSHA && BackupManifest.digest(raw.uboot) == originalUbootSHA)
    }
    @Test func alteredOrTruncatedExactArgumentsAreRefused() throws {
        let raw = try PinnedFELInputs.load()
        var wrong = raw.bootImage; wrong[1000] ^= 1
        #expect(throws: (any Error).self) { try PreparedRecoveryBoot(fes1: raw.fes1, uboot: raw.uboot, bootImage: wrong) }
        #expect(throws: (any Error).self) { try PreparedRecoveryBoot(fes1: Data(raw.fes1.dropLast()), uboot: raw.uboot, bootImage: raw.bootImage) }
        var wrongUboot = raw.uboot; wrongUboot[0] ^= 1
        #expect(throws: (any Error).self) { try PreparedRecoveryBoot(fes1: raw.fes1, uboot: wrongUboot, bootImage: raw.bootImage) }
    }
    @Test func cmdlineRemovesCompleteHakchiTokensWithoutChangingOtherBytes() throws {
        let raw = imageWithCommandLine("root=/dev/nandb ro key=unchanged hakchi-install hakchi-usb-host hakchi-shell hakchi-memboot boot=ok")
        let patched = try RecoveryBootPatcher.commandLine(in: raw)
        #expect(commandLineText(patched) == "root=/dev/nandb ro key=unchanged boot=ok hakchi-shell hakchi-memboot")
        #expect(patched[..<64] == raw[..<64] && patched[576...] == raw[576...])
        #expect(patched.count == raw.count)
    }
    @Test func cmdlineRequiresCompleteAsciiAndRejectsOverflowInsteadOfTruncating() throws {
        var unterminated = imageWithCommandLine(""); unterminated.replaceSubrange(64..<576, with: Data(repeating: 65, count: 512))
        var nonAscii = imageWithCommandLine("a"); nonAscii[64] = 0xFF
        var control = imageWithCommandLine("a"); control[64] = 10
        for bytes in [unterminated, nonAscii, control, imageWithCommandLine(String(repeating: "a", count: 500)), Data([1,2,3])] {
            #expect(throws: (any Error).self) { try RecoveryBootPatcher.commandLine(in: bytes) }
        }
        let flags = " hakchi-shell hakchi-memboot"
        let raw = imageWithCommandLine(String(repeating: "a", count: 511 - flags.utf8.count))
        let patched = try RecoveryBootPatcher.commandLine(in: raw)
        #expect(commandLineText(patched).utf8.count == 511 && patched[575] == 0)
    }
    @Test func bootcmdPreservesSlotAndAdjacentEnvironmentTerminators() throws {
        let original = Data("prefix\0bootcmd=old-command-long-enough\0bootdelay=0\0baudrate=115200\0\0suffix".utf8)
        let patched = try RecoveryBootPatcher.bootCommand(in: original, transferAddress: 0x47400000)
        let range = try RecoveryPayloadValidator.bootCommandRange(in: original)
        #expect(patched.count == original.count)
        #expect(patched[range].starts(with: Data("boota 47400000".utf8)))
        #expect(patched[range].dropFirst("boota 47400000".utf8.count).allSatisfy { $0 == 32 })
        #expect(patched[range.upperBound...] == original[range.upperBound...])
        for invalid in [Data("bootcmd=short\0".utf8), Data("bootcmd=long-but-not-terminated".utf8), original + Data("bootcmd=second-command\0".utf8)] {
            #expect(throws: (any Error).self) { try RecoveryBootPatcher.bootCommand(in: invalid, transferAddress: 0x47400000) }
        }
    }
}
