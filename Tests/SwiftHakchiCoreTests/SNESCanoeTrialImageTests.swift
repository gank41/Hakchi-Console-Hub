import Foundation
import Testing
@testable import SwiftHakchiCore

struct SNESCanoeTrialImageTests {
    private func rom(hi: Bool = false) -> Data {
        var b = [UInt8](repeating: 0, count: 65536)
        let h = hi ? 0xffc0 : 0x7fc0
        b.replaceSubrange(h..<h+21, with: Array("SYNTHETIC TEST GAME  ".utf8))
        b[h+0x15] = hi ? 0x21 : 0x20
        b[h+0x17] = 6; b[h+0x19] = 1
        b[h+0x3d] = 0x80
        b[h+0x1c] = 0xff; b[h+0x1d] = 0xff
        let checksum = b.reduce(0) { $0 + Int($1) } & 0xffff
        b[h+0x1c] = UInt8((checksum ^ 0xffff) & 255)
        b[h+0x1d] = UInt8((checksum ^ 0xffff) >> 8)
        b[h+0x1e] = UInt8(checksum & 255); b[h+0x1f] = UInt8(checksum >> 8)
        return Data(b)
    }
    private func le32(_ b: Data, _ i: Int) -> Int {
        (0..<4).reduce(0) { $0 | Int(b[i+$1]) << (8*$1) }
    }
    @Test(arguments: [false, true]) func serializesOrdinaryROMWithoutChangingPayload(hi: Bool) throws {
        let source = rom(hi: hi), prepared = try SNESCanoeTrialImage(rom: source)
        let b = prepared.data, footer = 48 + source.count
        #expect(b.count == source.count + 96)
        #expect(b[48..<footer] == source)
        #expect(le32(b, 0) == 0x100)
        #expect(le32(b, 4) == b.count)
        #expect(le32(b, 8) == 48)
        #expect(le32(b, 12) == footer)
        #expect(le32(b, 16) == b.count)
        #expect(le32(b, 20) == footer)
        #expect(le32(b, 24) == b.count)
        #expect(le32(b, 28) == 0)
        #expect(le32(b, 32) == footer + 27)
        #expect(b[36..<44] == Data("WUP-XXXX".utf8))
        #expect(le32(b, 44) == 0)
        #expect(b[footer] == 60)
        #expect(le32(b, footer+1) == source.count)
        #expect(b[footer+5..<footer+15].allSatisfy { $0 == 0 })
        #expect(Array(b[footer+15..<footer+18]) == [2, 0x5a, hi ? 0x15 : 0x14])
        #expect(b[footer+18..<footer+27].allSatisfy { $0 == 0 })
        #expect(le32(b, footer+27) == 1)
        #expect(le32(b, footer+31) == 1)
        #expect(b[(footer+35)...].allSatisfy { $0 == 0 })
        #expect(prepared.isHiROM == hi)
        #expect(prepared.requiresHardwareTrial)
    }
    @Test func stripsOnlyTheCopierPrefix() throws {
        let source = rom(), prefixed = Data(repeating: 0x91, count: 512) + source
        let prepared = try SNESCanoeTrialImage(rom: prefixed)
        #expect(prepared.sourcePrefixBytes == 512)
        #expect(prepared.data == (try SNESCanoeTrialImage(rom: source)).data)
        #expect(prefixed.prefix(512).allSatisfy { $0 == 0x91 })
    }
    private func recalculateChecksum(_ source: inout Data, headers: [Int]) {
        for h in headers {
            source[h+0x1c] = 0xff; source[h+0x1d] = 0xff
            source[h+0x1e] = 0; source[h+0x1f] = 0
        }
        let sum = source.reduce(0) { $0 + Int($1) } & 0xffff
        for h in headers {
            source[h+0x1c] = UInt8((sum ^ 0xffff) & 255); source[h+0x1d] = UInt8((sum ^ 0xffff) >> 8)
            source[h+0x1e] = UInt8(sum & 255); source[h+0x1f] = UInt8(sum >> 8)
        }
    }
    @Test(arguments: [0x15, 0x16, 0x17, 0x18, 0x19])
    func refusesUnsupportedOrDamagedHeaders(field: Int) {
        var source = rom()
        source[0x7fc0+field] = field == 0x15 ? 0x22 : source[0x7fc0+field] ^ 0x10
        recalculateChecksum(&source, headers: [0x7fc0])
        #expect(throws: SNESCanoeTrialImage.PreparationError.self) { try SNESCanoeTrialImage(rom: source) }
    }
    @Test func refusesAmbiguousMapping() {
        var source = rom(); let hi = rom(hi: true)
        source.replaceSubrange(0xffc0..<0x10000, with: hi[0xffc0..<0x10000])
        recalculateChecksum(&source, headers: [0x7fc0, 0xffc0])
        #expect(throws: SNESCanoeTrialImage.PreparationError.self) { try SNESCanoeTrialImage(rom: source) }
    }
    @Test(arguments: [false, true]) func acceptsOrdinaryFastROM(hi: Bool) throws {
        var source = rom(hi: hi); let h = hi ? 0xffc0 : 0x7fc0
        source[h+0x15] |= 0x10
        recalculateChecksum(&source, headers: [h])
        #expect(try SNESCanoeTrialImage(rom: source).isHiROM == hi)
    }
    @Test func acceptsNonzeroDataIndices() throws {
        let source = rom(), sliced = (Data([0]) + source).dropFirst()
        #expect(try SNESCanoeTrialImage(rom: sliced).data == SNESCanoeTrialImage(rom: source).data)
    }
    @Test func refusesDamagedPayloadAndIrregularLengths() {
        var b = rom(); b[256] ^= 1
        #expect(throws: SNESCanoeTrialImage.PreparationError.self) { try SNESCanoeTrialImage(rom: b) }
        for invalid in [Data(), rom().dropLast(), rom()+Data([0]), Data(repeating: 0, count: 4*1024*1024+1024)] {
            #expect(throws: SNESCanoeTrialImage.PreparationError.self) { try SNESCanoeTrialImage(rom: Data(invalid)) }
        }
    }
}
