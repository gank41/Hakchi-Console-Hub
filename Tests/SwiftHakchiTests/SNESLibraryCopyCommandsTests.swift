import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESLibraryCopyCommandsTests {
    @MainActor private func fixtureMenu(_ root: URL, romBytes: Int) throws -> (SNESLibraryMenu, SNESOriginalGamesFrame) {
        let fixture = SNESLibraryMaterialTests(), (review, originals) = try fixture.fixture(root, romBytes: romBytes)
        return (try fixture.menu(review, originals), originals)
    }
    @MainActor private func fixtureInventory(raw: Data? = nil, challenge: UUID) throws -> SNESLibraryInventory {
        let source = SNESLibraryInventoryTests()
        if let raw { return try source.parse(raw, challenge: challenge) }
        return try source.parse(source.frame(challenge: challenge), challenge: challenge)
    }
    @Test @MainActor func transportContainsOnlyMissingPayloadsAndPreservesOriginalMenu() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryMaterialTests(), (review, originals) = try fixture.fixture(root), menu = try fixture.menu(review, originals)
        let source = SNESLibraryInventoryTests(), nonce = UUID(), before = try source.parse(source.frame(challenge: nonce), challenge: nonce)
        let request = try SNESLibraryCopyCommands.prepare(menu: menu, before: before, runtimeSHA256: String(repeating: "b", count: 64), challenge: UUID())
        #expect(request.objectNames == Set(menu.objects.keys))
        #expect(request.script.utf8.count < 65536)
        #expect(request.body.count > menu.objects.values.reduce(0) { $0 + $1.count })
        #expect(!request.script.contains("kill ") && !request.script.contains("rm -r"))
        #expect(request.script.contains("SELECTOR_CHANGED=0"))
        #expect(request.script.contains("ibs=1 obs=65536"))
        let stream = try request.stream()
        #expect(stream.command.utf8.count < 1020 && stream.input.count > request.body.count)
        let already = try source.parse(source.frame(challenge: nonce, menu: menu), challenge: nonce)
        let reused = try SNESLibraryCopyCommands.prepare(menu: try fixture.menu(review, originals), before: already,
            runtimeSHA256: String(repeating: "b", count: 64), challenge: UUID())
        #expect(reused.objectNames.isEmpty)
        #expect(reused.body.count < request.body.count)
    }
    @Test(arguments: ["valid", "file-limit", "truncated", "corrupt", "occupied", "linked-parent", "game", "changed-selector", "reused", "conflicting-object"])
    func fixedCopyIsInactiveAndNeverOverwritesForeignFiles(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (menu, originals) = try await fixtureMenu(root, romBytes: fault == "file-limit" ? 524288 : 65536)
        let nonce = UUID(), before = try await fixtureInventory(challenge: nonce)
        let challenge = UUID(), runtimeHash = String(repeating: "b", count: 64)
        let request = try SNESLibraryCopyCommands.prepare(menu: menu, before: before, runtimeSHA256: runtimeHash, challenge: challenge)
        let data = root.appendingPathComponent("data"), runtime = root.appendingPathComponent("runtime")
        for dir in [data, runtime, data.appendingPathComponent("clover")] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let namespace = data.appendingPathComponent("swifthakchi/snes-v2"), target = namespace.appendingPathComponent("menus/" + menu.id.uuidString)
        let sentinel = Data("original stays".utf8); try sentinel.write(to: data.appendingPathComponent("clover/settings.json"))
        let pin = try makeRuntime(root: root, data: data, runtime: runtime, fault: fault)
        if fault == "occupied" { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true); try sentinel.write(to: target.appendingPathComponent("foreign")) }
        if fault == "changed-selector" {
            let legacy = data.appendingPathComponent("swifthakchi/snes-v1")
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            try sentinel.write(to: legacy.appendingPathComponent("active-menu"))
        }
        if fault == "linked-parent" {
            try FileManager.default.createSymbolicLink(at: data.appendingPathComponent("swifthakchi"), withDestinationURL: runtime)
        }
        if fault == "conflicting-object" || fault == "reused" {
            try FileManager.default.createDirectory(at: namespace.appendingPathComponent("objects"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: namespace.appendingPathComponent("menus"), withIntermediateDirectories: true)
            for (name, bytes) in menu.objects { try (fault == "reused" ? bytes : sentinel).write(to: namespace.appendingPathComponent("objects/" + name)) }
        }
        let effective: SNESLibraryCopyCommands.Request
        if fault == "reused" {
            let raw = String(decoding: before.rawFrame, as: UTF8.self).replacingOccurrences(of: "NAMESPACE absent absent", with: "NAMESPACE ready absent")
                .replacingOccurrences(of: "END\n", with: menu.objectRecords.map { "OBJECT \($0.name) \($0.byteCount) \($0.sha256)\n" }.joined() + "END\n")
            let seen = try await fixtureInventory(raw: Data(raw.utf8), challenge: nonce)
            effective = try SNESLibraryCopyCommands.prepare(menu: menu, before: seen, runtimeSHA256: runtimeHash, challenge: challenge)
        } else { effective = request }
        let script = effective.script.replacingOccurrences(of: "stat -L -c '%s' \"/proc/$$/fd/7\"", with: "stat -c '%s' \"$stage/.upload\"").replacingOccurrences(of: "/mnt/swifthakchi", with: runtime.path)
            .replacingOccurrences(of: "/var/lib", with: data.path).replacingOccurrences(of: "/etc/clover", with: root.path)
            .replacingOccurrences(of: "/proc/mounts", with: root.appendingPathComponent("mounts").path)
            .replacingOccurrences(of: "440b72b46c50939356768f35ea02b682176ca49ef07b3702ee75912af74aabd6", with: pin)
            .replacingOccurrences(of: runtimeHash, with: BackupManifest.digest(try Data(contentsOf: runtime.appendingPathComponent("runtime-files.sha256"))))
        var body = effective.body
        if fault == "truncated" { body = body.prefix(body.count / 2) }
        if fault == "corrupt" { body[body.count / 2] ^= 1 }
        let input = root.appendingPathComponent("input"); try body.write(to: input)
        let command = root.appendingPathComponent("copy.sh"); try Data(script.utf8).write(to: command)
        if let export = ProcessInfo.processInfo.environment[fault == "file-limit" ? "SWIFTHAKCHI_SNES_COPY_LIMIT_ARM_EXPORT" : "SWIFTHAKCHI_SNES_COPY_ARM_EXPORT"], ["valid", "file-limit"].contains(fault) {
            let target = URL(fileURLWithPath: export); try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data(effective.script.utf8).write(to: target.appendingPathComponent("copy.sh")); try effective.body.write(to: target.appendingPathComponent("body.bin"))
            try Data(SNESLibraryStartupScripts.verifier.utf8).write(to: target.appendingPathComponent("library-selector"))
            try JSONSerialization.data(withJSONObject: ["id": menu.id.uuidString, "challenge": challenge.uuidString, "context": before.contextSHA256,
                "hwid": before.hwid, "runtime": runtimeHash, "wire": BackupManifest.digest(try SNESLibraryStartupScripts.manifest(for: menu)),
                "description": BackupManifest.digest(menu.manifest), "objectNames": menu.objects.keys.sorted(), "stock": Dictionary(uniqueKeysWithValues: originals.entries.flatMap { entry in
                    entry.files.filter { $0.name.hasSuffix(".desktop") }.map { (entry.code + "/" + $0.name, $0.data.base64EncodedString()) }
                })], options: [.sortedKeys]).write(to: target.appendingPathComponent("fixture.json"))
        }
        let process = Process(), out = Pipe(), err = Pipe(), handle = try FileHandle(forReadingFrom: input)
        defer { try? handle.close() }
        if fault == "file-limit" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", "import resource,subprocess,sys; resource.setrlimit(resource.RLIMIT_FSIZE,(524288,resource.getrlimit(resource.RLIMIT_FSIZE)[1])); r=subprocess.run(['/bin/sh',sys.argv[1]]); assert resource.getrlimit(resource.RLIMIT_FSIZE)[0]==524288; sys.exit(r.returncode)", command.path]
            #expect(menu.objectRecords.contains { $0.name.hasSuffix(".sfrom") && $0.byteCount == 524384 })
        } else { process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [command.path] }
        process.standardInput = handle; process.standardOutput = out; process.standardError = err
        let started = Date()
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: deadline)
        defer { deadline.cancel() }
        let reply = out.fileHandleForReading.readDataToEndOfFile(), errors = err.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        #expect(Date().timeIntervalSince(started) < 29, "The synthetic copy reader did not stop promptly.")
        #expect(try Data(contentsOf: data.appendingPathComponent("clover/settings.json")) == sentinel)
        #expect(!FileManager.default.fileExists(atPath: namespace.appendingPathComponent("active-menu").path))
        if ["valid", "file-limit", "reused"].contains(fault) {
            #expect(process.terminationStatus == 0, "\(String(decoding: errors, as: UTF8.self))")
            let receipt = try SNESLibraryCopyReceipt(reply, request: effective)
            #expect(receipt.id == menu.id && receipt.freeBytes > 0)
            #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent(".upload").path))
            for record in menu.objectRecords { #expect(BackupManifest.digest(try Data(contentsOf: namespace.appendingPathComponent("objects/" + record.name))) == record.sha256) }
            #expect(try Data(contentsOf: target.appendingPathComponent("menu.manifest")) == SNESLibraryStartupScripts.manifest(for: menu))
            #expect(try Data(contentsOf: namespace.appendingPathComponent("descriptions/" + menu.id.uuidString + ".json")) == menu.manifest)
            var damaged = reply; damaged.append(10)
            #expect(throws: (any Error).self) { try SNESLibraryCopyReceipt(damaged, request: effective) }
        } else {
            #expect(process.terminationStatus != 0)
            #expect(throws: (any Error).self) { try SNESLibraryCopyReceipt(reply, request: effective) }
            if fault == "occupied" { #expect(try Data(contentsOf: target.appendingPathComponent("foreign")) == sentinel) }
            if fault == "conflicting-object" { for name in menu.objects.keys { #expect(try Data(contentsOf: namespace.appendingPathComponent("objects/" + name)) == sentinel) } }
        }
    }
    func makeRuntime(root: URL, data: URL, runtime: URL, fault: String) throws -> String {
        let shim = """
        #!/bin/sh
        case "$1" in
          stat)
            if test "$2" = -f; then printf '4096 76800 64000\\n'; exit; fi
            case "$3" in
              %u) printf '0\\n';;
              %h) exec /usr/bin/stat -f '%l' "$4";;
              %d) exec /usr/bin/stat -f '%d' "$4";;
              %s) exec /usr/bin/stat -f '%z' "$4";;
              '%d %i %a') exec /usr/bin/stat -f '%d %i %Lp' "$4";;
              '%d %i %Y %Z %a %s') exec /usr/bin/stat -f '%d %i %m %c %Lp %z' "$4";;
              *) exit 96;;
            esac;;
          sha256sum) shift; exec /usr/bin/shasum -a 256 "$@";;
          uname) printf '3.4.113\\n';;
          pidof) if test "$2" = clover-mcp; then printf '101\\n'; elif test '\(fault)' = game; then printf '102\\n'; else exit 1; fi;;
          readlink) if test "$3" = /proc/101/exe; then printf '/usr/bin/clover-mcp\\n'; else shift; exec /usr/bin/readlink "$@"; fi;;
          devmem) printf '0x11111111\\n';;
          dd) shift; exec /bin/dd "$@";;
          *) command=$1; shift; exec "$command" "$@";;
        esac
        """
        let busybox = runtime.appendingPathComponent("busybox"), pin = BackupManifest.digest(Data(shim.utf8))
        try Data(shim.utf8).write(to: busybox); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: busybox.path)
        try Data((pin + "  " + busybox.path + "\n").utf8).write(to: runtime.appendingPathComponent("runtime-files.sha256"))
        try Data("dp-shvc\n".utf8).write(to: root.appendingPathComponent("boardtype")); try Data("USA\n".utf8).write(to: root.appendingPathComponent("REGION"))
        try Data(("/dev/mapper/root-crypt / squashfs ro 0 0\n/dev/nandc " + data.path + " ext4 rw 0 0\n").utf8).write(to: root.appendingPathComponent("mounts"))
        // The production ARM verifier is exercised separately; host tests isolate the copy framing and filesystem behavior.
        try Data(("printf '%s\\n' '" + data.path + "/swifthakchi/snes-v2/menus/'\"$1\"'/pages/000'\n").utf8).write(to: runtime.appendingPathComponent("library-selector"))
        return pin
    }
}
