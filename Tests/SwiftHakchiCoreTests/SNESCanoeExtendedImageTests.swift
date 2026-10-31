import Foundation
import Testing
@testable import SwiftHakchiCore

struct SNESCanoeExtendedImageTests {
    // The weights below are hand-derived cartridge address mirrors, independent
    // of the production checksum routine. Header checksum bytes live in block 0.
    private func rom(length: Int, blocks: [(Int, Int)], hi: Bool = false,
                     country: UInt8 = 1, title: [UInt8] = Array("ORDINARY EXTENDED".utf8)) -> Data {
        var b = Data(repeating: 0, count: length)
        let h = hi ? 0xffc0 : 0x7fc0
        b[3] = 0x11; b[length - 13] = 0x37
        b.replaceSubrange(h..<h+21, with: title + Array(repeating: 32, count: 21-title.count))
        b[h+0x15] = hi ? 0x31 : 0x30
        b[h+0x16] = 2; b[h+0x18] = 5; b[h+0x19] = country
        var exponent = 5
        while (1 << (exponent+10)) < length { exponent += 1 }
        b[h+0x17] = UInt8(exponent); b[h+0x3d] = 0x80
        b[h+0x1c] = 255; b[h+0x1d] = 255
        var start = 0, checksum = 0
        for (count, weight) in blocks {
            checksum += b[start..<start+count].reduce(0) { $0 + Int($1) } * weight
            start += count
        }
        precondition(start == length)
        checksum &= 0xffff
        b[h+0x1c] = UInt8((checksum ^ 0xffff) & 255); b[h+0x1d] = UInt8((checksum ^ 0xffff) >> 8)
        b[h+0x1e] = UInt8(checksum & 255); b[h+0x1f] = UInt8(checksum >> 8)
        return b
    }

    private func word32(_ data: Data, _ offset: Int) -> Int {
        (0..<4).reduce(0) { $0 | Int(data[offset+$1]) << ($1*8) }
    }

    @Test(arguments: [false, true])
    func threeMiBCartridgeUsesMirroredChecksumAndKeepsItsActualPayload(hi: Bool) throws {
        let source = rom(length: 3*1024*1024, blocks: [(2*1024*1024, 1), (1024*1024, 2)], hi: hi)
        let prepared = try SNESCanoeImage.prepare(rom: source), footer = 48 + source.count
        #expect(prepared.data.count == 3*1024*1024+96)
        #expect(prepared.data[48..<footer] == source)
        #expect(word32(prepared.data, footer+1) == 3*1024*1024)
        #expect(word32(prepared.data, 4) == 3*1024*1024+96)
        #expect(prepared.isHiROM == hi && prepared.sramBytes == 32768 && prepared.saveCount == 3)
    }

    @Test(arguments: [1280, 1536, 2560])
    func otherValidIrregularSizesKeepThePayloadWithoutPadding(kib: Int) throws {
        let large = kib == 2560 ? 2048 : 1024, tail = kib-large
        let source = rom(length: kib*1024, blocks: [(large*1024, 1), (tail*1024, large/tail)])
        let prepared = try SNESCanoeImage.prepare(rom: source)
        #expect(prepared.data.count == source.count+96)
        #expect(prepared.data[48..<48+source.count] == source)
        #expect(prepared.sourcePayloadSHA256 == BackupManifest.digest(source))
    }

    @Test func nestedMirroringAndCopierPrefixHaveTheSameNormalizedIdentity() throws {
        let source = rom(length: 1792*1024, blocks: [(1024*1024, 1), (512*1024, 1), (256*1024, 2)])
        let prepared = try SNESCanoeImage.prepare(rom: source)
        let prefixed = try SNESCanoeImage.prepare(rom: Data(repeating: 0x93, count: 512) + source)
        #expect(prepared.data == prefixed.data && prefixed.sourcePrefixBytes == 512)
        #expect(prepared.data[48..<48+source.count] == source)
    }

    @Test func validJapaneseInternalTitleAndNTSCRegionDoNotRewriteTheCartridge() throws {
        let title: [UInt8] = [0xcd,0xde,0xbd,0xc4,0x20,0xbc,0xae,0xaf,0xc4,0x20,0xcc,0xdf,0xdb,0xba,0xde,0xd9,0xcc]
        let source = rom(length: 65536, blocks: [(65536, 1)], hi: true, country: 0, title: title)
        let prepared = try SNESCanoeImage.prepare(rom: source)
        #expect(prepared.internalTitle == "ﾍﾞｽﾄ ｼｮｯﾄ ﾌﾟﾛｺﾞﾙﾌ")
        #expect(prepared.data[48..<48+source.count] == source)
        #expect(prepared.isHiROM && prepared.presetID == 0)
    }

    @Test(arguments: ["checksum", "truncated-bank", "appended-bank", "declared-span", "PAL", "chip"])
    func broaderSizeSupportStillRejectsUnverifiedCartridgeChanges(fault: String) {
        var source = rom(length: 1536*1024, blocks: [(1024*1024, 1), (512*1024, 2)])
        switch fault {
        case "checksum": source[3] ^= 1
        case "truncated-bank": source.removeLast()
        case "appended-bank": source.append(Data(repeating: 0, count: 32768))
        case "declared-span": source[0x7fd7] = 12
        case "PAL": source[0x7fd9] = 2
        default: source[0x7fd6] = 0xf3
        }
        #expect(throws: SNESCanoeImage.PreparationError.self) { try SNESCanoeImage.prepare(rom: source) }
    }
}
