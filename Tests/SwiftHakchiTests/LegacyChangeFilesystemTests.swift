import Foundation
import Testing
@testable import SwiftHakchi

struct LegacyChangeFixture {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    let code = "CLV-H-ABCDE"
    var base: URL { root.appendingPathComponent("games") }
    var live: URL { base.appendingPathComponent("001/" + code) }
    var transactions: URL { root.appendingPathComponent("transactions") }
    var layout: LegacyChangeLayout { LegacyChangeLayout(base: base.path, transactions: transactions.path, active: root.appendingPathComponent("active").path, uiInit: root.appendingPathComponent("ui").path, proc: root.appendingPathComponent("proc").path, path: root.appendingPathComponent("bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin", expectedUIHash: nil, descriptorDirectory: "/dev/fd") }
    init() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: live, withIntermediateDirectories: true)
        try fm.createDirectory(at: base.appendingPathComponent("000"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("active"), withDestinationURL: base.appendingPathComponent("000"))
        try Data([0, 255, 2, 4, 0]).write(to: live.appendingPathComponent("sample.nes"))
        try Data("Name=Sample".utf8).write(to: live.appendingPathComponent("sample.desktop"))
        let boot = root.appendingPathComponent("proc/sys/kernel/random/boot_id")
        try fm.createDirectory(at: boot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("11111111-1111-1111-1111-111111111111\n".utf8).write(to: boot)
        let state = root.appendingPathComponent("running").path
        try Data().write(to: URL(fileURLWithPath: state))
        let scripts = [
            "sha256sum": "#!/bin/sh\nexec /usr/bin/shasum -a 256 \"$@\"\n",
            "stat": "#!/bin/sh\nexec /usr/bin/stat -f %d \"$3\"\n",
            "pidof": "#!/bin/sh\n[ \"$1\" = clover-mcp ] && [ -f '" + state + "' ] && echo 123\n",
            "killall": "#!/bin/sh\nrm -f '" + state + "'\n",
            "sync": "#!/bin/sh\nexit 0\n",
            "sleep": "#!/bin/sh\n/bin/sleep 0.02\n"
        ]
        for (name, body) in scripts { try executable(body, at: root.appendingPathComponent("bin/" + name)) }
        try executable("#!/bin/sh\ntouch '" + state + "'\n", at: root.appendingPathComponent("ui"))
    }
    func executable(_ body: String, at url: URL) throws {
        try Data(body.utf8).write(to: url); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    func run(_ script: String, inheritPipe: Bool = false) throws -> (Int32, String) {
        let file = root.appendingPathComponent(UUID().uuidString + ".sh")
        try Data(script.utf8).write(to: file)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", (inheritPipe ? "exec 11>&1; " : "") + "mkdir -p '" + root.path + "/proc/'$$; printf '1 (sh) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 123 0\\n' > '" + root.path + "/proc/'$$/stat; exec /bin/bash '" + file.path + "'"]
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        try p.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    func target() throws -> LegacyGameTarget {
        let result = try run(LegacyChangeScripts.probe(code: code, layout: layout))
        #expect(result.0 == 0, "\(result.1)")
        return try LegacyChangeScripts.parseProbe(result.1, code: code)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

struct LegacyChangeFilesystemTests {
    @Test func hideAndUndoPreserveROMAndUnrelatedFiles() throws {
        let f = try LegacyChangeFixture(); defer { f.clean() }
        let target = try f.target(); let id = UUID()
        let result = try f.run(LegacyChangeScripts.hide(id: id, target: target, layout: f.layout))
        #expect(result.0 == 0, "\(result.1)")
        #expect(!FileManager.default.fileExists(atPath: f.live.path))
        let preserved = f.transactions.appendingPathComponent(id.uuidString + "/preserved/" + f.code + "/sample.nes")
        #expect(try Data(contentsOf: preserved) == Data([0, 255, 2, 4, 0]))
        let undo = try f.run(LegacyChangeScripts.undo(id: id, target: target, layout: f.layout))
        #expect(undo.0 == 0, "\(undo.1)")
        #expect(try Data(contentsOf: f.live.appendingPathComponent("sample.nes")) == Data([0, 255, 2, 4, 0]))
        #expect(try f.run(LegacyChangeScripts.undo(id: id, target: target, layout: f.layout)).0 == 0)
        #expect(FileManager.default.fileExists(atPath: preserved.path))
    }
    @Test func changedGameCannotBeHidden() throws {
        let f = try LegacyChangeFixture(); defer { f.clean() }; let target = try f.target()
        try Data("changed".utf8).write(to: f.live.appendingPathComponent("sample.nes"))
        #expect(try f.run(LegacyChangeScripts.hide(id: UUID(), target: target, layout: f.layout)).0 != 0)
        #expect(try Data(contentsOf: f.live.appendingPathComponent("sample.nes")) == Data("changed".utf8))
    }
    @Test func linksAndDuplicateEntriesRefusePreview() throws {
        let f = try LegacyChangeFixture(); defer { f.clean() }
        try FileManager.default.createSymbolicLink(at: f.live.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        #expect(try f.run(LegacyChangeScripts.probe(code: f.code, layout: f.layout)).0 != 0)
        try FileManager.default.removeItem(at: f.live.appendingPathComponent("link"))
        try FileManager.default.createDirectory(at: f.base.appendingPathComponent("002/" + f.code), withIntermediateDirectories: true)
        #expect(try f.run(LegacyChangeScripts.probe(code: f.code, layout: f.layout)).0 != 0)
    }
    @Test func unknownLockAndStageFailureLeaveLiveGameIntact() throws {
        let f = try LegacyChangeFixture(); defer { f.clean() }; let target = try f.target()
        try FileManager.default.createDirectory(at: f.transactions.appendingPathComponent("lock"), withIntermediateDirectories: true)
        #expect(try f.run(LegacyChangeScripts.hide(id: UUID(), target: target, layout: f.layout)).0 != 0)
        #expect(FileManager.default.fileExists(atPath: f.live.path))
        try FileManager.default.removeItem(at: f.transactions.appendingPathComponent("lock"))
        try f.executable("#!/bin/sh\nexit 9\n", at: f.root.appendingPathComponent("bin/cp"))
        #expect(try f.run(LegacyChangeScripts.hide(id: UUID(), target: target, layout: f.layout)).0 != 0)
        #expect(FileManager.default.fileExists(atPath: f.live.path))
    }
    @Test func undoDoesNotOverwriteConflictingLiveEntry() throws {
        let f = try LegacyChangeFixture(); defer { f.clean() }; let target = try f.target(); let id = UUID()
        #expect(try f.run(LegacyChangeScripts.hide(id: id, target: target, layout: f.layout)).0 == 0)
        try FileManager.default.createDirectory(at: f.live, withIntermediateDirectories: true)
        try Data("other".utf8).write(to: f.live.appendingPathComponent("other"))
        #expect(try f.run(LegacyChangeScripts.undo(id: id, target: target, layout: f.layout)).0 != 0)
        #expect(try Data(contentsOf: f.live.appendingPathComponent("other")) == Data("other".utf8))
    }
    @Test func crossDeviceAndLiveOwnerRefuseMutation() throws {
        let f = try LegacyChangeFixture(); defer { f.clean() }; let target = try f.target(); let id = UUID()
        try f.executable("#!/bin/sh\ncase \"$3\" in *transactions*) echo 2;; *) echo 1;; esac\n", at: f.root.appendingPathComponent("bin/stat"))
        #expect(try f.run(LegacyChangeScripts.hide(id: id, target: target, layout: f.layout)).0 != 0)
        #expect(FileManager.default.fileExists(atPath: f.live.path))
    }
}

extension LegacyChangeFilesystemTests {
    @Test func recoveringLiveRemoteOwnerRefusesAndExitedOwnerCanRestore() throws {
        let f = try LegacyChangeFixture(); defer { f.clean() }; let target = try f.target(); let id = UUID()
        #expect(try f.run(LegacyChangeScripts.hide(id: id, target: target, layout: f.layout)).0 == 0)
        let lock = f.transactions.appendingPathComponent("lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        let stat = f.root.appendingPathComponent("proc/1234/stat")
        try FileManager.default.createDirectory(at: stat.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("1 (sh) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 123 0\n".utf8).write(to: stat)
        try Data((id.uuidString + "\n1234\n123\n00000000-0000-0000-0000-000000000000\n").utf8).write(to: lock.appendingPathComponent("owner"))
        #expect(try f.run(LegacyChangeScripts.undo(id: id, target: target, layout: f.layout)).0 != 0)
        #expect(!FileManager.default.fileExists(atPath: f.live.path))
        try FileManager.default.removeItem(at: stat)
        #expect(try f.run(LegacyChangeScripts.undo(id: id, target: target, layout: f.layout)).0 == 0)
        #expect(FileManager.default.fileExists(atPath: f.live.path))
    }
    @Test func renameFailureRestartsMenuWithoutDeletingLiveGame() throws {
        let f = try LegacyChangeFixture(); defer { f.clean() }; let target = try f.target()
        try f.executable("#!/bin/sh\nexit 9\n", at: f.root.appendingPathComponent("bin/mv"))
        #expect(try f.run(LegacyChangeScripts.hide(id: UUID(), target: target, layout: f.layout)).0 != 0)
        #expect(FileManager.default.fileExists(atPath: f.live.appendingPathComponent("sample.nes").path))
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("running").path))
    }
    @Test func restartFailureRollsBackRelocation() throws {
        let f = try LegacyChangeFixture(); defer { f.clean() }; let target = try f.target()
        try f.executable("#!/bin/sh\nexit 9\n", at: f.root.appendingPathComponent("ui"))
        #expect(try f.run(LegacyChangeScripts.hide(id: UUID(), target: target, layout: f.layout)).0 != 0)
        #expect(try Data(contentsOf: f.live.appendingPathComponent("sample.nes")) == Data([0, 255, 2, 4, 0]))
    }
    @Test func invalidRecoveryMaterialCannotAuthorizePreparation() throws {
        let f = try LegacyChangeFixture(); defer { f.clean() }
        #expect(throws: (any Error).self) { try LegacyRecoveryEvidence.find(in: f.root) }
        let dir = f.root.appendingPathComponent("RecoveryMaterial-fake")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("ANDROID!fake".utf8).write(to: dir.appendingPathComponent("kernel-stock-NES.img"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("manifest.json"))
        #expect(throws: (any Error).self) { try LegacyRecoveryEvidence.find(in: f.root) }
    }
}

extension LegacyChangeFilesystemTests {
    @Test func mismatchedMarkerCannotReclaimEvenAnExitedOwnersLock() throws {
        let f = try LegacyChangeFixture(); defer { f.clean() }; let target = try f.target(); let id = UUID()
        #expect(try f.run(LegacyChangeScripts.hide(id: id, target: target, layout: f.layout)).0 == 0)
        let lock = f.transactions.appendingPathComponent("lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        let owner = Data((id.uuidString + "\n999999\n123\n00000000-0000-0000-0000-000000000000\n").utf8)
        try owner.write(to: lock.appendingPathComponent("owner"))
        try Data("other".utf8).write(to: f.transactions.appendingPathComponent(id.uuidString + "/marker"))
        #expect(try f.run(LegacyChangeScripts.undo(id: id, target: target, layout: f.layout)).0 != 0)
        #expect(try Data(contentsOf: lock.appendingPathComponent("owner")) == owner)
    }
}

extension LegacyChangeFilesystemTests {
    @Test func demoDoesNotBlockReadOnlyPreviewButStillBlocksEveryWrite() throws {
        let f = try LegacyChangeFixture(); defer { f.clean() }
        try f.executable("#!/bin/sh\necho 123\n", at: f.root.appendingPathComponent("bin/pidof"))
        let target = try f.target()
        #expect(try f.run(LegacyChangeScripts.hide(id: UUID(), target: target, layout: f.layout)).0 != 0)
        #expect(!FileManager.default.fileExists(atPath: f.transactions.path))
        #expect(FileManager.default.fileExists(atPath: f.live.path))
    }
}

extension LegacyChangeFilesystemTests {
    @Test func undoRechecksFilesystemAfterMenuShutdown() throws {
        let f = try LegacyChangeFixture(); defer { f.clean() }; let target = try f.target(); let id = UUID()
        #expect(try f.run(LegacyChangeScripts.hide(id: id, target: target, layout: f.layout)).0 == 0)
        let changed = f.root.appendingPathComponent("changed-device").path
        try f.executable("#!/bin/sh\nrm -f '" + f.root.appendingPathComponent("running").path + "'\ntouch '" + changed + "'\n", at: f.root.appendingPathComponent("bin/killall"))
        try f.executable("#!/bin/sh\nif [ -e '" + changed + "' ]; then case \"$3\" in *games/001) echo 2; exit;; esac; fi; echo 1\n", at: f.root.appendingPathComponent("bin/stat"))
        #expect(try f.run(LegacyChangeScripts.undo(id: id, target: target, layout: f.layout)).0 != 0)
        #expect(!FileManager.default.fileExists(atPath: f.live.path))
    }
    @Test func survivingMutationChildRequiresPowerCycleBeforeRecovery() throws {
        let f = try LegacyChangeFixture(); defer { f.clean() }; let target = try f.target(); let id = UUID()
        #expect(try f.run(LegacyChangeScripts.hide(id: id, target: target, layout: f.layout)).0 == 0)
        #expect(try f.run(LegacyChangeScripts.undo(id: id, target: target, layout: f.layout)).0 == 0)
        let gate = f.root.appendingPathComponent("gate").path
        let done = f.root.appendingPathComponent("child-done").path
        let hidden = f.transactions.appendingPathComponent(id.uuidString + "/hidden/" + f.code).path
        let parent = Process(); parent.executableURL = URL(fileURLWithPath: "/bin/bash")
        parent.arguments = ["-c", "(while [ ! -e '" + gate + "' ]; do /bin/sleep 0.01; done; /bin/mv '" + f.live.path + "' '" + hidden + "'; touch '" + done + "') &"]
        parent.standardOutput = FileHandle.nullDevice; parent.standardError = FileHandle.nullDevice
        try parent.run(); parent.waitUntilExit()
        defer { FileManager.default.createFile(atPath: gate, contents: Data()) }
        let lock = f.transactions.appendingPathComponent("lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        try Data((id.uuidString + "\n" + String(parent.processIdentifier) + "\n123\n11111111-1111-1111-1111-111111111111\n").utf8).write(to: lock.appendingPathComponent("owner"))
        #expect(try f.run(LegacyChangeScripts.undo(id: id, target: target, layout: f.layout)).0 != 0)
        FileManager.default.createFile(atPath: gate, contents: Data())
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: done), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(FileManager.default.fileExists(atPath: hidden))
        let boot = f.root.appendingPathComponent("proc/sys/kernel/random/boot_id")
        try FileManager.default.createDirectory(at: boot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("22222222-2222-2222-2222-222222222222\n".utf8).write(to: boot)
        #expect(try f.run(LegacyChangeScripts.undo(id: id, target: target, layout: f.layout)).0 == 0)
        #expect(FileManager.default.fileExists(atPath: f.live.path))
    }
}

extension LegacyChangeFilesystemTests {
    @Test func nativeMenuPlayerDoesNotCountAsAnEmulator() throws {
        let f = try LegacyChangeFixture(); defer { f.clean() }; let target = try f.target()
        let running = f.root.appendingPathComponent("running").path
        let commandLine = f.root.appendingPathComponent("proc/999/cmdline")
        try FileManager.default.createDirectory(at: commandLine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("ReedPlayer-Clover\0--bootapp=/usr/share/clover-ui\0".utf8).write(to: commandLine)
        try f.executable("#!/bin/sh\ncase \"$*\" in *ReedPlayer-Clover*) [ -f '" + running + "' ] && echo 999; exit $?;; esac\n[ \"$1\" = clover-mcp ] && [ -f '" + running + "' ] && echo 123\n", at: f.root.appendingPathComponent("bin/pidof"))
        let result = try f.run(LegacyChangeScripts.hide(id: UUID(), target: target, layout: f.layout))
        #expect(result.0 == 0, "\(result.1)")
    }
}

extension LegacyChangeFilesystemTests {
    @Test func legacyMenuShutdownNeverSendsThePowerOffSignal() throws {
        let f = try LegacyChangeFixture(); defer { f.clean() }; let target = try f.target()
        let running = f.root.appendingPathComponent("running").path
        try f.executable("#!/bin/sh\n[ \"$1\" = -KILL ] || exit 7\nrm -f '" + running + "'\n", at: f.root.appendingPathComponent("bin/killall"))
        let result = try f.run(LegacyChangeScripts.hide(id: UUID(), target: target, layout: f.layout))
        #expect(result.0 == 0, "\(result.1)")
    }
}


extension LegacyChangeFilesystemTests {
    @Test func restartedMenuCannotInheritUSBCommandPipes() throws {
        let f = try LegacyChangeFixture(); defer { f.clean() }; let target = try f.target()
        let leaked = f.root.appendingPathComponent("leaked-descriptor").path
        let running = f.root.appendingPathComponent("running").path
        try f.executable("#!/bin/sh\n[ ! -e /dev/fd/11 ] || touch '" + leaked + "'\ntouch '" + running + "'\n", at: f.root.appendingPathComponent("ui"))
        #expect(try f.run(LegacyChangeScripts.hide(id: UUID(), target: target, layout: f.layout), inheritPipe: true).0 == 0)
        #expect(!FileManager.default.fileExists(atPath: leaked))
    }
}
