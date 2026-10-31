import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESStartupAdapterServiceTests {
    @Test(arguments:["none","arguments","executable","linked-pid","hardlinked-pid"])
    func existingDaemonRequiresExactNULTerminatedArgumentsAndOwnedPIDFile(_ fault:String) throws {
        let root=try testDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let holder=Process();holder.executableURL=URL(fileURLWithPath:"/bin/sleep");holder.arguments=["30"];try holder.run()
        defer { if holder.isRunning { holder.terminate() };holder.waitUntilExit() }
        let pid=String(holder.processIdentifier),proc=root.appendingPathComponent("proc/"+pid)
        try FileManager.default.createDirectory(at:proc,withIntermediateDirectories:true)
        let loader=root.appendingPathComponent("ld-linux-armhf.so.3");try Data("fixture loader\n".utf8).write(to:loader)
        let shim="#!/bin/sh\nif test \"$1\" = stat; then /usr/bin/stat -f '%l' \"$4\"; else exec \"$@\"; fi\n"
        let bb=root.appendingPathComponent("busybox");try Data(shim.utf8).write(to:bb);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:bb.path)
        let runtime=BackupManifest.digest(try Data(contentsOf:loader))+"  "+loader.path+"\n"
        try Data(runtime.utf8).write(to:root.appendingPathComponent("runtime-files.sha256"))
        let pidfile=root.appendingPathComponent("daemon.pid");try Data((pid+"\n").utf8).write(to:pidfile)
        if fault=="linked-pid" {
            let actual=root.appendingPathComponent("pid-source");try FileManager.default.moveItem(at:pidfile,to:actual)
            try FileManager.default.createSymbolicLink(at:pidfile,withDestinationURL:actual)
        }
        if fault=="hardlinked-pid" { try FileManager.default.linkItem(at:pidfile,to:root.appendingPathComponent("pid-link")) }
        try FileManager.default.createSymbolicLink(at:proc.appendingPathComponent("exe"),withDestinationURL:fault=="executable" ? bb:loader)
        let argv=[loader.path,"--inhibit-cache","--inhibit-rpath","","--library-path",root.path,root.appendingPathComponent("clovershell").path]
        var command=Data((argv.joined(separator:"\0")+"\0").utf8)
        if fault=="arguments" { command.append(Data("extra\0".utf8)) }
        try command.write(to:proc.appendingPathComponent("cmdline"))
        let scripts=try SNESStartupAdapterScripts(binding:.init(sourceSnapshot:"SNES-US-Setup-11111111-1111-1111-1111-111111111111",setupManifestSHA256:String(repeating:"1",count:64),expectedHWID:String(repeating:"1",count:32)))
        let script=scripts.service.replacingOccurrences(of:"/mnt/swifthakchi",with:root.path).replacingOccurrences(of:"/proc/",with:root.path+"/proc/")
        let file=root.appendingPathComponent("service");try Data(script.utf8).write(to:file)
        let p=Process();p.executableURL=URL(fileURLWithPath:"/bin/sh");p.arguments=[file.path,"start"]
        p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice;try p.run();p.waitUntilExit()
        #expect((p.terminationStatus==0)==(fault=="none"))
        #expect(holder.isRunning)
        #expect(!FileManager.default.fileExists(atPath:root.appendingPathComponent("daemon.log").path))
    }
}

extension SNESStartupAdapterServiceTests {
    @Test func failedDaemonStartupRestoresOriginalUSBRevision() throws {
        let root=try testDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let gadget=root.appendingPathComponent("usb")
        try FileManager.default.createDirectory(at:gadget.appendingPathComponent("f_clover"),withIntermediateDirectories:true)
        func write(_ name:String,_ text:String) throws {
            let url=root.appendingPathComponent(name);try Data(text.utf8).write(to:url)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:url.path)
        }
        try write("busybox","#!/bin/sh\nif test \"$1\" = stat; then if test \"$3\" = '%h'; then /usr/bin/stat -f '%l' \"$4\"; else /usr/bin/stat -f '%z' \"$4\"; fi; else exec \"$@\"; fi\n")
        try write("ld-linux-armhf.so.3","#!/bin/sh\nexit 4\n")
        let attributes=["enable":"1","idVendor":"057e","idProduct":"0001","bcdDevice":"0230","bDeviceClass":"0","iProduct":"original","functions":"clover","f_clover/model":"3"]
        for (name,value) in attributes { try write("usb/"+name,value) }
        try write("original-usb","#!/bin/sh\nprintf '057e' > '\(gadget.path)/idVendor'\nprintf 'original' > '\(gadget.path)/iProduct'\nprintf '1' > '\(gadget.path)/enable'\n")
        let scripts=try SNESStartupAdapterScripts(binding:.init(sourceSnapshot:"SNES-US-Setup-11111111-1111-1111-1111-111111111111",setupManifestSHA256:String(repeating:"1",count:64),expectedHWID:String(repeating:"1",count:32)))
        let service=scripts.service.replacingOccurrences(of:"/mnt/swifthakchi",with:root.path).replacingOccurrences(of:"/sys/devices/virtual/android_usb/android0",with:gadget.path).replacingOccurrences(of:"/dev/usb_clover",with:"/dev/null")
        try write("service",service)
        try write("usb-wrapper",scripts.usbWrapper.replacingOccurrences(of:"/mnt/swifthakchi",with:root.path))
        let checks=BackupManifest.digest(try Data(contentsOf:root.appendingPathComponent("ld-linux-armhf.so.3")))+"  "+root.appendingPathComponent("ld-linux-armhf.so.3").path+"\n"
        try write("runtime-files.sha256",checks)
        let p=Process();p.executableURL=URL(fileURLWithPath:"/bin/sh");p.arguments=[root.appendingPathComponent("usb-wrapper").path,"start"]
        p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice;try p.run();p.waitUntilExit()
        #expect(p.terminationStatus==0)
        #expect(try String(contentsOf:gadget.appendingPathComponent("bcdDevice"),encoding:.utf8)=="0230")
        #expect(try String(contentsOf:gadget.appendingPathComponent("idVendor"),encoding:.utf8)=="057e")
        #expect(try String(contentsOf:gadget.appendingPathComponent("iProduct"),encoding:.utf8)=="original")
    }
}
