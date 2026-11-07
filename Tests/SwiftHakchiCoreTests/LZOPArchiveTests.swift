import Foundation
import Testing
@testable import SwiftHakchiCore

struct LZOPArchiveTests {
    @Test func adlerChecksumMatchesIndependentVectorsAcrossBlockBoundaries() {
        // Expected values from zlib, for repeating 00...ff bytes.
        let vectors: [(Int, UInt32)] = [
            (0, 0x00000001), (1, 0x00010001), (5551, 0xc77eb190),
            (5552, 0x79ccb23f), (5553, 0x2ccab2ef), (262144, 0x8f901de3),
            (262145, 0xad731de3), (4194304, 0x9effde30)
        ]
        let bytes = (0..<4194304).map { UInt8(truncatingIfNeeded: $0) }
        for (count, expected) in vectors {
            #expect(LZOPArchive.checksum(Array(bytes.prefix(count)), crc: false) == expected)
        }
    }
    // A stored-only fallback must not pass as a compressed startup package.
    @Test func strongCompressionIsBoundedDeterministicAndPreservesAllBlocks() throws {
        let input=Data(repeating:65,count:600_000)
        let encoded=try LZOPArchive.compress(input)
        #expect(encoded.count<10_000)
        #expect(try LZOPArchive.decode(encoded)==input)
        #expect(try LZOPArchive.compress(input)==encoded)
        #expect(try LZOPArchive.decode(LZOPArchive.compress(Data())).isEmpty)
        var seed:UInt32=12345
        let random=Data((0..<300_000).map { _ -> UInt8 in seed=1664525 &* seed &+ 1013904223;return UInt8(truncatingIfNeeded:seed>>24) })
        #expect(try LZOPArchive.decode(LZOPArchive.compress(random))==random)
        #expect(throws:(any Error).self) {try LZOPArchive.compress(Data(count:LZOPArchive.maximumSize+1))}
        for count in [0,8,38,encoded.count-1] {#expect(throws:(any Error).self) {try LZOPArchive.decode(Data(encoded.prefix(count)))}}
        var changed=encoded;changed[46]^=1
        #expect(throws:(any Error).self) {try LZOPArchive.decode(changed)}
    }

    @Test func independentlyEncodedStoredAndCompressedFixtures() throws {
        func bytes(_ hex: String) -> Data {
            Data(stride(from: 0, to: hex.count, by: 2).map { n in
                UInt8(hex.dropFirst(n).prefix(2), radix: 16)!
            })
        }
        let stored = bytes("894c5a4f000d0a1a0a103020a00940010100000001000000000000000000000000001cb9014d0000000300000003024d012761626300000000")
        #expect(try LZOPArchive.decode(stored) == Data("abc".utf8))
        #expect(try LZOPArchive.store(Data("abc".utf8)) == stored)
        let compressed = bytes("894c5a4f000d0a1a0a103020a00940010100000001000000000000000000000000001cb9014d0000012c00000022cb9e4c2d02414141414120f3100000014141414141414141414141414141414141414111000000000000")
        #expect(try LZOPArchive.decode(compressed) == Data(repeating: 65, count: 300))
        var invalid = compressed; invalid.replaceSubrange(50..<54, with: [0, 0, 0, 0])
        #expect(throws: (any Error).self) { try LZOPArchive.decode(invalid) }
    }
    @Test func storedRoundTripIsDeterministicAndBounded() throws {
        let bytes = Data(repeating: 65, count: 300_000)
        let first = try LZOPArchive.store(bytes)
        #expect(first == (try LZOPArchive.store(bytes)))
        #expect(try LZOPArchive.decode(first) == bytes)
        #expect(try LZOPArchive.decode(LZOPArchive.store(Data())).isEmpty)
        #expect(throws: (any Error).self) { try LZOPArchive.store(Data(count: 16 * 1024 * 1024 + 1)) }
    }
    @Test func framingChecksumAndDecoderFailuresAreErrors() throws {
        let valid = try LZOPArchive.store(Data("abc".utf8))
        for index in [0, 9, 15, 17, 33, valid.count - 5] {
            var bad = valid; bad[index] ^= 0x80
            #expect(throws: (any Error).self) { try LZOPArchive.decode(bad) }
        }
        for n in [0, 8, 20, valid.count - 1] {
            #expect(throws: (any Error).self) { try LZOPArchive.decode(Data(valid.prefix(n))) }
        }
        #expect(throws: (any Error).self) { try LZOPArchive.decode(valid + Data([1])) }
    }
    @Test func uncheckedLengthsFeaturesAndChecksumsCannotReachDecoder() throws {
        let good = try LZOPArchive.store(Data("abc".utf8))
        func repairedHeader(_ offset: Int, _ replacement: [UInt8]) -> Data {
            var bytes = good; bytes.replaceSubrange(offset..<offset+replacement.count, with: replacement)
            let sum = LZOPArchive.checksum(Array(bytes[9..<34]), crc: false)
            bytes.replaceSubrange(34..<38, with: LZOPArchive.bigEndian(sum))
            return bytes
        }
        // Each header's checksum is valid: feature/version/method validation must reject it.
        for bytes in [repairedHeader(9, [0xff, 0xff]), repairedHeader(15, [4]),
                      repairedHeader(17, [0, 0, 8, 1]), repairedHeader(17, [0, 0, 4, 1]),
                      repairedHeader(17, [0, 0, 0, 0x41])] {
            #expect(throws: (any Error).self) { try LZOPArchive.decode(bytes) }
        }
        var huge = good; huge.replaceSubrange(38..<42, with: [255, 255, 255, 255])
        #expect(throws: (any Error).self) { try LZOPArchive.decode(huge) }
        // Valid framing, but impossible LZO payload: safe decoder must return an error.
        var invalid = good; invalid.replaceSubrange(38..<42, with: [0, 0, 1, 0])
        #expect(throws: (any Error).self) { try LZOPArchive.decode(invalid) }
        #expect(throws: (any Error).self) { try LZOPArchive.decode(Data(count: LZOPArchive.maximumSize + 1)) }
    }
}
