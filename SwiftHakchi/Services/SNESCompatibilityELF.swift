import Foundation

/// Inert inspection for optional ARM libretro cores, separate from the historical
/// 2 MiB USB-runtime boundary. A passing inspection is not permission to execute:
/// package provenance, exact artifact hashes and console dependencies must also match.
struct SNESCompatibilityELF: Sendable {
    let dependencies: [String]
    let requiredVersions: Set<String>
    let exports: Set<String>

    static let requiredExports: Set<String> = [
        "retro_set_environment", "retro_set_video_refresh", "retro_set_audio_sample", "retro_set_audio_sample_batch",
        "retro_set_input_poll", "retro_set_input_state", "retro_init", "retro_deinit", "retro_api_version",
        "retro_get_system_info", "retro_get_system_av_info", "retro_set_controller_port_device", "retro_reset",
        "retro_run", "retro_serialize_size", "retro_serialize", "retro_unserialize", "retro_cheat_reset",
        "retro_cheat_set", "retro_load_game", "retro_load_game_special", "retro_unload_game", "retro_get_region",
        "retro_get_memory_data", "retro_get_memory_size"
    ]

    init(data: Data) throws {
        func fail() -> RecoveryProbeError {
            .refused("The optional emulator core uses an unsupported or damaged ARM library. Nothing was installed.")
        }
        guard (52...8*1024*1024).contains(data.count) else { throw fail() }
        let b=Array(data)
        func word(_ at:Int, _ n:Int=4) throws -> UInt32 {
            guard at >= 0, at <= b.count, n <= b.count-at else { throw fail() }
            return (0..<n).reduce(UInt32(0)) { $0 | UInt32(b[at+$1]) << ($1*8) }
        }
        func range(_ start:Int, _ size:Int) throws -> Range<Int> {
            guard start >= 0, start <= b.count, size >= 0, size <= b.count-start else { throw fail() }
            return start..<start+size
        }
        guard b[0..<7].elementsEqual([127,69,76,70,1,1,1]), [0,3].contains(b[7]),
              try word(16,2)==3, try word(18,2)==40, try word(20)==1,
              try word(36)==0x05000400, try word(40,2)==52,
              try word(42,2)==32, try word(46,2)==40 else { throw fail() }
        struct Segment { let type:UInt32, offset:Int, address:UInt64, size:Int, memory:UInt64, flags:UInt32 }
        let ph=Int(try word(28)), phCount=Int(try word(44,2))
        guard ph >= 52, (1...128).contains(phCount) else { throw fail() }
        _ = try range(ph,phCount*32)
        var segments:[Segment]=[]
        for i in 0..<phCount {
            let at=ph+i*32, size=Int(try word(at+16)), memory=UInt64(try word(at+20))
            let address=UInt64(try word(at+8)), offset=Int(try word(at+4)), align=try word(at+28)
            _ = try range(offset,size)
            guard UInt64(size)<=memory, address+memory <= 0x1_0000_0000,
                  (align==0 || (align & (align-1)==0 && address % UInt64(align)==UInt64(offset) % UInt64(align))) else { throw fail() }
            segments.append(.init(type:try word(at),offset:offset,address:address,size:size,memory:memory,flags:try word(at+24)))
        }
        let loads=segments.filter { $0.type==1 }, dynamics=segments.filter { $0.type==2 }
        guard !loads.isEmpty, dynamics.count==1, !segments.contains(where:{$0.type==3}),
              loads.reduce(UInt64(0),{$0+$1.memory}) <= 32*1024*1024 else { throw fail() }
        for (i,load) in loads.enumerated() where load.memory>0 {
            for other in loads.dropFirst(i+1) where other.memory>0 {
                guard load.address+load.memory <= other.address || other.address+other.memory <= load.address else { throw fail() }
            }
        }
        func mapped(_ address:UInt64, _ size:Int) throws -> Int {
            let owners=loads.filter { address >= $0.address && address+UInt64(size) <= $0.address+UInt64($0.size) }
            guard owners.count==1 else { throw fail() }
            return owners[0].offset+Int(address-owners[0].address)
        }
        let dynamic=dynamics[0]
        guard dynamic.size>=8, dynamic.size<=65536, dynamic.size%8==0,
              try mapped(dynamic.address,dynamic.size)==dynamic.offset else { throw fail() }
        var tags:[UInt32:[UInt32]]=[:], ended=false
        for at in stride(from:dynamic.offset,to:dynamic.offset+dynamic.size,by:8) {
            let tag=try word(at)
            if tag==0 { ended=true; break }
            tags[tag,default:[]].append(try word(at+4))
        }
        let forbidden:Set<UInt32>=[15,29,35,36,37,0x7fffffff,0x7ffffffd,0x6ffffefa,0x6ffffefb,0x6ffffefc,
                                    0x6000000f,0x60000010,0x60000011,0x60000012]
        let allowed:Set<UInt32>=[1,2,3,4,5,6,10,11,17,18,19,20,23,30,
            0x6ffffef5,0x6ffffff0,0x6ffffffe,0x6fffffff,0x6ffffffa,0x6ffffffb]
        guard ended, forbidden.isDisjoint(with:tags.keys), Set(tags.keys).isSubset(of:allowed),
              tags.allSatisfy({$0.key==1 || $0.value.count==1}),
              (tags[30]?.first ?? 0) & ~UInt32(8)==0,
              (tags[0x6ffffffb]?.first ?? 0) & ~UInt32(1)==0 else { throw fail() }
        func single(_ tag:UInt32) throws -> UInt32 {
            guard let values=tags[tag], values.count==1 else { throw fail() }; return values[0]
        }
        let stringSize=Int(try single(10))
        guard (1...1_048_576).contains(stringSize) else { throw fail() }
        let strings=try mapped(UInt64(single(5)),stringSize)
        func string(_ value:UInt32) throws -> String {
            let at=Int(value)
            guard at<stringSize, let end=b[strings+at..<strings+stringSize].firstIndex(of:0),
                  end-(strings+at)<=256, b[strings+at..<end].allSatisfy({(33...126).contains($0)}) else { throw fail() }
            return String(decoding:b[strings+at..<end],as:UTF8.self)
        }
        var dependencies:[String]=[]
        for value in tags[1] ?? [] {
            let name=try string(value)
            guard ["libc.so.6","libpthread.so.0"].contains(name), !dependencies.contains(name) else { throw fail() }
            dependencies.append(name)
        }
        guard Set(dependencies)==Set(["libc.so.6","libpthread.so.0"]), try single(11)==16 else { throw fail() }
        struct Section { let type:UInt32, address:UInt64, offset:Int, size:Int, link:Int, entry:Int, flags:UInt32 }
        let sh=Int(try word(32)), shCount=Int(try word(48,2))
        guard sh>=52, (1...256).contains(shCount) else { throw fail() }
        _ = try range(sh,shCount*40)
        var sections:[Section]=[]
        for i in 0..<shCount {
            let at=sh+i*40, type=try word(at+4), offset=Int(try word(at+16)), size=Int(try word(at+20))
            if type != 8 { _ = try range(offset,size) } // SHT_NOBITS occupies memory, not file bytes.
            sections.append(.init(type:type,address:UInt64(try word(at+12)),offset:offset,size:size,
                                  link:Int(try word(at+24)),entry:Int(try word(at+36)),flags:try word(at+8)))
        }
        func linkedStrings(_ section:Section) throws {
            guard sections.indices.contains(section.link) else { throw fail() }
            let linked=sections[section.link]
            guard linked.type==3, linked.offset==strings, linked.size==stringSize else { throw fail() }
        }
        let symbols=sections.filter{$0.type==11}
        guard symbols.count==1 else { throw fail() }
        let symbolsTable=symbols[0]
        try linkedStrings(symbolsTable)
        guard symbolsTable.entry==16, symbolsTable.size>=16, symbolsTable.size<=1_048_576, symbolsTable.size%16==0,
              symbolsTable.address==UInt64(try single(6)),
              try mapped(symbolsTable.address,symbolsTable.size)==symbolsTable.offset else { throw fail() }
        let symbolCount=symbolsTable.size/16
        var exports=Set<String>(), exportedIndices:[String:Int]=[:]
        for index in 0..<symbolCount {
            let at=symbolsTable.offset+index*16
            let name=try word(at), info=b[at+12], visibility=b[at+13] & 3, defined=Int(try word(at+14,2))
            if name>0, defined>0, [1,2].contains(info>>4), info & 15 == 2, [0,3].contains(visibility) {
                guard sections.indices.contains(defined) else { throw fail() }
                let section=sections[defined], address=UInt64(try word(at+4) & ~UInt32(1)), size=max(1,Int(try word(at+8)))
                guard section.type==1, section.flags & 6==6, address>=section.address,
                      address+UInt64(size)<=section.address+UInt64(section.size),
                      loads.contains(where:{$0.flags & 1==1 && address >= $0.address && address+UInt64(size)<=$0.address+UInt64($0.size)}) else { throw fail() }
                let value=try string(name)
                guard exports.insert(value).inserted else { throw fail() }
                exportedIndices[value]=index
            }
        }
        guard Self.requiredExports.isSubset(of:exports) else { throw fail() }
        let needs=sections.filter{$0.type==0x6ffffffe}
        guard needs.count==1 else { throw fail() }
        let need=needs[0]; try linkedStrings(need)
        guard (16...65536).contains(need.size), try mapped(need.address,need.size)==need.offset else { throw fail() }
        guard need.address==UInt64(try single(0x6ffffffe)) else { throw fail() }
        let versionCount=Int(try single(0x6fffffff))
        guard (1...16).contains(versionCount) else { throw fail() }
        var versions=Set<String>(), versionIndices=Set<UInt32>(), next=0, seen=Set<Int>()
        repeat {
            guard seen.insert(next).inserted, seen.count<=16, next>=0, next<=need.size-16 else { throw fail() }
            let at=need.offset+next, count=Int(try word(at+2,2))
            guard try word(at,2)==1, (1...128).contains(count), dependencies.contains(try string(word(at+4))) else { throw fail() }
            var aux=next+Int(try word(at+8)), auxSeen=Set<Int>()
            for i in 0..<count {
                guard auxSeen.insert(aux).inserted, aux>=next+16, aux<=need.size-16 else { throw fail() }
                let version=try string(word(need.offset+aux+8))
                // The currently reviewed core needs only these public glibc versions.
                guard ["GLIBC_2.4","GLIBC_2.7","GLIBC_2.17"].contains(version) else { throw fail() }
                let versionIndex=try word(need.offset+aux+6,2)
                guard (2..<0x8000).contains(versionIndex), versionIndices.insert(versionIndex).inserted else { throw fail() }
                versions.insert(version)
                let step=Int(try word(need.offset+aux+12))
                guard (i==count-1 && step==0) || (i<count-1 && step>=16) else { throw fail() }
                aux += step
            }
            let step=Int(try word(at+12))
            if step==0 { break }
            guard step>=16 else { throw fail() }; next += step
        } while true
        guard seen.count==versionCount else { throw fail() }
        let versionTables=sections.filter{$0.type==0x6fffffff}
        guard versionTables.count==1 else { throw fail() }
        let versionTable=versionTables[0]
        guard versionTable.size==symbolCount*2, versionTable.entry==2,
              versionTable.link==sections.firstIndex(where:{$0.type==11}),
              versionTable.address==UInt64(try single(0x6ffffff0)),
              try mapped(versionTable.address,versionTable.size)==versionTable.offset else { throw fail() }
        for index in 0..<symbolCount {
            let version=try word(versionTable.offset+index*2,2), base=version & 0x7fff
            guard base<=1 || versionIndices.contains(base) else { throw fail() }
        }
        for name in Self.requiredExports {
            guard let index=exportedIndices[name], try word(versionTable.offset+index*2,2)==1 else { throw fail() }
        }

        // Verify that the loader can actually find every required exported function.
        let hashAddress=UInt64(try single(4)), hash=try mapped(hashAddress,8)
        let bucketCount=Int(try word(hash)), chainCount=Int(try word(hash+4))
        guard (1...65536).contains(bucketCount), chainCount==symbolCount else { throw fail() }
        let hashBase=try mapped(hashAddress,(2+bucketCount+chainCount)*4)
        func sysvHash(_ name:String) -> UInt32 {
            var h:UInt32=0
            for byte in name.utf8 {
                h=(h &<< 4) &+ UInt32(byte); let high=h & 0xf0000000
                if high != 0 { h ^= high >> 24 }; h &= ~high
            }
            return h
        }
        func symbolName(_ index:Int) throws -> String { try string(word(symbolsTable.offset+index*16)) }
        for name in Self.requiredExports {
            var index=Int(try word(hashBase+8+Int(sysvHash(name)%UInt32(bucketCount))*4)), seen=Set<Int>(), found=false
            while index != 0 {
                guard index<symbolCount, seen.insert(index).inserted else { throw fail() }
                if try symbolName(index)==name { found=(exportedIndices[name]==index); break }
                index=Int(try word(hashBase+8+bucketCount*4+index*4))
            }
            guard found else { throw fail() }
        }
        if let gnuAddress=tags[0x6ffffef5]?.first {
            let address=UInt64(gnuAddress), header=try mapped(address,16)
            let buckets=Int(try word(header)), offset=Int(try word(header+4)), blooms=Int(try word(header+8)), shift=try word(header+12)
            guard (1...65536).contains(buckets), offset<symbolCount, (1...65536).contains(blooms),
                  blooms & (blooms-1)==0, shift<32 else { throw fail() }
            let table=try mapped(address,16+(blooms+buckets+symbolCount-offset)*4)
            for name in Self.requiredExports {
                let h=name.utf8.reduce(UInt32(5381)){($0 &* 33) &+ UInt32($1)}
                let bloom=try word(table+16+Int((h/32)%UInt32(blooms))*4)
                let mask=(UInt32(1) << (h%32)) | (UInt32(1) << ((h >> shift)%32))
                guard bloom & mask==mask else { throw fail() }
                var index=Int(try word(table+16+blooms*4+Int(h%UInt32(buckets))*4)), found=false
                guard index>=offset, index<symbolCount else { throw fail() }
                while index<symbolCount {
                    let chain=try word(table+16+(blooms+buckets+index-offset)*4)
                    if chain | 1 == h | 1, try symbolName(index)==name { found=(exportedIndices[name]==index); break }
                    if chain & 1==1 { break }; index += 1
                }
                guard found else { throw fail() }
            }
        }

        func relocations(pointer:UInt32,size:UInt32,entry:UInt32,plt:Bool) throws {
            let present=[pointer,size,entry].filter{tags[$0] != nil}
            if present.isEmpty { return }
            guard present.count==3, try single(entry)==(plt ? 17 : 8) else { throw fail() }
            let length=Int(try single(size))
            guard length>0, length<=1_048_576, length%8==0 else { throw fail() }
            let at=try mapped(UInt64(single(pointer)),length)
            for position in stride(from:at,to:at+length,by:8) {
                let destination=UInt64(try word(position)), info=try word(position+4), kind=info & 255, symbol=Int(info >> 8)
                guard (plt ? [UInt32(22)] : [2,21,23]).contains(kind), symbol<symbolCount,
                      kind != 23 || symbol==0, destination%4==0,
                      loads.contains(where:{$0.flags & 2==2 && destination >= $0.address && destination+4 <= $0.address+$0.memory}) else { throw fail() }
            }
            if !plt, let relativeCount=tags[0x6ffffffa]?.first {
                guard relativeCount<=length/8 else { throw fail() }
                for index in 0..<Int(relativeCount) { guard try word(at+index*8+4)==23 else { throw fail() } }
            }
        }
        try relocations(pointer:17,size:18,entry:19,plt:false)
        try relocations(pointer:23,size:2,entry:20,plt:true)
        guard tags[0x6ffffffa]==nil || tags[17] != nil else { throw fail() }
        if let got=tags[3]?.first {
            guard loads.contains(where:{$0.flags & 2==2 && UInt64(got)>=$0.address && UInt64(got)+4<=$0.address+$0.memory}) else { throw fail() }
        }
        self.dependencies=dependencies; self.requiredVersions=versions; self.exports=exports
    }
}
