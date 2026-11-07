import Foundation

enum GameGenieROMPatcher {
    static func validate(data:Data,system:GameGenieSystem,extension ext:String)throws {
        switch system {
        case .nes:guard ext.lowercased()=="nes" else{throw GameGenieError.unsupportedROM};_=try NESROMIdentity(data:data)
        case .snes:guard ["sfc","smc"].contains(ext.lowercased()) else{throw MappingError.unsupported("Use a raw .sfc or .smc ROM. SFROM and interleaved images are not supported for patching.")};_=try SNESLayout(data)
        case .genesis:guard ["md","bin","gen"].contains(ext.lowercased()) else{throw MappingError.unsupported("Use a raw, big-endian .md, .bin or .gen ROM. Interleaved SMD images are not supported.")};try validateGenesis(data)
        }
    }
    static func patch(data:Data,system:GameGenieSystem,extension ext:String,codes:[String])throws->NESGameGeniePatcher.Result {
        try validate(data:data,system:system,extension:ext)
        guard !codes.isEmpty,codes.count<=3200 else{throw GameGenieError.noCodes}
        if system == .nes{return try NESGameGeniePatcher.patch(data:data,codes:codes)}
        var writes:[Int:UInt8]=[:]
        func add(_ offset:Int,_ value:UInt8)throws {
            guard offset>=0,offset<data.count else{throw MappingError.unsupported("A code targets memory outside this ROM. Check the game version.")}
            if let old=writes[offset],old != value {throw GameGenieError.conflict};writes[offset]=value
        }
        var output=data
        if system == .snes {
            let layout=try SNESLayout(data)
            for code in codes {
                guard let decoded=GameGenieSNES.decode(code) else{throw GameGenieError.invalidCode(code)}
                try add(layout.offset(decoded.address),decoded.value)
            }
            for (offset,value) in writes {output[offset]=value}
            let h=layout.prefix+layout.header
            output[h+0x1C]=0xFF;output[h+0x1D]=0xFF;output[h+0x1E]=0;output[h+0x1F]=0
            let rom=output.dropFirst(layout.prefix)
            var sum=rom.reduce(UInt32(0)){$0+UInt32($1)}
            if layout.mirrorCount > 1 {
                sum += UInt32(layout.mirrorCount - 1) * rom.suffix(layout.tailLength).reduce(UInt32(0)){$0+UInt32($1)}
            }
            sum &= 0xFFFF
            output[h+0x1C]=UInt8((sum ^ 0xFFFF)&0xFF);output[h+0x1D]=UInt8(((sum ^ 0xFFFF)>>8)&0xFF)
            output[h+0x1E]=UInt8(sum&0xFF);output[h+0x1F]=UInt8((sum>>8)&0xFF)
            return .init(data:output,offsets:Array(Set(writes.keys).union([h+0x1C,h+0x1D,h+0x1E,h+0x1F])).sorted())
        }
        for code in codes {
            guard let decoded=GameGenieGenesis.decode(code) else{throw GameGenieError.invalidCode(code)}
            let offset=Int(decoded.address & 0xFFFFFE)
            guard offset>=0x200,offset+1<data.count else{throw MappingError.unsupported("A Genesis code targets RAM, cartridge metadata, or a location outside this ROM.")}
            try add(offset,UInt8(decoded.value>>8));try add(offset+1,UInt8(decoded.value&0xFF))
        }
        for (offset,value) in writes {output[offset]=value}
        var sum:UInt32=0
        for i in stride(from:0x200,to:output.count,by:2) {sum=(sum+UInt32(output[i])*256+UInt32(output[i+1]))&0xFFFF}
        output[0x18E]=UInt8(sum>>8);output[0x18F]=UInt8(sum&0xFF)
        return .init(data:output,offsets:Array(Set(writes.keys).union([0x18E,0x18F])).sorted())
    }
    private static func validateGenesis(_ data:Data)throws {
        guard data.count>=0x400,data.count<=4*1024*1024,data.count%2==0,
              String(data:data[0x100..<0x104],encoding:.ascii)=="SEGA" else{throw MappingError.unsupported("This is not a supported raw Genesis cartridge image.")}
        func word(_ offset:Int)->UInt32 {data[offset..<offset+4].reduce(UInt32(0)){($0<<8)|UInt32($1)}}
        let start=word(0x1A0),end=word(0x1A4)
        guard start==0,end==UInt32(data.count-1),data.count.nonzeroBitCount==1 else{throw MappingError.unsupported("This Genesis ROM uses a layout that needs separate mapping support.")}
        let title=String(decoding:data[0x120..<0x180],as:UTF8.self).uppercased()
        guard !["VIRTUA RACING","SUPER STREET FIGHTER","SONIC & KNUCKLES","SONIC AND KNUCKLES","PIER SOLAR","SUPER MARIO"].contains(where:title.contains) else {throw MappingError.unsupported("This Genesis cartridge needs a separately verified banking or special-chip mapper.")}
        if data[0x1B0]==0x52 && data[0x1B1]==0x41 {
            let ramStart=word(0x1B4)
            guard ramStart>=UInt32(data.count) else{throw MappingError.unsupported("This cartridge has a RAM window inside the ROM address range.")}
        }
    }
    struct SNESLayout {
        let prefix:Int,header:Int,hi:Bool,length:Int,tailLength:Int,mirrorCount:Int
        init(_ data:Data)throws {
            let offsetPrefix=data.count%32768==512 ? 512:0,payloadLength=data.count-offsetPrefix
            prefix=offsetPrefix;length=payloadLength
            guard length>=32768,length<=4*1024*1024 else {throw MappingError.unsupported("This SNES game uses a file size that Cheat Codes cannot safely patch yet.")}
            let baseSize = 1 << (Int.bitWidth - 1 - length.leadingZeroBitCount)
            let tail = length-baseSize
            guard tail==0 || (tail>=32768 && tail.nonzeroBitCount==1 && baseSize%tail==0) else {throw MappingError.unsupported("This SNES game uses a file layout that Cheat Codes cannot safely patch yet.")}
            tailLength=tail;mirrorCount=tail==0 ? 1:baseSize/tail
            let candidates=[(0x7FC0,false),(0xFFC0,true)].filter{h,high in
                let base=offsetPrefix+h
                guard base+64<=data.count else{return false}
                let mode=data[base+0x15],type=data[base+0x16],size=data[base+0x17],sram=data[base+0x18]
                let complement=UInt16(data[base+0x1C])|UInt16(data[base+0x1D])<<8,checksum=UInt16(data[base+0x1E])|UInt16(data[base+0x1F])<<8
                let reset=UInt16(data[base+0x3C])|UInt16(data[base+0x3D])<<8
                let expectedSize=tail==0 ? payloadLength:baseSize*2
                // Contra III's original US title overflows into the map-mode byte. Its
                // cartridge is LoROM; restrict the exception to the observed layout.
                let contra = !high && payloadLength == 1024*1024 && mode == 0x53 && type == 0 && size == 10 && sram == 0 && data[base+0x19] == 1 &&
                    data[base..<base+22] == Data("CONTRA3 THE ALIEN WARS".utf8)
                return (contra || (high ? [0x21,0x31]:[0x20,0x30]).contains(Int(mode))) && type<=2 && size<=12 && (1 << (Int(size)+10))==expectedSize && sram<=5 && (complement ^ checksum)==0xFFFF && reset>=0x8000 && reset<0xFFFF && data[base..<base+21].allSatisfy{(32...126).contains($0)}
            }
            guard candidates.count==1,let selected=candidates.first else{throw MappingError.unsupported("This game may use special cartridge hardware or a file layout that Cheat Codes cannot safely patch yet. Your original game is unchanged.")}
            header=selected.0;hi=selected.1
            let title=String(decoding:data[prefix+header..<prefix+header+21],as:UTF8.self).uppercased()
            guard !["BANDAI SFC-ADX","ADD-ON BASE","DEZAEMON","RPG-TCOOL","DERBY STALLION","SUPER DRIFT OUT","THOROUGHBRED","BATMAN--REVENGE"].contains(where:title.contains) else{throw MappingError.unsupported("This SNES cartridge needs a separately verified mapper.")}
        }
        func offset(_ address:UInt32)throws->Int {
            let bank=Int(address>>16),word=Int(address&0xFFFF)
            guard bank != 0x7E,bank != 0x7F,word>=0x8000 || (bank&0x7F)>=0x40 else{throw MappingError.unsupported("This code targets SNES RAM or hardware registers rather than ROM.")}
            if !hi {guard (bank&0x7F)<0x70,word>=0x8000 || (bank&0x7F)>=0x40 else{throw MappingError.unsupported("This code uses an SRAM or mirrored bank that is not supported for ROM patching yet.")}}
            let offset=hi ? ((bank&0x3F)<<16)|word:((bank&0x7F)<<15)|(word&0x7FFF)
            guard offset<length,!(header..<header+64).contains(offset) else{throw MappingError.unsupported("This code targets a mirrored bank or cartridge header. Check the ROM version.")}
            return prefix+offset
        }
    }
    enum MappingError:LocalizedError {case unsupported(String);var errorDescription:String?{if case .unsupported(let text)=self{return text};return nil}}
}
