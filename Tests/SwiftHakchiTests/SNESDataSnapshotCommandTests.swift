import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESDataSnapshotCommandTests {
    @Test(arguments: ["none", "linked", "mounted", "size", "dd-error", "short", "helper"])
    func emittedReadRequiresACompleteUnchangedRange(fault: String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let body = Data(repeating: 0xa7, count: 2*1024*1024), id = UUID()
        try (fault == "short" ? Data(body.prefix(1024*1024)) : body).write(to: root.appendingPathComponent("nandc"))
        if fault == "linked" {
            try FileManager.default.moveItem(at: root.appendingPathComponent("nandc"), to: root.appendingPathComponent("actual"))
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("nandc").path, withDestinationPath: "actual")
        }
        try Data((fault == "size" ? "8192\n" : "4096\n").utf8).write(to: root.appendingPathComponent("size"))
        try Data(("rootfs / rootfs rw 0 0\n/dev/mapper/root-crypt /newroot squashfs ro 0 0\n" + (fault == "mounted" ? "/dev/nandc /var/lib ext4 ro 0 0\n" : "")).utf8).write(to: root.appendingPathComponent("mounts"))
        let shim = root.appendingPathComponent("busybox")
        try Data((#"""
        #!/bin/sh
        app="$1"; shift
        case "$app" in
          sha256sum) exec /usr/bin/shasum -a 256 "$@";;
          dd) \#(fault == "dd-error" ? "exit 1" : "exec /bin/dd \"$@\"");;
          cat|awk) exec "$app" "$@";;
          *) exit 55;;
        esac
        """# + "\n").utf8).write(to: shim)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
        let plan = try SNESDataSnapshotPlan(partitionSectors: 4096)
        let command = try SNESDataSnapshotCommands.read(plan: plan, index: 0, challenge: id)
        if fault == "none", let export = ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_DATA_ARM_FIXTURE"] {
            let folder = URL(fileURLWithPath: export)
            try Data(command.utf8).write(to: folder.appendingPathComponent("read.sh"), options: .withoutOverwriting)
            try Data(SNESDataSnapshotCommands.hash(plan: plan, challenge: id).utf8).write(to: folder.appendingPathComponent("hash.sh"), options: .withoutOverwriting)
            try body.write(to: folder.appendingPathComponent("body.bin"), options: .withoutOverwriting)
            try snesDataFrame(body, challenge: id, index: 0).write(to: folder.appendingPathComponent("expected.bin"), options: .withoutOverwriting)
            try Data("SWIFTHAKCHI_SNES_DATA_HASH_V1 \(id.uuidString) \(body.count) \(BackupManifest.digest(body))\n".utf8)
                .write(to: folder.appendingPathComponent("expected-hash.txt"), options: .withoutOverwriting)
        }
        // Only the fixture changes the node type and helper pin. Production uses a block node.
        let script = command.replacingOccurrences(of: "test -b /dev/nandc", with: "test -f /dev/nandc")
            .replacingOccurrences(of: "/dev/nandc", with: "./nandc")
            .replacingOccurrences(of: "/sys/class/block/nandc/size", with: "./size")
            .replacingOccurrences(of: "/proc/mounts", with: "./mounts")
            .replacingOccurrences(of: "B=/bin/busybox", with: "B=" + LaunchCommand.shellQuote(shim.path))
            .replacingOccurrences(of: "test \"${pin%% *}\" = '" + SNESDataSnapshotCommands.busyboxSHA256 + "'", with: fault == "helper" ? "false" : "true")
        let process = Process(), output = Pipe(); process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]; process.currentDirectoryURL = root
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); let raw = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        if fault == "none" {
            #expect(process.terminationStatus == 0)
            #expect(try SNESDataSnapshotChunk(frame: raw, challenge: id, index: 0, count: body.count).bytes == body)
        } else if fault == "short" {
            #expect(throws: (any Error).self) { try SNESDataSnapshotChunk(frame: raw, challenge: id, index: 0, count: body.count) }
        } else { #expect(process.terminationStatus != 0); #expect(raw.isEmpty) }
        #expect(command.contains("of=") == false)
        #expect(command.contains("burn_") == false)
    }
}
