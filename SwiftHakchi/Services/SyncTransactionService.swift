import Foundation
import SwiftHakchiCore

actor SyncTransactionService {
    private var running = false

    func run(plan: SyncPlan, inventory: DeviceInventory, shell: any ConsoleShell,
             backup: VerifiedConsoleBackup, journalDirectory: URL,
             prepare: @Sendable (String) async throws -> Void,
             progress: @Sendable (String, Double, Bool) async -> Void = { _, _, _ in }) async throws {
        guard !running else { throw SyncPlanError.invalidInput("Another console operation is already running.") }
        running = true
        defer { running = false }
        guard inventory.canSync, let base = inventory.syncBase,
              plan.profile.deviceID == inventory.profile.deviceID,
              plan.profile.systemCode == inventory.profile.systemCode else { throw SyncPlanError.unsupportedConsole }
        try ConsoleBackupService.verify(backup, for: inventory)
        let pending = try Self.pendingJournals(in: journalDirectory, profile: inventory.profile)
        guard pending.isEmpty else { throw SyncPlanError.invalidInput("A previous sync needs recovery before another sync can start. Use Recover Interrupted Sync in Tools.") }
        try await verifyIdentity(inventory.profile, shell: shell)
        let fresh = try await DeviceInventoryService.inspect(shell: shell)
        guard fresh.canSync, fresh.syncBase == inventory.syncBase,
              fresh.installedCodes == inventory.installedCodes,
              fresh.visibleCodes == inventory.visibleCodes, fresh.activePage == inventory.activePage,
              fresh.freeBytes >= plan.requiredStagingBytes + 10 * 1024 * 1024 else {
            throw SyncPlanError.invalidInput("The console inventory or free space changed. Review the sync again.")
        }
        let menuPath = try await shell.executeChecked("hakchi eval 'printf \"/var/saves/%s/menu\" \"$modname\"'").output
        guard menuPath.range(of: #"^/var/saves/[A-Za-z0-9_-]+/menu$"#, options: .regularExpression) != nil else {
            throw SyncPlanError.invalidInput("Could not determine the console menu state path.")
        }
        let markerExists = try await shell.execute("test -f \(q(menuPath))", timeout: 30_000)
        guard markerExists.exitCode == 0 || markerExists.exitCode == 1 else { throw SyncPlanError.invalidInput("Could not read the menu state.") }
        let oldMarker = markerExists.succeeded ? try await shell.executeChecked("cat \(q(menuPath))").stdoutData : nil
        var journal = SyncJournal(profile: inventory.profile, activeBase: base, oldPage: inventory.activePage,
            originalGamesPath: inventory.originalGamesPath,
            expectedCodes: Set(plan.selectedGames.filter { !$0.isStock }.map(\.code)), menuStatePath: menuPath, oldMenuState: oldMarker)
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        let file = journalDirectory.appendingPathComponent(journal.id.uuidString + ".journal.json")
        try save(journal, to: file)
        do {
            await progress("Uploading replacement library...", 0.1, true)
            try await prepare(journal.stage)
            _ = try await shell.executeChecked("cd \(q(journal.stage)) && sha256sum -c .sync-checksums", timeout: 300_000)
            try Task.checkCancellation()
            try await verifyIdentity(inventory.profile, shell: shell)
            // Disable cancellation in the UI before the durable commit boundary.
            try Task.checkCancellation()
            await progress("Activating verified library...", 0.8, false)
            try Task.checkCancellation()
            journal.phase = .activating
            try save(journal, to: file)
            // Once this phase starts, finish activation or recovery even after cancellation.
            let activationJournal = journal
            try await Task.detached {
                _ = try await shell.executeChecked("uistop")
                try await Self.unmountIfNeeded(activationJournal, shell: shell)
                _ = try await shell.executeChecked("mv \(Self.quote(activationJournal.activeBase)) \(Self.quote(activationJournal.previous))")
                _ = try await shell.executeChecked("mv \(Self.quote(activationJournal.stage)) \(Self.quote(activationJournal.activeBase))")
                try await Self.mount(activationJournal, page: activationJournal.activeBase + "/000", menuState: Data("000\n".utf8), shell: shell)
            }.value
            let installed = try await DeviceInventoryService.inspect(shell: shell)
            guard installed.profile.deviceID == plan.profile.deviceID,
                  installed.installedCodes == journal.expectedCodes else {
                throw SyncPlanError.invalidInput("The installed library did not match the verified plan.")
            }
            // Verify activation without inheriting a cancellation that arrived during commit.
            try await Task.detached {
                _ = try await shell.executeChecked("cd \(Self.quote(activationJournal.activeBase)) && sha256sum -c .sync-checksums", timeout: 300_000)
            }.value
            journal.phase = .verified
            try save(journal, to: file)
            let verifiedJournal = journal
            try await Task.detached { _ = try await shell.executeChecked("rm -rf \(Self.quote(verifiedJournal.previous))") }.value
            try FileManager.default.removeItem(at: file)
            await progress("Library synchronized and verified", 1, false)
        } catch {
            let failure = error
            let recoveryJournal = journal
            do {
                try await Task.detached { try await Self.restore(recoveryJournal, shell: shell) }.value
                try FileManager.default.removeItem(at: file)
            } catch {
                throw SyncPlanError.invalidInput("Sync did not finish, and recovery could not be verified: \(error.localizedDescription). Reconnect the same console and use Recover Interrupted Sync. Recovery record: \(file.lastPathComponent)")
            }
            throw failure
        }
    }

    func recover(journalDirectory: URL, profile: ConsoleProfile, shell: any ConsoleShell) async throws {
        guard !running else { throw SyncPlanError.invalidInput("Another console operation is running.") }
        running = true
        defer { running = false }
        for (url, journal) in try Self.pendingJournals(in: journalDirectory, profile: profile) {
            try await Self.restore(journal, shell: shell)
            try FileManager.default.removeItem(at: url)
        }
    }

    static func pendingJournals(in directory: URL, profile: ConsoleProfile) throws -> [(URL, SyncJournal)] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".journal.json") }.compactMap { url in
                let journal = try JSONDecoder().decode(SyncJournal.self, from: Data(contentsOf: url))
                guard journal.profile.deviceID == profile.deviceID, journal.profile.systemCode == profile.systemCode else { return nil }
                return (url, journal)
            }
    }

    private func verifyIdentity(_ profile: ConsoleProfile, shell: any ConsoleShell) async throws {
        try await Self.checkIdentity(profile, shell: shell)
    }
    private static func checkIdentity(_ profile: ConsoleProfile, shell: any ConsoleShell) async throws {
        let identity = try await shell.executeChecked(DeviceInventoryService.Command.identity).output.filter { !$0.isWhitespace }
        let system = try await shell.executeChecked(DeviceInventoryService.Command.system).output
        guard identity == profile.deviceID, ConsoleType.fromSystemCode(system).syncCode == profile.systemCode else {
            throw SyncPlanError.invalidInput("The attached console changed; reconnect the original console before continuing.")
        }
    }
    private static func directoryExists(_ path: String, shell: any ConsoleShell) async throws -> Bool {
        let result = try await shell.execute("test -d \(quote(path))", timeout: 30_000)
        guard result.exitCode == 0 || result.exitCode == 1 else { throw SyncPlanError.invalidInput("Could not inspect recovery directories.") }
        return result.succeeded
    }
    private static func validate(_ journal: SyncJournal) throws {
        let expected = "/var/lib/hakchi/games/\(journal.profile.systemCode)"
        guard journal.profile.supportsGameSync, journal.activeBase == expected,
              journal.originalGamesPath == "/usr/share/games/nes/kachikachi",
              journal.menuStatePath?.range(of: #"^/var/saves/[A-Za-z0-9_-]+/menu$"#, options: .regularExpression) != nil,
              journal.oldPage.range(of: "^" + NSRegularExpression.escapedPattern(for: expected) + #"/[0-9]{3}$"#, options: .regularExpression) != nil else {
            throw SyncPlanError.invalidInput("Recovery record contains an unsupported storage path.")
        }
    }
    private static func restore(_ journal: SyncJournal, shell: any ConsoleShell) async throws {
        try validate(journal)
        try await checkIdentity(journal.profile, shell: shell)
        if journal.phase == .verified {
            _ = try await shell.executeChecked("cd \(quote(journal.activeBase)) && sha256sum -c .sync-checksums", timeout: 300_000)
            _ = try await shell.executeChecked("rm -rf \(quote(journal.previous))")
            return
        }
        if journal.phase == .activating {
            _ = try await shell.executeChecked("uistop")
            try await unmountIfNeeded(journal, shell: shell)
            if try await directoryExists(journal.previous, shell: shell) {
                if try await directoryExists(journal.activeBase, shell: shell) {
                    _ = try await shell.executeChecked("mv \(quote(journal.activeBase)) \(quote(journal.failed))")
                }
                _ = try await shell.executeChecked("mv \(quote(journal.previous)) \(quote(journal.activeBase))")
            }
            guard try await directoryExists(journal.activeBase, shell: shell) else { throw SyncPlanError.invalidInput("The original game directory is unavailable.") }
            try await mount(journal, page: journal.oldPage, menuState: journal.oldMenuState, shell: shell)
        }
        _ = try await shell.executeChecked("rm -rf \(quote(journal.stage)) \(quote(journal.failed))")
    }
    private static func unmountIfNeeded(_ journal: SyncJournal, shell: any ConsoleShell) async throws {
        let mounted = try await shell.execute("grep -Fq \(quote(" " + journal.originalGamesPath + " ")) /proc/mounts", timeout: 30_000)
        guard mounted.exitCode == 0 || mounted.exitCode == 1 else { throw SyncPlanError.invalidInput("Could not inspect the console game mount.") }
        if mounted.succeeded { _ = try await shell.executeChecked("umount \(quote(journal.originalGamesPath))") }
    }
    private static func mount(_ journal: SyncJournal, page: String, menuState: Data?, shell: any ConsoleShell) async throws {
        _ = try await shell.executeChecked("mount --bind \(quote(page)) \(quote(journal.originalGamesPath))")
        _ = try await shell.executeChecked("ln -sfn \(quote(page)) /var/games")
        guard let marker = journal.menuStatePath else { throw SyncPlanError.invalidInput("Recovery record is missing menu state.") }
        if let menuState {
            let parent = (marker as NSString).deletingLastPathComponent
            let temporary = marker + ".sync-" + journal.id.uuidString
            _ = try await shell.executeChecked("mkdir -p \(quote(parent))")
            try await shell.upload(data: menuState, to: temporary, timeout: 30_000)
            _ = try await shell.executeChecked("mv \(quote(temporary)) \(quote(marker))")
            let actual = try await shell.executeChecked("cat \(quote(marker))").stdoutData
            guard actual == menuState else { throw SyncPlanError.invalidInput("The console menu state did not verify.") }
        } else {
            _ = try await shell.executeChecked("rm -f \(quote(marker))")
        }
        _ = try await shell.executeChecked("uistart")
    }
    private func save(_ journal: SyncJournal, to file: URL) throws { try JSONEncoder().encode(journal).write(to: file, options: .atomic) }
    private func q(_ string: String) -> String { Self.quote(string) }
    private static func quote(_ string: String) -> String { LaunchCommand.shellQuote(string) }
}
