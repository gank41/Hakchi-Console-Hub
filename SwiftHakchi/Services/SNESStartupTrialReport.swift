import Foundation
import SwiftHakchiCore

struct SNESStartupTrialExpectation:Sendable {
    let hwid:String,runtimeSHA256:String,wrapperSHA256:String
    let deviceVersion:UInt16,menuWrapperSHA256:String?
    var menuEnabled:Bool {[UInt16(0x6a05),UInt16(0x6a06),UInt16(0x6a07),UInt16(0x6a08),UInt16(0x6a09),UInt16(0x6a0a),UInt16(0x6a0b)].contains(deviceVersion)}
    var requiresCleanMenuLaunch:Bool {[UInt16(0x6a0a),UInt16(0x6a0b)].contains(deviceVersion)}
    init(hwid:String,runtimeSHA256:String,wrapperSHA256:String,deviceVersion:UInt16=0x6a04,menuWrapperSHA256:String?=nil) {
        self.hwid=hwid;self.runtimeSHA256=runtimeSHA256;self.wrapperSHA256=wrapperSHA256;self.deviceVersion=deviceVersion;self.menuWrapperSHA256=menuWrapperSHA256
    }
    func validate() throws {
        guard [UInt16(0x6a04),UInt16(0x6a05),UInt16(0x6a06),UInt16(0x6a07),UInt16(0x6a08),UInt16(0x6a09),UInt16(0x6a0a),UInt16(0x6a0b)].contains(deviceVersion),
              menuEnabled ? menuWrapperSHA256.map(SNESDataSnapshotChunk.isDigest)==true : menuWrapperSHA256==nil,
              hwid.count==32,SNESRuntimeBinding.hex(hwid),hwid.contains(where:{$0 != "0"}),
              [runtimeSHA256,wrapperSHA256].allSatisfy(SNESDataSnapshotChunk.isDigest) else {throw SNESRuntimeBinding.failure()}
    }
    static func checked(_ trial:PreparedSNESStartupTrial) throws -> Self {
        let image=try LegacyBootImageBuilder.inspect(trial.image)
        func member(_ name:String)throws->Data {
            guard let e=image.archive.entries.first(where:{$0.name=="swifthakchi/"+name}),e.fields[1]&0xf000==0x8000 else {throw SNESRuntimeBinding.failure()};return e.data
        }
        let value=Self(hwid:trial.expectedHWID,runtimeSHA256:BackupManifest.digest(try member("runtime-files.sha256")),wrapperSHA256:BackupManifest.digest(try member("usb-wrapper")),deviceVersion:trial.candidate.managementVersion,
            menuWrapperSHA256:trial.candidate.hasMenuSupport ? BackupManifest.digest(try member("menu-wrapper")):nil)
        try value.validate();return value
    }
}
struct SNESStartupTrialReport:Sendable {
    let raw:Data,mcpPID:Int,daemonPID:Int
    init(_ raw:Data,expected:SNESStartupTrialExpectation,challenge:UUID,temporaryMenu:Bool=false) throws {
        try expected.validate()
        guard raw.count<=16384,let text=String(data:raw,encoding:.ascii),text.utf8.allSatisfy({$0==10 || (32...126).contains($0)}) else {throw SNESRuntimeBinding.failure()}
        let lines=text.components(separatedBy:"\n")
        guard lines.count>=22,lines.last=="",lines.first=="SWIFTHAKCHI_SNES_STARTUP_TRIAL_V1" else {throw SNESRuntimeBinding.failure()}
        var fields:[String:String]=[:]
        let fieldCount=expected.requiresCleanMenuLaunch ? 18:16
        guard lines.count>=fieldCount+6 else {throw SNESRuntimeBinding.failure()}
        for line in lines[1...fieldCount] {
            guard line.utf8.count<=256,let index=line.firstIndex(of:"=") else {throw SNESRuntimeBinding.failure()}
            let key=String(line[..<index]);guard fields[key]==nil else {throw SNESRuntimeBinding.failure()};fields[key]=String(line[line.index(after:index)...])
        }
        var constants=["CHALLENGE":challenge.uuidString,"KERNEL":"3.4.113","BOARD":"dp-shvc","REGION":"USA","HWID":expected.hwid,
            "RUNTIME_SHA":expected.runtimeSHA256,"WRAPPER_SHA":expected.wrapperSHA256,"ROOT":"verified","INIT":"original-busybox",
            "MODULES":"clvcon,mali,sunxi_keyboard,sunxi_knob","DEVICES":"ready","USB":"verified-model-3","PROFILE":"existing"]
        if expected.requiresCleanMenuLaunch {constants["MCP_SIGBLK"]="0000000000000000";constants["UI_SIGBLK"]="0000000000000000"}
        func pid(_ key:String)->Int? {guard let s=fields[key],let n=Int(s),String(n)==s,(2...4194304).contains(n) else {return nil};return n}
        guard Set(fields.keys)==Set(constants.keys).union(["MCP_PID","DAEMON_PID","TAINT"]),constants.allSatisfy({fields[$0.key]==$0.value}),
              ["0","4096"].contains(fields["TAINT"]),let mcp=pid("MCP_PID"),let daemon=pid("DAEMON_PID"),mcp != daemon,
              lines[fieldCount+1]=="MOUNTS_BEGIN",lines.suffix(3)==["MOUNTS_END","END",""] else {throw SNESRuntimeBinding.failure()}
        guard !temporaryMenu || !expected.menuEnabled else {throw SNESRuntimeBinding.failure()}
        try Self.validateMounts(Array(lines[(fieldCount+2)..<lines.count-3]),menuEnabled:expected.menuEnabled,temporaryMenu:temporaryMenu)
        self.raw=raw;mcpPID=mcp;daemonPID=daemon
    }
    static func validateMounts(_ lines:[String],menuEnabled:Bool=false,temporaryMenu:Bool=false) throws {
        // switch_root can leave the initial pseudo-root listed beneath the real
        // squashfs root. Accept only this exact first entry, never another root.
        var lines=lines
        if lines.first=="rootfs / rootfs rw 0 0" {lines.removeFirst()}
        var expected=["/":"squashfs","/dev":"devtmpfs","/proc":"proc","/sys":"sysfs","/dev/pts":"devpts","/dev/shm":"tmpfs",
            "/tmp":"tmpfs","/run":"tmpfs","/var":"tmpfs","/var/lib":"ext4","/mnt":"tmpfs","/etc/init.d/S90usb-gadget":"tmpfs"]
        if menuEnabled {
            expected["/etc/init.d/S81clover-mcp"]="tmpfs"
            if lines.contains(where:{$0.split(separator:" ").dropFirst().first=="/usr/share/applications/clover-mcp.desktop"}) {expected["/usr/share/applications/clover-mcp.desktop"]="tmpfs"}
        }
        if temporaryMenu {expected["/usr/share/applications/clover-mcp.desktop"]="tmpfs"}
        guard lines.count==expected.count else {throw SNESRuntimeBinding.failure()};var seen=Set<String>()
        for line in lines {
            let p=line.split(separator:" ").map(String.init)
            guard p.count==6,p[4]=="0",p[5]=="0",seen.insert(p[1]).inserted,expected[p[1]]==p[2] else {throw SNESRuntimeBinding.failure()}
            let options=Set(p[3].split(separator:",").map(String.init))
            if p[1]=="/" {
                guard p[0]=="/dev/mapper/root-crypt",options.contains("ro"),!options.contains("rw") else {throw SNESRuntimeBinding.failure()}
            } else {
                guard options.contains("rw"),!options.contains("ro") else {throw SNESRuntimeBinding.failure()}
                if p[1]=="/var/lib" {guard p[0]=="/dev/nandc" else {throw SNESRuntimeBinding.failure()}}
                else {guard !p[0].hasPrefix("/dev/nand"),!p[0].hasPrefix("/dev/mapper/") else {throw SNESRuntimeBinding.failure()}}
            }
        }
    }
}
