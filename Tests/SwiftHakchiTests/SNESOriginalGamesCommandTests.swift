import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESOriginalGamesCommandTests {
    @Test(arguments:["none","link","oversize","missing-rom","missing-art","changed-read","root-rw"])
    func actualProducerReadsOnlyBoundedOriginalAssets(_ fault:String)throws {
        let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let games=root.appendingPathComponent("games"),etc=root.appendingPathComponent("etc"),bb=root.appendingPathComponent("busybox"),mounts=root.appendingPathComponent("mounts")
        try FileManager.default.createDirectory(at:games,withIntermediateDirectories:true);try FileManager.default.createDirectory(at:etc,withIntermediateDirectories:false)
        try Data("dp-shvc\n".utf8).write(to:etc.appendingPathComponent("boardtype"));try Data("USA\n".utf8).write(to:etc.appendingPathComponent("REGION"))
        try Data("rootfs / rootfs rw 0 0\n/dev/mapper/root-crypt / squashfs \(fault=="root-rw" ? "rw":"ro") 0 0\n".utf8).write(to:mounts)
        let codes=["CLV-P-AAAAA","CLV-P-BBBBB"]
        for code in codes {
            let dir=games.appendingPathComponent(code);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:false)
            try Data("[Desktop Entry]\nName=Été\nExec=/usr/bin/original\n".utf8).write(to:dir.appendingPathComponent(code+".desktop"))
            try Data([137,80,78,71,13,10,26,10]).write(to:dir.appendingPathComponent(code+".png"))
            try Data(repeating:127,count:65536).write(to:dir.appendingPathComponent(code+".sfrom"))
        }
        let launcher=root.appendingPathComponent("launcher");try Data("#!/bin/sh\nexec /usr/bin/emulator \"$@\"\n".utf8).write(to:launcher)
        let first=games.appendingPathComponent(codes[0]),icon=first.appendingPathComponent(codes[0]+".png"),rom=first.appendingPathComponent(codes[0]+".sfrom")
        if fault=="link" {try FileManager.default.removeItem(at:icon);try FileManager.default.createSymbolicLink(at:icon,withDestinationURL:root.appendingPathComponent("outside"))}
        if fault=="oversize" {let h=try FileHandle(forWritingTo:rom);try h.truncate(atOffset:16*1024*1024+1);try h.close()}
        if fault=="missing-rom" {try FileManager.default.removeItem(at:rom)}
        if fault=="missing-art" {try FileManager.default.removeItem(at:icon)}
        let shim="""
        #!/bin/sh
        case "$1" in
          uname) printf '3.4.113\\n';;
          devmem) printf '0x11111111\\n';;
          cat)
            if test '\(fault)' = changed-read && test "${2##*/}" = CLV-P-AAAAA.desktop; then printf 'changed'; exit 0; fi
            exec "$@";;
          sha256sum|awk|head|tail|wc|tr) exec "$@";;
          *) exit 97;;
        esac
        """
        let shimData=Data(shim.utf8);try shimData.write(to:bb);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:bb.path)
        var script=try SNESOriginalGamesCommand.script(binding:originalGamesBinding(),challenge:originalGamesChallenge)
        script=script.replacingOccurrences(of:"/mnt/swifthakchi/busybox",with:bb.path)
            .replacingOccurrences(of:SNESRAMProbeScripts.busyboxSHA256,with:BackupManifest.digest(shimData))
            .replacingOccurrences(of:"/usr/share/games",with:games.path)
            .replacingOccurrences(of:"/usr/bin/clover-canoe-shvc",with:launcher.path)
            .replacingOccurrences(of:"/etc/clover",with:etc.path)
            .replacingOccurrences(of:"/proc/mounts",with:mounts.path)
        let file=root.appendingPathComponent("capture");try Data(script.utf8).write(to:file)
        func state()throws->[String:Data] {
            var values:[String:Data]=[:]
            let scan=try #require(FileManager.default.enumerator(at:games,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey]))
            for case let url as URL in scan {
                let v=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
                if v.isSymbolicLink==true {values[url.path]=Data((try FileManager.default.destinationOfSymbolicLink(atPath:url.path)).utf8)}
                else if v.isRegularFile==true {values[url.path]=try Data(contentsOf:url)}
            };return values
        }
        let before=try state(),p=Process(),out=Pipe(),err=Pipe();p.executableURL=URL(fileURLWithPath:"/bin/sh");p.arguments=[file.path];p.standardOutput=out;p.standardError=err
        try p.run();let bytes=out.fileHandleForReading.readDataToEndOfFile();let errors=err.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
        #expect(try state()==before)
        if fault=="none" {
            #expect(p.terminationStatus==0,"Producer stderr: \(String(decoding:errors,as:UTF8.self))")
            let frame=try SNESOriginalGamesFrame(bytes,binding:originalGamesBinding(),challenge:originalGamesChallenge)
            #expect(frame.entries.map(\.code)==codes && frame.entries[0].romBytes==65536)
            #expect(frame.entries[0].headers==Data(repeating:127,count:96))
            #expect(frame.entries[0].romSHA256==BackupManifest.digest(Data(repeating:127,count:65536)))
            #expect(frame.entries[0].files[0].data==Data("[Desktop Entry]\nName=Été\nExec=/usr/bin/original\n".utf8))
        } else {
            #expect(throws:(any Error).self) {try SNESOriginalGamesFrame(bytes,binding:originalGamesBinding(),challenge:originalGamesChallenge)}
        }
    }
}
