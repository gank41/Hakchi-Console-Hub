import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESStartupPreflightCommandTests {
    @Test(arguments:["none","existing","low-memory","tmp-mount","linked-file","hardlinked-file","short-image","image-hash","operation"])
    func RAMStagingRefusesForeignOrIncompleteFiles(_ fault:String) throws {
        let root=try testDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let temp=root.appendingPathComponent("tmp");try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:false)
        let helper=root.appendingPathComponent("busybox")
        let shim="""
        #!/bin/sh
        if test "$1" = stat; then
          case "$3" in
            %u) printf '0\\n';;
            %a) /usr/bin/stat -f '%Lp' "$4";;
            %h) /usr/bin/stat -f '%l' "$4";;
            %s) /usr/bin/stat -f '%z' "$4";;
            *) exit 30;;
          esac
        else exec "$@"; fi
        """
        try Data(shim.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        let mounts=root.appendingPathComponent("mounts"),meminfo=root.appendingPathComponent("meminfo")
        try Data(("rootfs / rootfs rw 0 0\n"+(fault=="tmp-mount" ? "tmpfs \(temp.path) tmpfs rw 0 0\n":"")).utf8).write(to:mounts)
        try Data("MemFree: \(fault=="low-memory" ? "1":"100000") kB\n".utf8).write(to:meminfo)
        let id=UUID(uuidString:"11111111-1111-1111-1111-111111111111")!,image=Data(repeating:0x61,count:4096),stock=Data(repeating:0x62,count:2736128)
        let directory=temp.appendingPathComponent("swifthakchi-snes-startup-"+id.uuidString)
        func run(_ raw:String) throws -> (Int32,Data) {
            var text=raw.replacingOccurrences(of:"/bin/busybox",with:helper.path).replacingOccurrences(of:SNESDataSnapshotCommands.busyboxSHA256,with:BackupManifest.digest(Data(shim.utf8)))
            text=text.replacingOccurrences(of:"/proc/mounts",with:mounts.path).replacingOccurrences(of:"/proc/meminfo",with:meminfo.path)
            text=text.replacingOccurrences(of:"/tmp",with:temp.path)
            let path=root.appendingPathComponent(UUID().uuidString+".sh");try Data(text.utf8).write(to:path)
            let out=root.appendingPathComponent(UUID().uuidString+".out");FileManager.default.createFile(atPath:out.path,contents:nil)
            let handle=try FileHandle(forWritingTo:out);defer {try? handle.close()}
            let p=Process();p.executableURL=URL(fileURLWithPath:"/bin/sh");p.arguments=[path.path];p.standardOutput=handle;p.standardError=FileHandle.nullDevice
            try p.run();p.waitUntilExit();return (p.terminationStatus,try Data(contentsOf:out))
        }
        if fault=="existing" { try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false) }
        let made=try run(SNESStartupPreflightCommands.create(id:id,imageBytes:image.count,stockBytes:stock.count))
        if ["existing","low-memory","tmp-mount"].contains(fault) { #expect(made.0 != 0 && made.1.isEmpty);return }
        #expect(made.0==0 && made.1==Data(SNESStartupPreflightCommands.created(id).utf8))
        let imageURL=directory.appendingPathComponent("startup.img"),stockURL=directory.appendingPathComponent("stock.img")
        try image.write(to:imageURL);try stock.write(to:stockURL)
        if fault=="linked-file" {
            let actual=directory.appendingPathComponent("source");try FileManager.default.moveItem(at:imageURL,to:actual)
            try FileManager.default.createSymbolicLink(at:imageURL,withDestinationURL:actual)
        }
        if fault=="hardlinked-file" { try FileManager.default.linkItem(at:imageURL,to:directory.appendingPathComponent("image-link")) }
        if fault=="short-image" { try image.dropLast().write(to:imageURL) }
        if fault=="image-hash" { try Data(repeating:0x63,count:image.count).write(to:imageURL) }
        if fault=="operation" { try Data((UUID().uuidString+"\n").utf8).write(to:directory.appendingPathComponent("operation")) }
        let checked=try run(SNESStartupPreflightCommands.check(id:id,imageBytes:image.count,stockBytes:stock.count,imageSHA:BackupManifest.digest(image),stockSHA:BackupManifest.digest(stock)))
        #expect((checked.0==0)==(fault=="none"))
        #expect(checked.1==(fault=="none" ? Data(SNESStartupPreflightCommands.staged(id,imageSHA:BackupManifest.digest(image),stockSHA:BackupManifest.digest(stock)).utf8):Data()))
        #expect(try Data(contentsOf:stockURL)==stock)
        if fault=="none",let export=ProcessInfo.processInfo.environment["SWIFTHAKCHI_PREFLIGHT_ARM_EXPORT"] {
            let destination=URL(fileURLWithPath:export)
            let files:[String:Data]=[
                "create.sh":Data(try SNESStartupPreflightCommands.create(id:id,imageBytes:image.count,stockBytes:stock.count).utf8),
                "check.sh":Data(try SNESStartupPreflightCommands.check(id:id,imageBytes:image.count,stockBytes:stock.count,imageSHA:BackupManifest.digest(image),stockSHA:BackupManifest.digest(stock)).utf8),
                "startup.bin":image,"stock.bin":stock,
                "created.txt":Data(SNESStartupPreflightCommands.created(id).utf8),
                "checked.txt":Data(SNESStartupPreflightCommands.staged(id,imageSHA:BackupManifest.digest(image),stockSHA:BackupManifest.digest(stock)).utf8)]
            for (name,bytes) in files {try bytes.write(to:destination.appendingPathComponent(name),options:.withoutOverwriting)}
        }

    }
}
