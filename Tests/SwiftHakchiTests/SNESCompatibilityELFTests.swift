import Foundation
import Testing
@testable import SwiftHakchi

// Hand-built inert ELF: one load segment, a dynamic table, symbol/string tables and
// a GLIBC version requirement. It contains no executable implementation.
func compatibilityELF(gnu:Bool=false) -> Data {
    var b = Data(count: 3 * 1024 * 1024)
    func w(_ at: Int, _ value: UInt32, _ n: Int = 4) {
        for i in 0..<n { b[at+i] = UInt8(truncatingIfNeeded: value >> (8*i)) }
    }
    b.replaceSubrange(0..<7, with: [127,69,76,70,1,1,1])
    w(16,3,2); w(18,40,2); w(20,1); w(28,52); w(32,4096); w(36,0x05000400)
    w(40,52,2); w(42,32,2); w(44,2,2); w(46,40,2); w(48,6,2)
    for (i,v) in [UInt32(1),0,0,0,UInt32(b.count),UInt32(b.count+4096),5,4096].enumerated() { w(52+i*4,v) }
    var strings=Data([0]); var offsets:[String:UInt32]=[:]
    let names = ["libc.so.6", "libpthread.so.0", "GLIBC_2.17"] + [
        "retro_set_environment", "retro_set_video_refresh", "retro_set_audio_sample", "retro_set_audio_sample_batch",
        "retro_set_input_poll", "retro_set_input_state", "retro_init", "retro_deinit", "retro_api_version",
        "retro_get_system_info", "retro_get_system_av_info", "retro_set_controller_port_device", "retro_reset",
        "retro_run", "retro_serialize_size", "retro_serialize", "retro_unserialize", "retro_cheat_reset",
        "retro_cheat_set", "retro_load_game", "retro_load_game_special", "retro_unload_game", "retro_get_region",
        "retro_get_memory_data", "retro_get_memory_size"]
    for name in names { offsets[name]=UInt32(strings.count); strings.append(Data(name.utf8)); strings.append(0) }
    b.replaceSubrange(1024..<1024+strings.count, with: strings)
    let tags:[(UInt32,UInt32)]=[(5,1024),(10,UInt32(strings.count)),(6,2048),(11,16),
        (1,offsets["libc.so.6"]!),(1,offsets["libpthread.so.0"]!),
        (4,3584),(0x6ffffffe,3072),(0x6fffffff,1),(0x6ffffff0,3456),(0,0)]
    for (i,t) in tags.enumerated() { w(256+i*8,t.0); w(260+i*8,t.1) }
    for (i,v) in [UInt32(2),256,256,0,UInt32(tags.count*8),UInt32(tags.count*8),4,4].enumerated() { w(84+i*4,v) }
    for (i,name) in names.dropFirst(3).enumerated() {
        let at=2048+(i+1)*16; w(at,offsets[name]!); w(at+4,512); w(at+8,4)
        b[at+12]=0x12; w(at+14,4,2)
    }
    // SHT_DYNSYM links to section2 (SHT_STRTAB).
    for (i,v) in [UInt32(0),11,2,2048,2048,UInt32(416),2,1,4,16].enumerated() { w(4136+i*4,v) }
    for (i,v) in [UInt32(0),3,2,1024,1024,UInt32(strings.count),0,0,1,0].enumerated() { w(4176+i*4,v) }
    for (i,v) in [UInt32(0),0x6ffffffe,2,3072,3072,32,2,1,4,0].enumerated() { w(4216+i*4,v) }
    w(3072,1,2); w(3074,1,2); w(3076,offsets["libc.so.6"]!); w(3080,16)
    w(3094,2,2); w(3096,offsets["GLIBC_2.17"]!)
    for (i,v) in [UInt32(0),1,6,512,512,128,0,0,4,0].enumerated() { w(4256+i*4,v) }
    for (i,v) in [UInt32(0),0x6fffffff,2,3456,3456,52,1,0,2,2].enumerated() { w(4296+i*4,v) }
    for i in 1...25 { w(3456+i*2,1,2) }
    // SysV hash: one bucket, every named function reachable in its chain.
    w(3584,1); w(3588,26); w(3592,1)
    for i in 1..<25 { w(3596+i*4,UInt32(i+1)) }
    if gnu {
        w(336,0x6ffffef5); w(340,4500); w(344,0); w(348,0); w(100,96); w(104,96)
        w(4500,1); w(4504,1); w(4508,1); w(4512,5); w(4520,1)
        var bloom:UInt32=0
        for (i,name) in names.dropFirst(3).enumerated() {
            let hash=name.utf8.reduce(UInt32(5381)){($0 &* 33) &+ UInt32($1)}
            bloom |= (1 << (hash%32)) | (1 << ((hash >> 5)%32))
            w(4524+i*4,(hash & ~UInt32(1)) | (i==24 ? 1 : 0))
        }
        w(4516,bloom)
    }
    return b
}
private func changing(_ original: Data, _ at: Int, _ value: UInt32, count:Int=4) -> Data {
    var b=original; for i in 0..<count { b[at+i]=UInt8(truncatingIfNeeded:value >> (i*8)) }; return b
}
struct SNESCompatibilityELFTests {
    @Test func largerCoreIsInspectedWithoutChangingLegacyRuntimeLimit() throws {
        let bytes=compatibilityELF(), elf=try SNESCompatibilityELF(data:bytes)
        #expect(elf.dependencies == ["libc.so.6", "libpthread.so.0"])
        #expect(elf.requiredVersions == ["GLIBC_2.17"])
        #expect(elf.exports.contains("retro_run"))
        #expect(elf.exports.count == 25)
        #expect(throws:(any Error).self) { try ARMRuntimeELF(data:bytes) }
    }
    @Test(arguments:[0,4,5,16,18,36,42,44,46,48])
    func wrongABIOrUnboundedHeadersRefuse(_ offset:Int) {
        var b=compatibilityELF(); b[offset] ^= 255
        if offset == 48 { b = changing(b,48,65535,count:2) }
        #expect(throws:(any Error).self) { try SNESCompatibilityELF(data:b) }
    }
    @Test(arguments:[UInt32(15),29,35,36,37,0x6ffffefa,0x7fffffff])
    func searchPathsAndUnreviewedLoaderFeaturesRefuse(_ tag:UInt32) {
        let b=changing(compatibilityELF(),304,tag)
        #expect(throws:(any Error).self) { try SNESCompatibilityELF(data:b) }
    }
    @Test func missingExportUnknownDependencyAndNewerGLIBCRefuse() {
        let original=compatibilityELF()
        var missing=original; missing[2076]=0 // first function becomes local
        var unknown=original; unknown[1025]=UInt8(ascii:"x")
        var newer=original
        let old=Array("GLIBC_2.17".utf8)
        if let at=(1024..<2048-old.count).first(where:{ Array(original[$0..<$0+old.count]) == old }) {
            newer.replaceSubrange(at..<at+old.count,with:Array("GLIBC_9.99".utf8))
        }
        for b in [missing,unknown,newer] { #expect(throws:(any Error).self) { try SNESCompatibilityELF(data:b) } }
    }
    @Test(arguments:["version-pointer","version-count","symbol-version","function-address","function-section","hash-chain","load-alignment","relocation-pointer","text-relocation"])
    func loaderSelectedMetadataCannotDisagreeWithInspectedSections(_ fault:String) {
        var b=compatibilityELF()
        switch fault {
        case "version-pointer": b=changing(b,316,4000)
        case "version-count": b=changing(b,324,2)
        case "symbol-version": b=changing(b,3458,3,count:2)
        case "function-address": b=changing(b,2068,UInt32.max)
        case "function-section": b=changing(b,2078,65535,count:2)
        case "hash-chain": b=changing(b,3592,0)
        case "load-alignment": b=changing(b,60,1)
        case "relocation-pointer": b=changing(b,336,17); b=changing(b,340,UInt32.max); b=changing(b,100,96); b=changing(b,104,96)
        default: b=changing(b,336,22); b=changing(b,340,0); b=changing(b,100,96); b=changing(b,104,96)
        }
        #expect(throws:(any Error).self) { try SNESCompatibilityELF(data:b) }
    }
    @Test func bothLoaderHashFormatsMustFindTheReviewedExports() throws {
        let original=compatibilityELF(gnu:true)
        #expect(try SNESCompatibilityELF(data:original).exports.contains("retro_run"))
        // A valid SysV table cannot conceal a broken GNU table selected by the loader.
        for b in [changing(original,4516,0), changing(original,4520,0),
                  changing(original,4524,1), changing(original,4508,UInt32.max)] {
            #expect(throws:(any Error).self) { try SNESCompatibilityELF(data:b) }
        }
    }
    @Test func damagedTablesAndExpansionRefuse() {
        let original=compatibilityELF()
        for b in [Data(original.prefix(100)),Data(count:8*1024*1024+1),
                  changing(original,4140,1),changing(original,4160,UInt32.max),
                  changing(original,4196,UInt32.max),changing(original,3080,UInt32.max)] {
            #expect(throws:(any Error).self) { try SNESCompatibilityELF(data:b) }
        }
    }
}
