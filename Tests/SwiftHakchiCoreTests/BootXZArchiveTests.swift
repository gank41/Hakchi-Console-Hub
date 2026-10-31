import Foundation
import Testing
@testable import SwiftHakchiCore

struct BootXZArchiveTests {
    @Test func decodesIndependentCRC32Fixture() throws {
        let hex="fd377a585a0000016922de360200210110000000a8708e86e008fb002b5d00379c8955f85c747058919151585e5ba7b619b68c53f7747a894c9419b746d0931dabc110ea005312d9bd000000f67a8356000143fc11000000b921f82f3e300d8b020000000001595a"
        let fixture=Data(stride(from:0,to:hex.count,by:2).map {UInt8(hex.dropFirst($0).prefix(2),radix:16)!})
        #expect(try BootXZArchive.decode(fixture)==Data(String(repeating:"original startup files\n",count:100).utf8))
        var corrupt=fixture;corrupt[50]^=1
        #expect(throws:(any Error).self) {try BootXZArchive.decode(corrupt)}
        for bad in [Data(fixture.dropLast()),fixture+Data([0]),fixture+fixture,Data([1,2,3])] {
            #expect(throws:(any Error).self) {try BootXZArchive.decode(bad)}
        }
    }
    @Test func nativeEncodingPreservesBytesAndRejectsUnboundedExpansion() throws {
        for bytes in [Data(),Data("abc".utf8),Data(repeating:65,count:300_000)] {
            let packed=try BootXZArchive.encode(bytes)
            #expect(packed.starts(with:[0xfd,0x37,0x7a,0x58,0x5a,0]))
            #expect(try BootXZArchive.decode(packed)==bytes)
        }
        let tooLarge=Data(repeating:65,count:16*1024*1024+1)
        #expect(throws:(any Error).self) {try BootXZArchive.encode(tooLarge)}
        #expect(throws:(any Error).self) {try BootXZArchive.decode(tooLarge)}
        if let path=ProcessInfo.processInfo.environment["SWIFTHAKCHI_XZ_EXPORT"] {
            try BootXZArchive.encode(Data(repeating:65,count:300_000)).write(to:URL(fileURLWithPath:path),options:.withoutOverwriting)
        }
    }
}
