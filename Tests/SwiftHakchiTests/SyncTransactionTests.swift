import Foundation
import Testing
@testable import SwiftHakchi
@testable import SwiftHakchiCore

actor TransactionShell: ConsoleShell {
    var files: [String: Data] = ["/var/lib/hakchi/games/nes-usa/.storage/CLV-H-OLDXX/game.nes": Data("old".utf8)]
    var identity = "ABC123"
    var failOnce: String?
    var mounted = true
    var uiRunning = true
    var activePage = "/var/lib/hakchi/games/nes-usa/001"
    var menuState: Data? = Data("001\n".utf8)
    var commands: [String] = []
    func setMenuState(_ bytes: Data?) { menuState = bytes }
    func fail(_ prefix: String) { failOnce = prefix }
    func changeIdentity() { identity = "OTHER" }
    func setIdentity(_ value: String) { identity = value }
    func put(_ path: String, _ bytes: String) { files[path] = Data(bytes.utf8) }
    func data(_ path: String) -> Data? { files[path] }
    func exists(_ path: String) -> Bool { files.keys.contains { $0 == path || $0.hasPrefix(path + "/") } }
    func execute(_ command: String, timeout: Int) async throws -> SSHResult {
        commands.append(command)
        if let prefix = failOnce, command.hasPrefix(prefix) {
            failOnce = nil
            return result(exit: 3, stderr: "injected failure")
        }
        if command.contains("hakchi eval"), command.contains("modname") { return result("/var/saves/hakchi/menu") }
        if command == "cat '/var/saves/hakchi/menu'" { return SSHResult(stdout: String(decoding: menuState ?? Data(), as: UTF8.self), stderr: "", stdoutData: menuState ?? Data(), exitCode: menuState == nil ? 1 : 0) }
        if command == "test -f '/var/saves/hakchi/menu'" { return result(exit: menuState == nil ? 1 : 0) }
        if command == DeviceInventoryService.Command.identity { return result(identity) }
        if command == DeviceInventoryService.Command.system { return result("clv-nes") }
        if command == DeviceInventoryService.Command.activePage { return result(activePage) }
        if command == DeviceInventoryService.Command.capacity { return result("/dev/nandc 400000 10000 390000 5% /var/lib") }
        if command == DeviceInventoryService.Command.version { return result("1.0.3 3.4.113 1.0.4.124") }
        if command.hasPrefix("find ") {
            let codes = Set(files.keys.filter { $0.hasPrefix("/var/lib/hakchi/games/nes-usa/.storage/") }.compactMap { $0.split(separator: "/").dropFirst(6).first.map(String.init) })
            return result(codes.sorted().joined(separator: "\n"))
        }
        if command.hasPrefix("cd "), command.contains("sha256sum -c .sync-checksums") { return result() }
        if command.hasPrefix("grep ") { return result(exit: mounted ? 0 : 1) }
        let args = try LaunchCommand.arguments(in: command)
        switch args.first {
        case "test": return result(exit: exists(args.last ?? "") ? 0 : 1)
        case "mv":
            let from = args[1], to = args[2]
            guard exists(from), !exists(to) else { return result(exit: 2) }
            if to == "/var/saves/hakchi/menu" { menuState = files.removeValue(forKey: from); return result() }
            let moved = files.filter { $0.key == from || $0.key.hasPrefix(from + "/") }
            for (key, value) in moved { files.removeValue(forKey: key); files[to + key.dropFirst(from.count)] = value }
        case "rm":
            for path in args.dropFirst().filter({ !$0.hasPrefix("-") }) {
                if path == "/var/saves/hakchi/menu" { menuState = nil }
                for key in Array(files.keys) where key == path || key.hasPrefix(path + "/") { files.removeValue(forKey: key) }
            }
        case "uistop": uiRunning = false
        case "uistart": uiRunning = true
        case "umount": mounted = false
        case "mount": mounted = true
        case "ln": activePage = args[2]
        default: break
        }
        return result()
    }
    private func result(_ text: String = "", exit: Int = 0, stderr: String = "") -> SSHResult {
        SSHResult(stdout: text, stderr: stderr, stdoutData: Data(text.utf8), exitCode: exit)
    }
    func upload(data: Data, to remotePath: String, timeout: Int) async throws { files[remotePath] = data }
    func uploadTar(data: Data, to directory: String, extraArgs: String, timeout: Int) async throws { throw SSHError.transferFailed("Not needed by transaction tests") }
}

struct SyncTransactionTests {
    private func context() async throws -> (TransactionShell, DeviceInventory, SyncPlan, VerifiedConsoleBackup, URL) {
        let shell = TransactionShell()
        let inventory = try await DeviceInventoryService.inspect(shell: shell)
        let plan = try SyncPlanner.makePlan(inputs: [], installedCodes: inventory.installedCodes, profile: inventory.profile, freeBytes: inventory.freeBytes, reserveBytes: 10_000_000)
        let directory = try testDirectory()
        var tar = TarWriter(); tar.addFile(name: "old.nes", contents: Data("old".utf8)); let archive = tar.finalize()
        try archive.write(to: directory.appendingPathComponent("console.tar"))
        let manifest = BackupManifest(profile: inventory.profile, sourcePaths: [inventory.syncBase!], archiveFilename: "console.tar", data: archive)
        return (shell, inventory, plan, VerifiedConsoleBackup(manifest: manifest, directory: directory), directory)
    }
    @Test func failedStagingLeavesInstalledLibraryUntouched() async throws {
        let (shell, inventory, plan, backup, directory) = try await context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = SyncTransactionService()
        await #expect(throws: (any Error).self) {
            try await service.run(plan: plan, inventory: inventory, shell: shell, backup: backup, journalDirectory: directory, prepare: { _ in throw SSHError.transferFailed("upload failed") })
        }
        #expect(await shell.data("/var/lib/hakchi/games/nes-usa/.storage/CLV-H-OLDXX/game.nes") == Data("old".utf8))
        #expect(await shell.uiRunning)
    }
    @Test func mountFailureRestoresOldLibraryAndUI() async throws {
        let (shell, inventory, plan, backup, directory) = try await context()
        defer { try? FileManager.default.removeItem(at: directory) }
        await shell.fail("mount ")
        let service = SyncTransactionService()
        await #expect(throws: (any Error).self) {
            try await service.run(plan: plan, inventory: inventory, shell: shell, backup: backup, journalDirectory: directory, prepare: { stage in
                await shell.put(stage + "/000/marker", "new")
            })
        }
        #expect(await shell.data("/var/lib/hakchi/games/nes-usa/.storage/CLV-H-OLDXX/game.nes") == Data("old".utf8))
        #expect(await shell.uiRunning)
        #expect(await shell.mounted)
        #expect(await shell.menuState == Data("001\n".utf8))
    }
    @Test func identityChangeBlocksActivation() async throws {
        let (shell, inventory, plan, backup, directory) = try await context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = SyncTransactionService()
        await #expect(throws: (any Error).self) {
            try await service.run(plan: plan, inventory: inventory, shell: shell, backup: backup, journalDirectory: directory, prepare: { stage in
                await shell.put(stage + "/000/marker", "new")
                await shell.changeIdentity()
            })
        }
        #expect(await shell.data("/var/lib/hakchi/games/nes-usa/.storage/CLV-H-OLDXX/game.nes") == Data("old".utf8))
    }
    @Test func successReplacesOnlyAfterStagingAndVerification() async throws {
        let (shell, inventory, plan, backup, directory) = try await context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = SyncTransactionService()
        try await service.run(plan: plan, inventory: inventory, shell: shell, backup: backup, journalDirectory: directory, prepare: { stage in
            #expect(await shell.data("/var/lib/hakchi/games/nes-usa/.storage/CLV-H-OLDXX/game.nes") == Data("old".utf8))
            await shell.put(stage + "/000/marker", "new")
        })
        #expect(await shell.data("/var/lib/hakchi/games/nes-usa/000/marker") == Data("new".utf8))
        // Bundled chmenu refuses a target matching the saved marker; the next page must be reachable.
        #expect(await shell.menuState == Data("000\n".utf8))
        #expect(await shell.menuState != Data("001\n".utf8))
        #expect(await shell.uiRunning)
    }
    @Test(arguments: ["uistop", "mv '/var/lib/hakchi/games/nes-usa'", "mv '/var/lib/hakchi/games/nes-usa.stage-", "ln -sfn", "uistart"])
    func activationFailuresRestoreOriginalLibrary(command: String) async throws {
        let (shell, inventory, plan, backup, directory) = try await context()
        defer { try? FileManager.default.removeItem(at: directory) }
        await shell.fail(command)
        let service = SyncTransactionService()
        await #expect(throws: (any Error).self) {
            try await service.run(plan: plan, inventory: inventory, shell: shell, backup: backup, journalDirectory: directory, prepare: { stage in
                await shell.put(stage + "/000/marker", "new")
            })
        }
        #expect(await shell.data("/var/lib/hakchi/games/nes-usa/.storage/CLV-H-OLDXX/game.nes") == Data("old".utf8))
        #expect(await shell.uiRunning)
        #expect(try SyncTransactionService.pendingJournals(in: directory, profile: inventory.profile).isEmpty)
    }
    @Test func cancellationBeforeCommitDoesNotStopConsoleUI() async throws {
        let (shell, inventory, plan, backup, directory) = try await context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = SyncTransactionService()
        await #expect(throws: CancellationError.self) {
            try await service.run(plan: plan, inventory: inventory, shell: shell, backup: backup, journalDirectory: directory, prepare: { _ in throw CancellationError() })
        }
        #expect(await shell.commands.contains("uistop") == false)
        #expect(await shell.uiRunning)
    }
    @Test func reconnectingOriginalDeviceRecoversRetainedJournal() async throws {
        let (shell, inventory, plan, backup, directory) = try await context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = SyncTransactionService()
        await #expect(throws: (any Error).self) {
            try await service.run(plan: plan, inventory: inventory, shell: shell, backup: backup, journalDirectory: directory, prepare: { stage in
                await shell.put(stage + "/000/marker", "partial")
                await shell.changeIdentity()
            })
        }
        #expect(try SyncTransactionService.pendingJournals(in: directory, profile: inventory.profile).count == 1)
        await shell.setIdentity("ABC123")
        try await service.recover(journalDirectory: directory, profile: inventory.profile, shell: shell)
        #expect(try SyncTransactionService.pendingJournals(in: directory, profile: inventory.profile).isEmpty)
        #expect(await shell.data("/var/lib/hakchi/games/nes-usa/.storage/CLV-H-OLDXX/game.nes") == Data("old".utf8))
    }

}

extension SyncTransactionTests {
    @Test func rollbackRestoresAbsentMenuMarker() async throws {
        let (shell, inventory, plan, backup, directory) = try await context()
        defer { try? FileManager.default.removeItem(at: directory) }
        await shell.setMenuState(nil)
        await shell.fail("uistart")
        await #expect(throws: (any Error).self) {
            try await SyncTransactionService().run(plan: plan, inventory: inventory, shell: shell, backup: backup, journalDirectory: directory, prepare: { stage in
                await shell.put(stage + "/000/marker", "new")
            })
        }
        #expect(await shell.menuState == nil)
        #expect(await shell.uiRunning)
    }
}

actor StagingGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; entryWaiter?.resume(); entryWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

extension SyncTransactionTests {
    @Test func cancellationAtCommitProgressBoundaryNeverStartsActivation() async throws {
        let (shell, inventory, plan, backup, directory) = try await context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = SyncTransactionService(), gate = StagingGate()
        let task = Task {
            try await service.run(plan:plan,inventory:inventory,shell:shell,backup:backup,journalDirectory:directory,
                                  prepare:{ stage in await shell.put(stage + "/000/marker","new") },
                                  progress:{ status,_,_ in
                if status.hasPrefix("Activating verified library") { await gate.pause() }
            })
        }
        await gate.waitForEntry()
        #expect(await !shell.commands.contains("uistop"))
        task.cancel(); await gate.release()
        await #expect(throws:CancellationError.self) { try await task.value }
        #expect(await !shell.commands.contains("uistop"))
        #expect(await shell.data("/var/lib/hakchi/games/nes-usa/.storage/CLV-H-OLDXX/game.nes") == Data("old".utf8))
    }
    @Test func secondSyncCannotOverlapSuspendedUpload() async throws {
        let (shell, inventory, plan, backup, directory) = try await context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = SyncTransactionService(); let gate = StagingGate()
        let first = Task {
            try await service.run(plan: plan, inventory: inventory, shell: shell, backup: backup, journalDirectory: directory, prepare: { stage in
                await gate.pause()
                await shell.put(stage + "/000/marker", "new")
            })
        }
        await gate.waitForEntry()
        await #expect(throws: SyncPlanError.self) {
            try await service.run(plan: plan, inventory: inventory, shell: shell, backup: backup, journalDirectory: directory, prepare: { _ in Issue.record("Second operation entered staging") })
        }
        await gate.release(); try await first.value
        #expect(await shell.uiRunning)
    }
}
