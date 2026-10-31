import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryInventoryCommandTests {
    @Test(arguments: ["valid", "link", "hardlink", "game", "partial", "partial-normal", "partial-base", "partial-base-strict"])
    func fixedCommandReadsDataAndRejectsUnsafeFilesWithoutChangingThem(_ fault: String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data"), runtime = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: data.appendingPathComponent("clover"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false)
        let profile = data.appendingPathComponent("clover/settings.json"), outside = root.appendingPathComponent("outside")
        let bytes = Data("{\"language\":\"en\"}".utf8); try bytes.write(to: outside)
        if fault == "link" { try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: outside) }
        else if fault == "hardlink" { try FileManager.default.linkItem(at: outside, to: profile) }
        else { try bytes.write(to: profile) }
        let busybox = runtime.appendingPathComponent("busybox")
        let shim = """
        #!/bin/sh
        case "$1" in
          stat)
            if test "$2" = -L; then shift; fi
            if test "$2" = -f; then printf '4096 76800 64000\\n'; exit; fi
            case "$3" in
              %u) printf '0\\n';;
              %h) exec /usr/bin/stat -f '%l' "$4";;
              %d) exec /usr/bin/stat -f '%d' "$4";;
              %s) exec /usr/bin/stat -f '%z' "$4";;
              '%d %i %Y %Z %a %s') exec /usr/bin/stat -f '%d %i %m %c %Lp %z' "$4";;
              *) exit 96;;
            esac;;
          sha256sum) shift; exec /usr/bin/shasum -a 256 "$@";;
          uname) printf '3.4.113\\n';;
          pidof) if test "$2" = clover-mcp; then printf '101\\n'; elif test '\(fault)' = game; then printf '102\\n'; else exit 1; fi;;
          readlink) if test "$3" = /proc/101/exe; then printf '/usr/bin/clover-mcp\\n'; else shift; exec /usr/bin/readlink "$@"; fi;;
          devmem) printf '0x11111111\\n';;
          *) command=$1; shift; exec "$command" "$@";;
        esac
        """
        try Data(shim.utf8).write(to: busybox); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: busybox.path)
        let pin = BackupManifest.digest(Data(shim.utf8)), checks = Data((pin + "  " + busybox.path + "\n").utf8)
        try checks.write(to: runtime.appendingPathComponent("runtime-files.sha256"))
        try Data("dp-shvc\n".utf8).write(to: root.appendingPathComponent("boardtype")); try Data("USA\n".utf8).write(to: root.appendingPathComponent("REGION"))
        let mounts = root.appendingPathComponent("mounts")
        try Data(("/dev/mapper/root-crypt / squashfs ro 0 0\n/dev/nandc " + data.path + " ext4 rw 0 0\n").utf8).write(to: mounts)
        let fixture = SNESLibraryInventoryTests(), challenge = UUID(), incompleteID = UUID()
        if fault.hasPrefix("partial") {
            let namespace = data.appendingPathComponent("swifthakchi/snes-v2")
            let leaves = fault.hasPrefix("partial-base") ? ["objects"] : ["objects", "menus", "descriptions", "menus/" + incompleteID.uuidString]
            for leaf in leaves {
                try FileManager.default.createDirectory(at: namespace.appendingPathComponent(leaf), withIntermediateDirectories: true)
            }
            if !fault.hasPrefix("partial-base") { try Data([1,2,3]).write(to: namespace.appendingPathComponent("menus/" + incompleteID.uuidString + "/.upload")) }
        }
        let source = try SNESLibraryInventoryCommands.script(contextSHA256: fixture.context, hwid: fixture.hwid,
            catalogSHA256: fixture.catalog, runtimeSHA256: BackupManifest.digest(checks), librarySupport: fault.hasPrefix("partial"), challenge: challenge,
            excludingIncompleteMenu: ["partial", "partial-base", "partial-base-strict"].contains(fault) ? incompleteID : nil,
            allowIncompleteNamespace: fault == "partial-base")
        if let export = ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_INVENTORY_ARM_EXPORT"], fault == "valid" {
            let target = URL(fileURLWithPath: export)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data(source.utf8).write(to: target.appendingPathComponent("inventory.sh"))
            try JSONSerialization.data(withJSONObject: ["challenge": challenge.uuidString, "context": fixture.context,
                "hwid": fixture.hwid, "catalog": fixture.catalog], options: [.sortedKeys]).write(to: target.appendingPathComponent("fixture.json"))
        }
        if let export = ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_INVENTORY_ARM_EXPORT"], fault == "partial" {
            try Data(source.utf8).write(to: URL(fileURLWithPath: export).appendingPathComponent("recovery-inventory.sh"))
            try Data(incompleteID.uuidString.utf8).write(to: URL(fileURLWithPath: export).appendingPathComponent("recovery-id.txt"))
        }
        if let export = ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_INVENTORY_ARM_EXPORT"], fault.hasPrefix("partial-base") {
            let target = URL(fileURLWithPath: export)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data(source.utf8).write(to: target.appendingPathComponent(fault + "-inventory.sh"))
        }
        let script = source.replacingOccurrences(of: "/mnt/swifthakchi", with: runtime.path)
            .replacingOccurrences(of: "/var/lib", with: data.path).replacingOccurrences(of: "/etc/clover", with: root.path)
            .replacingOccurrences(of: "/proc/mounts", with: mounts.path)
            .replacingOccurrences(of: "440b72b46c50939356768f35ea02b682176ca49ef07b3702ee75912af74aabd6", with: pin)
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", script]
        process.standardOutput = output; process.standardError = errors
        try process.run(); let raw = output.fileHandleForReading.readDataToEndOfFile(), stderr = errors.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        #expect(try Data(contentsOf: outside) == bytes)
        if ["valid", "partial", "partial-base"].contains(fault) {
            #expect(process.terminationStatus == 0, "\(String(decoding: stderr, as: UTF8.self))")
            let inventory = try SNESLibraryInventory(raw: raw, challenge: challenge, contextSHA256: fixture.context, hwid: fixture.hwid,
                catalogSHA256: fixture.catalog, excludingIncompleteMenu: ["partial", "partial-base"].contains(fault) ? incompleteID : nil)
            #expect(inventory.excludedMenuID == (["partial", "partial-base"].contains(fault) ? incompleteID : nil))
            #expect(inventory.incompleteNamespace == (fault == "partial-base"))
            #expect(inventory.files.count == 1 && inventory.files[0].sha256 == BackupManifest.digest(bytes))
            #expect(inventory.files[0].identity.inode > 0 && inventory.capacity.freeBytes == 64000 * 4096)
            let file = inventory.files[0], chunkID = UUID()
            let chunkSource = try SNESLibraryBackupCommands.script(contextSHA256: fixture.context, hwid: fixture.hwid,
                runtimeSHA256: BackupManifest.digest(checks), file: file, offset: 0, challenge: chunkID)
            if let export = ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_INVENTORY_ARM_EXPORT"] {
                try Data(chunkSource.utf8).write(to: URL(fileURLWithPath: export).appendingPathComponent("chunk.sh"))
            }
            // macOS fdesc reports read-only descriptor permissions/device IDs; real Linux fd semantics are tested in the pinned ARM guest.
            let command = chunkSource.replacingOccurrences(of: "/mnt/swifthakchi", with: runtime.path)
                .replacingOccurrences(of: "/var/lib", with: data.path).replacingOccurrences(of: "/etc/clover", with: root.path)
                .replacingOccurrences(of: "/proc/mounts", with: mounts.path).replacingOccurrences(of: "/proc/$$/fd/7", with: profile.path)
                .replacingOccurrences(of: "440b72b46c50939356768f35ea02b682176ca49ef07b3702ee75912af74aabd6", with: pin)
            func readChunk() throws -> (Int32, Data) {
                let process = Process(), out = Pipe(), error = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", command]
                process.standardOutput = out; process.standardError = error
                try process.run(); let raw = out.fileHandleForReading.readDataToEndOfFile(); let stderr = error.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                if process.terminationStatus != 0 { #expect(!stderr.isEmpty || raw.isEmpty) }
                return (process.terminationStatus, raw)
            }
            let result = try readChunk()
            #expect(result.0 == 0)
            #expect(try SNESLibraryBackupChunk(raw: result.1, file: file, offset: 0, challenge: chunkID, contextSHA256: fixture.context).bytes == bytes)
            try FileManager.default.removeItem(at: profile); try bytes.write(to: profile)
            #expect(try readChunk().0 != 0)

        } else {
            if process.terminationStatus == 0 { #expect(throws: (any Error).self) { try fixture.parse(raw, challenge: challenge) } }
            if fault == "game" || fault == "partial-normal" { #expect(process.terminationStatus != 0) }
        }
    }
    @Test func catalogContentIdentitySurvivesARecaptureButChangesWithOriginalContent() throws {
        let a = UUID(), b = UUID(), binding = originalGamesBinding()
        let first = try SNESOriginalGamesFrame(originalGamesFrameFixture(challenge: a), binding: binding, challenge: a)
        let secondRaw = originalGamesFrameFixture(challenge: b)
        let second = try SNESOriginalGamesFrame(secondRaw, binding: binding, challenge: b)
        #expect(first.raw != second.raw)
        #expect(try SNESLibraryCatalogIdentity.digest(first) == SNESLibraryCatalogIdentity.digest(second))
        var changedRaw = secondRaw
        let range = try #require(changedRaw.range(of: Data(String(repeating: "c", count: 64).utf8)))
        changedRaw.replaceSubrange(range, with: Data(String(repeating: "d", count: 64).utf8))
        let changed = try SNESOriginalGamesFrame(changedRaw, binding: binding, challenge: b)
        #expect(try SNESLibraryCatalogIdentity.digest(first) != SNESLibraryCatalogIdentity.digest(changed))
    }
    @Test func freshSpaceReplyCannotBeReusedForAnotherConsoleOrGeometry() throws {
        let fixture = SNESLibraryInventoryTests(), first = UUID(), second = UUID()
        let inventory = try fixture.parse(fixture.frame(challenge: first), challenge: first)
        let raw = Data("SWIFTHAKCHI_SNES_SPACE_V1 \(second.uuidString)\nCONTEXT=\(fixture.context)\nHWID=\(fixture.hwid)\nSPACE=4096 76800 0\nEND\n".utf8)
        let measured = Date(), space = try SNESLibrarySpace(raw, challenge: second, contextSHA256: fixture.context, hwid: fixture.hwid, measuredAt: measured)
        let live = try space.capacity(for: inventory)
        #expect(live.freeBytes == 0 && live.measuredAt == measured && inventory.capacity.freeBytes > 0)
        #expect(throws: (any Error).self) { try SNESLibrarySpace(raw, challenge: first, contextSHA256: fixture.context, hwid: fixture.hwid) }
        #expect(throws: (any Error).self) { try SNESLibrarySpace(raw, challenge: second, contextSHA256: fixture.context, hwid: String(repeating: "2", count: 32)) }
        let changed = Data(String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "4096 76800", with: "2048 76800").utf8)
        let other = try SNESLibrarySpace(changed, challenge: second, contextSHA256: fixture.context, hwid: fixture.hwid)
        #expect(throws: (any Error).self) { try other.capacity(for: inventory) }
    }
}
