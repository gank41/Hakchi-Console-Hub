import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESStartupAdapterPrepareTests {
    @Test(arguments:["none","occupied","linked-target","source-hash","root-hash","sed-fails","bind-fails","bound-check","library-hash","library-missing","library-link","lib-folder-link"])
    func stagingChecksInputsAndCleansOnlyOwnedRAMMounts(_ fault:String) throws {
        try staging(fault: fault, lean: true)
    }
    @Test func historicalStagingStillWorksWithoutRootLibraryCopy() throws {try staging(fault:"none",lean:false)}
    private func staging(fault:String,lean:Bool) throws {
        let binding=SNESRuntimeBinding(sourceSnapshot:"SNES-US-Setup-11111111-1111-1111-1111-111111111111",setupManifestSHA256:String(repeating:"1",count:64),expectedHWID:String(repeating:"1",count:32))
        let runtime=try SNESRuntimeFrame(runtimeFrameFixture())
        let scripts=try SNESStartupAdapterScripts(binding:binding,rootRuntime:lean ? runtime:nil),root=try testDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let source=root.appendingPathComponent("source"),system=root.appendingPathComponent("newroot"),mounts=root.appendingPathComponent("mounts"),calls=root.appendingPathComponent("calls")
        for folder in [source,system.appendingPathComponent("mnt"),system.appendingPathComponent("etc/clover"),system.appendingPathComponent("etc/init.d"),system.appendingPathComponent("lib")] {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        }
        func write(_ url:URL,_ text:String) throws { try Data(text.utf8).write(to:url) }
        try write(system.appendingPathComponent("etc/clover/boardtype"),"dp-shvc\n");try write(system.appendingPathComponent("etc/clover/REGION"),"USA\n")
        let stockUSB=system.appendingPathComponent("etc/init.d/S90usb-gadget");try write(stockUSB,"original USB fixture\n")
        try write(mounts,"rootfs / rootfs rw 0 0\ndevtmpfs /dev devtmpfs rw 0 0\nproc /proc proc rw 0 0\nsys /sys sysfs rw 0 0\n/dev/mapper/root-crypt \(system.path) squashfs ro 0 0\n")
        let shim="""
        #!/bin/sh
        case "$1" in
          uname) printf '3.4.113\\n';;
          devmem) printf '0x11111111\\n';;
          mount)
            shift
            if test "$1" = -t; then
              printf 'mount:tmpfs\\n' >> '\(calls.path)'
              printf 'tmpfs \(system.path)/mnt tmpfs rw 0 0\\n' >> '\(mounts.path)'
            else
              printf 'mount:bind\\n' >> '\(calls.path)'
              if test '\(fault)' = bind-fails; then exit 9; fi
              kind=tmpfs; if test '\(fault)' = bound-check; then kind=wrong; fi
              printf 'tmpfs \(system.path)/etc/init.d/S90usb-gadget %s rw 0 0\\n' "$kind" >> '\(mounts.path)'
            fi;;
          umount)
            printf 'umount:%s\\n' "$2" >> '\(calls.path)'
            /usr/bin/awk -v target="$2" '$2!=target' '\(mounts.path)' > '\(mounts.path).next'
            /bin/mv '\(mounts.path).next' '\(mounts.path)';;
          sed) shift; /usr/bin/sed "$@"; if test '\(fault)' = sed-fails; then exit 19; fi;;
          *) exec "$@";;
        esac
        """
        try write(source.appendingPathComponent("busybox"),shim)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:source.appendingPathComponent("busybox").path)
        let names=["busybox","clovershell","ld-linux-armhf.so.3","libc.so.6","original-usb","service","usb-wrapper"]
        for name in names where name != "busybox" { try write(source.appendingPathComponent(name),"fixture \(name)\n") }
        if lean {
            for (name,bytes) in [("ld-2.23.so",runtime.loader),("libc-2.23.so",runtime.libc)] {try bytes.write(to:system.appendingPathComponent("lib/"+name))}
            // The archive deliberately has no duplicate .so files.
            for name in ["ld-linux-armhf.so.3","libc.so.6"] {try FileManager.default.removeItem(at:source.appendingPathComponent(name))}
        }
        let runtimeChecks=try names.map { BackupManifest.digest(lean && $0=="ld-linux-armhf.so.3" ? runtime.loader:lean && $0=="libc.so.6" ? runtime.libc:try Data(contentsOf:source.appendingPathComponent($0))) + "  /mnt/swifthakchi/" + $0 + "\n" }.joined()
        try write(source.appendingPathComponent("runtime-files.sha256"),runtimeChecks)
        try write(source.appendingPathComponent("root-files.sha256"),BackupManifest.digest(try Data(contentsOf:stockUSB))+"  "+stockUSB.path+"\n")
        let checks=try (names.filter { !lean || !["ld-linux-armhf.so.3","libc.so.6"].contains($0) }+["runtime-files.sha256","root-files.sha256"]).map { BackupManifest.digest(try Data(contentsOf:source.appendingPathComponent($0)))+"  "+source.appendingPathComponent($0).path+"\n" }.joined()
        try write(source.appendingPathComponent("files.sha256"),checks)
        if fault=="occupied" { try write(system.appendingPathComponent("mnt/keep"),"preserve\n") }
        if fault=="linked-target" {
            try FileManager.default.removeItem(at:system.appendingPathComponent("mnt"))
            try FileManager.default.createSymbolicLink(at:system.appendingPathComponent("mnt"),withDestinationURL:source)
        }
        if fault=="source-hash" { try write(source.appendingPathComponent("clovershell"),"changed\n") }
        if fault=="root-hash" { try write(stockUSB,"changed original\n") }
        if fault=="library-hash" {try write(system.appendingPathComponent("lib/libc-2.23.so"),"changed library")}
        if fault=="library-missing" {try FileManager.default.removeItem(at:system.appendingPathComponent("lib/libc-2.23.so"))}
        if fault=="library-link" {
            try FileManager.default.removeItem(at:system.appendingPathComponent("lib/libc-2.23.so"))
            try FileManager.default.createSymbolicLink(at:system.appendingPathComponent("lib/libc-2.23.so"),withDestinationURL:source.appendingPathComponent("busybox"))
        }
        if fault=="lib-folder-link" {
            try FileManager.default.moveItem(at:system.appendingPathComponent("lib"),to:system.appendingPathComponent("libs"))
            try FileManager.default.createSymbolicLink(at:system.appendingPathComponent("lib"),withDestinationURL:system.appendingPathComponent("libs"))
        }
        var script=scripts.prepare.replacingOccurrences(of:#"(?<![A-Za-z0-9_/-])/swifthakchi(?=/|\s|$)"#,with:source.path,options:.regularExpression)
        script=script.replacingOccurrences(of:"/newroot",with:system.path).replacingOccurrences(of:"/proc/mounts",with:mounts.path)
        let path=root.appendingPathComponent("prepare");try write(path,script)
        let p=Process();p.executableURL=URL(fileURLWithPath:"/bin/sh");p.arguments=[path.path]
        p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice;try p.run();p.waitUntilExit()
        let actual=(try? String(contentsOf:calls,encoding:.utf8).split(separator:"\n").map(String.init)) ?? []
        let expected:[String]
        switch fault {
        case "none":expected=["mount:tmpfs","mount:bind"]
        case "sed-fails":expected=["mount:tmpfs","umount:"+system.path+"/mnt"]
        case "bind-fails":expected=["mount:tmpfs","mount:bind","umount:"+system.path+"/mnt"]
        case "bound-check":expected=["mount:tmpfs","mount:bind","umount:"+stockUSB.path,"umount:"+system.path+"/mnt"]
        case "library-hash","library-missing","library-link","lib-folder-link":expected=["mount:tmpfs","umount:"+system.path+"/mnt"]
        default:expected=[]
        }
        #expect(actual==expected)
        #expect((p.terminationStatus==0)==(fault=="none"))
        if fault=="none" && lean {
            #expect(try Data(contentsOf:system.appendingPathComponent("mnt/swifthakchi/libc.so.6"))==runtime.libc)
            #expect(try Data(contentsOf:system.appendingPathComponent("mnt/swifthakchi/ld-linux-armhf.so.3"))==runtime.loader)
        }
        #expect(try String(contentsOf:stockUSB,encoding:.utf8)==(fault=="root-hash" ? "changed original\n":"original USB fixture\n"))
        if fault=="occupied" { #expect(try String(contentsOf:system.appendingPathComponent("mnt/keep"),encoding:.utf8)=="preserve\n") }
    }
}
