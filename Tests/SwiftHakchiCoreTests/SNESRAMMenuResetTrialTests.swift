import Foundation
import Testing
@testable import SwiftHakchiCore

struct SNESRAMMenuResetTrialTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HC_MENU_OWNER"] != nil, "Requires private local trial files"))
    func resetImageWiresVerifiedOwnerAndRejectsTampering() throws {
        let env=ProcessInfo.processInfo.environment
        let source=try Data(contentsOf: URL(fileURLWithPath: try #require(env["HC_MENU_SOURCE"])))
        let root=URL(fileURLWithPath: try #require(env["HC_MENU_PAYLOAD"]),isDirectory:true)
        let names=["retroarch","snes9x2010_libretro.so","alien3.smc","retroarch.cfg","trial-start","trial-owner","autoconfig/Nintendo Clovercon - controller1.cfg"]
        let payload=try Dictionary(uniqueKeysWithValues:names.map { ($0,try Data(contentsOf:root.appendingPathComponent($0))) })
        let report=try Data(contentsOf:URL(fileURLWithPath:try #require(env["HC_MENU_REPORT"])))
        let art=try Data(contentsOf:URL(fileURLWithPath:try #require(env["HC_MENU_ART"])))
        let owner=try Data(contentsOf:URL(fileURLWithPath:try #require(env["HC_MENU_OWNER"])))
        let built=try SNESRAMMenuResetTrialBuilder.build(source:source,payload:payload,report:report,artwork:art,owner:owner)
        let image=try LegacyBootImageBuilder.inspect(built.image)
        let files=Dictionary(uniqueKeysWithValues:image.archive.entries.map { ($0.name,$0.data) })
        let start=try #require(files["probe/compat/trial-start"].flatMap { String(data:$0,encoding:.utf8) })
        #expect(files["probe/compat/trial-menu-owner"] == owner)
        #expect(start.contains("trial-menu-owner\" \"$waitfd\" \"$startfd\" \"$finishfd\""))
        #expect(start.contains("test -n \"$waitfd\""))
        #expect(!start.contains("$R/trial-owner\"\n"))
        let begin = try #require(start.range(of: "# Record only the three transition descriptor arguments")?.lowerBound)
        let end = try #require(start.range(of: "stage=display-owner", range: begin..<start.endIndex)?.lowerBound)
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:temp) }
        let bb=temp.appendingPathComponent("busybox"),status=temp.appendingPathComponent("status")
        try Data("#!/bin/sh\nif [ \"$1\" = readlink ]; then printf 'anon_inode:[eventfd]\\n'; exit 0; fi\nexec \"$@\"\n".utf8).write(to:bb)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:bb.path)
        try Data("PPid:\t41\n".utf8).write(to:status)
        let observation=temp.appendingPathComponent("observation")
        let fragment=String(start[begin..<end]).replacingOccurrences(of:"/run/swifthakchi/trial-manager-observation",with:observation.path)
            .replacingOccurrences(of:#""/proc/$$/status""#,with:"'\(status.path)'")
        func exercise(_ args:String) throws -> (Int32,String) {
            try? FileManager.default.removeItem(at:observation)
            let command="set -eu\nB='\(bb.path)'\nset -- \(args)\n" + fragment + "\nprintf 'FD %s %s %s\\n' \"$waitfd\" \"$startfd\" \"$finishfd\"\n"
            let p=Process(),output=Pipe();p.executableURL=URL(fileURLWithPath:"/bin/sh");p.arguments=["-c",command];p.standardOutput=output;p.standardError=FileHandle.nullDevice
            try p.run();let data=output.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
            return (p.terminationStatus,String(decoding:data,as:UTF8.self))
        }
        let valid=try exercise("--wait-transition-fd 14 --start-transition-fd 15 --finish-transition-fd 16")
        #expect(valid.0==0 && valid.1=="FD 14 15 16\n")
        let missing=try exercise("--wait-transition-fd 14 --start-transition-fd 15")
        #expect(missing.0 != 0)
        let duplicate=try exercise("--wait-transition-fd 14 --wait-transition-fd 15 --start-transition-fd 16 --finish-transition-fd 17")
        #expect(duplicate.0 != 0)
        let shell=Process();shell.executableURL=URL(fileURLWithPath:"/bin/sh");shell.arguments=["-n","-c",start]
        shell.standardError=FileHandle.nullDevice;shell.standardOutput=FileHandle.nullDevice
        try shell.run();shell.waitUntilExit();#expect(shell.terminationStatus==0)
        #expect(throws:(any Error).self) { try SNESRAMMenuResetTrialBuilder.build(source:source,payload:payload,report:report,artwork:art,owner:Data([0])) }
    }
}
