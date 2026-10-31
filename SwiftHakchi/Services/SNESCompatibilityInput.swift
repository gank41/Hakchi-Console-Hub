import Foundation

/// A short, explicit RESET trace. Evidence only; never grants emulator eligibility.
struct SNESCompatibilityInputFrame: Sendable {
    static let maximumBytes=4096
    let raw: Data
    let device: String
    let resetKey: UInt16?
    init(_ raw: Data, challenge: UUID, context: String, hwid: String) throws {
        try SNESCompatibilitySupportFrame.requireBinding(context:context,hwid:hwid)
        guard raw.count<=Self.maximumBytes,let text=String(data:raw,encoding:.utf8) else {throw SNESCompatibilitySupportFrame.failure()}
        let lines=text.components(separatedBy:"\n")
        guard lines.count==8,lines[0]=="HAKCHI_SNES_RESET_INPUT_V1",lines[1]=="CHALLENGE="+challenge.uuidString,
              lines[2]=="CONTEXT="+context,lines[3]=="HWID="+hwid,lines[4].hasPrefix("DEVICE="),
              lines[5].hasPrefix("EVENTS="),lines[6]=="END",lines[7].isEmpty else {throw SNESCompatibilitySupportFrame.failure()}
        let device=String(lines[4].dropFirst(7)),hex=String(lines[5].dropFirst(7))
        guard device.range(of:#"^/dev/input/event([0-9]|[12][0-9]|3[01])$"#,options:.regularExpression) != nil,
              hex.utf8.count<=512,hex.utf8.count%32==0,hex.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else {throw SNESCompatibilitySupportFrame.failure()}
        let chars=Array(hex.utf8);var bytes=[UInt8]()
        for i in stride(from:0,to:chars.count,by:2) {
            func nibble(_ x:UInt8)->UInt8{x<=57 ? x-48:x-87}
            bytes.append(nibble(chars[i])*16+nibble(chars[i+1]))
        }
        func u16(_ i:Int)->UInt16{UInt16(bytes[i])|UInt16(bytes[i+1])<<8}
        func u32(_ i:Int)->UInt32{(0..<4).reduce(0){$0|UInt32(bytes[i+$1])<<($1*8)}}
        var keys=Set<UInt16>(),down=Set<UInt16>(),completed=Set<UInt16>(),ordered=true
        for i in stride(from:0,to:bytes.count,by:16) {
            let type=u16(i+8),code=u16(i+10),value=u32(i+12)
            guard [UInt16(0),1,4].contains(type),u32(i+4)<1_000_000 else {throw SNESCompatibilitySupportFrame.failure()}
            if type==1 {
                guard value<=2 else {throw SNESCompatibilitySupportFrame.failure()}
                keys.insert(code)
                if value==1 {
                    if down.contains(code) {ordered=false}
                    down.insert(code)
                }
                if value==0 {
                    if down.remove(code) == nil {ordered=false} else {completed.insert(code)}
                }
            }
        }
        self.raw=raw;self.device=device
        resetKey=ordered && keys.count==1 && completed==keys && down.isEmpty ? keys.first:nil
    }
}
enum SNESCompatibilityInputCommand {
    static func read(challenge: UUID, context: String, hwid: String) throws -> String {
        let base=try SNESCompatibilitySupportCommand.read(challenge:challenge,context:context,hwid:hwid)
        let marker="printf 'HAKCHI_SNES_COMPAT_SUPPORT_V1"
        guard let stop=base.range(of:marker) else {throw SNESCompatibilitySupportFrame.failure()}
        return String(base[..<stop.lowerBound]) + #"""
        set -o pipefail
        input_device=''
        for index in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do
          path="/sys/class/input/event$index/device/name"
          if test -f "$path";then
            name=$("$B" head -c 65 "$path")
            if test "$name" = sunxi-keyboard;then
              test -z "$input_device"
              input_device="/dev/input/event$index"
            fi
          fi
        done
        test -n "$input_device" && test -c "$input_device" && test ! -L "$input_device"
        test "$("$B" stat -c '%u' "$input_device")" = 0
        timeout_help=$("$B" timeout --help 2>&1 || :)
        case "$timeout_help" in
          *'[-t SECS]'*) timeout_style=old;;
          *'SECS PROG'*) timeout_style=new;;
          *) exit 84;;
        esac
        read_events() {
          if test "$timeout_style" = old;then
            "$B" timeout -t 60 "$B" dd if="$input_device" bs=16 count=16 2>/dev/null
          else
            "$B" timeout 60 "$B" dd if="$input_device" bs=16 count=16 2>/dev/null
          fi
        }
        """# + "\n" +
        "printf 'HAKCHI_SNES_RESET_INPUT_V1\\nCHALLENGE=\(challenge.uuidString)\\nCONTEXT=\(context)\\nHWID=\(hwid)\\nDEVICE=%s\\nEVENTS=' \"$input_device\"\n" + #"""
        set +e
        read_events | "$B" od -An -v -tx1 | "$B" tr -d ' \n'
        result=$?
        set -e
        case "$result" in 0|124|143) ;; *) exit 85;;esac
        printf '\n'
        no_game;test "$menu_pid" = "$original_menu_pid"
        printf 'END\n'
        """# + "\n"
    }
}

/// One observed switch event, tied to a pre-shutdown connection. Evidence only.
struct SNESPowerInputFrame: Sendable {
    let raw:Data,device:String
    let eventType:UInt16,eventCode:UInt16
    let eventValue:UInt32
    init(_ raw:Data,challenge:UUID,context:String,hwid:String)throws {
        try SNESCompatibilitySupportFrame.requireBinding(context:context,hwid:hwid)
        guard raw.count<=4096,let text=String(data:raw,encoding:.utf8) else {throw SNESCompatibilitySupportFrame.failure()}
        let lines=text.components(separatedBy:"\n")
        guard lines.count==8,lines[0]=="HAKCHI_SNES_POWER_INPUT_V1",lines[1]=="CHALLENGE="+challenge.uuidString,
              lines[2]=="CONTEXT="+context,lines[3]=="HWID="+hwid,lines[4].hasPrefix("DEVICE="),
              lines[5].hasPrefix("EVENTS="),lines[6]=="END",lines[7].isEmpty else {throw SNESCompatibilitySupportFrame.failure()}
        let device=String(lines[4].dropFirst(7)),hex=Array(lines[5].dropFirst(7).utf8)
        guard device.range(of:#"^/dev/input/event([0-9]|[12][0-9]|3[01])$"#,options:.regularExpression) != nil,
              hex.count==32,hex.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else {throw SNESCompatibilitySupportFrame.failure()}
        func nibble(_ x:UInt8)->UInt8{x<=57 ? x-48:x-87}
        var b=[UInt8]();for i in stride(from:0,to:32,by:2){b.append(nibble(hex[i])*16+nibble(hex[i+1]))}
        func u16(_ i:Int)->UInt16{UInt16(b[i])|UInt16(b[i+1])<<8}
        func u32(_ i:Int)->UInt32{(0..<4).reduce(0){$0|UInt32(b[i+$1])<<($1*8)}}
        let type=u16(8),code=u16(10),value=u32(12)
        guard u32(4)<1_000_000,type==1,(1...767).contains(code),value<=1 else {throw SNESCompatibilitySupportFrame.failure()}
        self.raw=raw;self.device=device;self.eventType=type;self.eventCode=code;self.eventValue=value
    }
}
enum SNESPowerInputCommand {
    static func checkedResponse(_ result:SSHResult,challenge:UUID)throws->Data {
        guard result.succeeded,result.stderr=="HC_POWER_READER_READY_\(challenge.uuidString)\n",result.stdoutData.count<=4096 else {throw SNESCompatibilitySupportFrame.failure()}
        return result.stdoutData
    }
    static func hasReadyMarker(_ stderr:Data,challenge:UUID)->Bool {
        stderr.range(of:Data("HC_POWER_READER_READY_\(challenge.uuidString)\n".utf8)) != nil
    }
    /// Reads one event. A power-off may sever the connection before a complete result.
    static func read(challenge:UUID,context:String,hwid:String)throws->String {
        let base=try SNESCompatibilityInputCommand.read(challenge:challenge,context:context,hwid:hwid)
        guard base.contains("sunxi-keyboard"),base.contains("count=16"),base.contains("HAKCHI_SNES_RESET_INPUT_V1"),
              base.contains("no_game;test \"$menu_pid\" = \"$original_menu_pid\"") else {throw SNESCompatibilitySupportFrame.failure()}
        return base.replacingOccurrences(of:"sunxi-keyboard",with:"sunxi-knob")
            .replacingOccurrences(of:"count=16",with:"count=1")
            .replacingOccurrences(of:"timeout -t 60",with:"timeout -t 180")
            .replacingOccurrences(of:"timeout 60",with:"timeout 180")
            .replacingOccurrences(of:"HAKCHI_SNES_RESET_INPUT_V1",with:"HAKCHI_SNES_POWER_INPUT_V1")
            .replacingOccurrences(of:"no_game;test \"$menu_pid\" = \"$original_menu_pid\"",with:":")
            .replacingOccurrences(of:"dd if=\"$input_device\" bs=16 count=1",with:"dd bs=16 count=1 <&8")
            .replacingOccurrences(of:"set +e\nread_events",with:"exec 8<\"$input_device\"\nprintf 'HC_POWER_READER_READY_\(challenge.uuidString)\\n' >&2\nset +e\nread_events")
    }
}
