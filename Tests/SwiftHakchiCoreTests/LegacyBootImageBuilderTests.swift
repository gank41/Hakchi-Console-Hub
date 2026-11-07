import Foundation
import CryptoKit
import Testing
@testable import SwiftHakchiCore

func builderFixtureImage() throws -> Data {
    let archive = newcFixture([("init", 0o100755, Data("#!/bin/sh\n".utf8), 1),
        ("key-file", 0o100600, Data(repeating: 7, count: 32), 1)])
    let kernel = Data([1, 2, 3]), ramdisk = try LZOPArchive.store(archive)
    var bytes = Data(count: 2048)
    bytes.replaceSubrange(0..<8, with: Data("ANDROID!".utf8))
    for (offset, value) in [(8, UInt32(kernel.count)), (12, 0x40008000), (16, UInt32(ramdisk.count)),
        (20, 0x42000000), (28, 0x40f00000), (32, 0x40000100), (36, 2048)] {
        bytes.replaceSubrange(offset..<offset+4, with: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0*8)) })
    }
    bytes.replaceSubrange(48..<55, with: Data("test-us".utf8))
    bytes.replaceSubrange(64..<66, with: Data("ro".utf8))
    var hash = Insecure.SHA1()
    for section in [kernel, ramdisk, Data()] {
        hash.update(data: section)
        hash.update(data: Data((0..<4).map { UInt8(truncatingIfNeeded: UInt32(section.count) >> ($0*8)) }))
    }
    bytes.replaceSubrange(576..<596, with: Data(hash.finalize()))
    bytes.append(kernel); while bytes.count % 2048 != 0 { bytes.append(0) }
    bytes.append(ramdisk); while bytes.count % 2048 != 0 { bytes.append(0) }
    return bytes
}

struct LegacyBootImageBuilderTests {
    @Test func comparisonChecksDecodedContentsAndPreservedHeaderWithoutRebuilding() throws {
        let source = try builderFixtureImage()
        let original = try LegacyBootImageBuilder.inspect(source)
        let archive = try original.archive.updating(replacements: ["init": Data(repeating: 65, count: 40_000)])
        for encoding: LegacyBootImageBuilder.RamdiskEncoding in [.lzopStored, .lzopCompressed, .xz] {
            let image = try LegacyBootImageBuilder.build(source: source, kernel: original.kernel, archive: archive, ramdiskEncoding: encoding)
            #expect(try LegacyBootImageBuilder.matchesRebuild(image, source: source, kernel: original.kernel, archive: archive))
            #expect(try !LegacyBootImageBuilder.matchesRebuild(image, source: source, kernel: Data([9]), archive: archive))
            #expect(try !LegacyBootImageBuilder.matchesRebuild(image, source: source, kernel: original.kernel, archive: original.archive))
            var differentSource = source; differentSource[64] = 113
            #expect(try !LegacyBootImageBuilder.matchesRebuild(image, source: differentSource, kernel: original.kernel, archive: archive))
            var corrupted = image; corrupted[576] ^= 1
            #expect(throws: (any Error).self) {
                try LegacyBootImageBuilder.matchesRebuild(corrupted, source: source, kernel: original.kernel, archive: archive)
            }
        }
    }
    @Test func independentIdentifierAndPreservedHeader() throws {
        let id = LegacyBootImageBuilder.identifier(kernel: Data("abc".utf8), ramdisk: Data("def".utf8))
        #expect(id.map { String(format: "%02x", $0) }.joined() == "9c6fc5452226c14d4e57da050fb606f940943dc0")
        let original = try builderFixtureImage()
        let source = try LegacyBootImageBuilder.inspect(original)
        let archive = try source.archive.updating(replacements: ["init": Data("new startup".utf8)])
        let first = try LegacyBootImageBuilder.build(source: original, kernel: Data([4, 5, 6, 7]), archive: archive)
        #expect(first == (try LegacyBootImageBuilder.build(source: original, kernel: Data([4, 5, 6, 7]), archive: archive)))
        let checked = try LegacyBootImageBuilder.inspect(first)
        #expect(checked.archive == archive)
        #expect(checked.kernel == Data([4, 5, 6, 7]))
        #expect(first[12..<16] == original[12..<16])
        #expect(first[20..<576] == original[20..<576])
        #expect(checked.archive.entries[1].data == source.archive.entries[1].data)
    }
    @Test(arguments:[false,true]) func compressedImagePreservesOriginalContentsAndHeader(lzo:Bool) throws {
        let source=try builderFixtureImage(),original=try LegacyBootImageBuilder.inspect(source)
        let archive=try original.archive.updating(replacements:["init":Data(repeating:65,count:400_000)])
        let image=try LegacyBootImageBuilder.build(source:source,kernel:original.kernel,archive:archive,ramdiskEncoding:lzo ? .lzopCompressed:.xz)
        #expect(image.count<16_384)
        let checked=try LegacyBootImageBuilder.inspect(image)
        #expect(checked.archive==archive && checked.kernel==original.kernel)
        #expect(image[12..<16]==source[12..<16] && image[20..<576]==source[20..<576])
        let layout=try LegacyAndroidBootImage(data:image)
        #expect(image.subdata(in:layout.ramdiskRange).starts(with:lzo ? [0x89,0x4c,0x5a,0x4f,0,13,10,26,10]:[0xfd,0x37,0x7a,0x58,0x5a,0]))
    }
    @Test func unsupportedHeaderChangesCannotBeRebuilt() throws {
        let good = try builderFixtureImage()
        for index in [0, 24, 40, 44, 55, 575, 576, 607, 1000, 2052] {
            var bad = good; bad[index] ^= 255
            #expect(throws: (any Error).self) { try LegacyBootImageBuilder.inspect(bad) }
        }
        #expect(throws: (any Error).self) { try LegacyBootImageBuilder.inspect(good + Data([0])) }
    }
}
