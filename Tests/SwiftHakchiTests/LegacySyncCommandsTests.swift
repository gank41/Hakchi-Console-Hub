import Foundation
import Testing
@testable import SwiftHakchi
@testable import SwiftHakchiCore

struct LegacySyncCommandsTests {
    @Test func activationRequiresVerifiedStageAndJournalsBeforeEitherRename() throws {
        let id = UUID(), tree = String(repeating: "a", count: 64)
        let archive = String(repeating: "b", count: 64)
        let script = try LegacySyncCommands.activate(operationID: id, treeSHA256: tree,
                                                      archiveSHA256: archive, archiveBytes: 8192)
        let marker = try #require(script.range(of: "verified.marker"))
        let stop = try #require(script.range(of: "stop_ui || fail"))
        let oldMove = try #require(script.range(of: "mv \"$live\" \"$old\""))
        let newMove = try #require(script.range(of: "mv \"$stage\" \"$live\""))
        #expect(marker.lowerBound < stop.lowerBound)
        #expect(stop.lowerBound < oldMove.lowerBound)
        #expect(oldMove.lowerBound < newMove.lowerBound)
        #expect(script.contains("find . -mindepth 1"))
        #expect(script.contains("sha256sum \"$tx/menu.tar\""))
        #expect(script.contains("phase STOPPED"))
        #expect(script.contains("phase OLD_MOVED"))
        #expect(script.contains("phase NEW_ACTIVE"))
        #expect(script.contains("phase MENU_STARTED"))
        #expect(script.contains("old.identity"))
        #expect(script.range(of: "mv \"$tx/old.identity.partial\" \"$tx/old.identity\"")!.lowerBound
            < script.range(of: "mv \"$live\" \"$old\"")!.lowerBound)
        #expect(script.contains("/var/lib/hakchi/games/nes.swift-old-\(id.uuidString)"))
        #expect(script.contains("/var/lib/hakchi/games/nes.swift-stage-\(id.uuidString)"))
        #expect(!script.contains("rm -rf"))
        #expect(!script.contains("reboot"))
        #expect(script.utf8.count <= 65_536)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let shellFile = root.appendingPathComponent("activate.sh")
        try Data(script.utf8).write(to: shellFile)
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/sh")
        check.arguments = ["-n", shellFile.path]
        try check.run(); check.waitUntilExit()
        #expect(check.terminationStatus == 0)
    }

    @Test func malformedHashCannotBuildActivationAndReceiptMustBeExact() throws {
        let id = UUID(), tree = String(repeating: "a", count: 64)
        #expect(throws: (any Error).self) {
            try LegacySyncCommands.activate(operationID: id, treeSHA256: "bad",
                                            archiveSHA256: tree, archiveBytes: 8192)
        }
        let exact = "ACTIVE:\(id.uuidString):\(tree)\n"
        try LegacySyncCommands.requireActiveReceipt(
            SSHResult(stdout: exact, stderr: "", stdoutData: Data(exact.utf8), exitCode: 0),
            operationID: id, treeSHA256: tree)
        #expect(throws: (any Error).self) {
            try LegacySyncCommands.requireActiveReceipt(
                SSHResult(stdout: exact, stderr: "", stdoutData: Data(exact.utf8), exitCode: 1),
                operationID: id, treeSHA256: tree)
        }
    }

    @Test func recoveryInspectionIsReadOnlyAndClassifiesRenameBoundary() throws {
        let id = UUID(), tree = String(repeating: "a", count: 64)
        let script = try LegacySyncCommands.inspect(operationID: id, treeSHA256: tree)
        #expect(script.contains("/var/lib/hakchi/games/nes.swift-old-\(id.uuidString)"))
        #expect(script.contains("/var/lib/hakchi/games/nes.swift-stage-\(id.uuidString)"))
        #expect(!script.contains("killall"))
        #expect(!script.contains("mkdir"))
        #expect(!script.contains("mv \""))
        #expect(!script.contains("rm \""))
        let text = """
        SYNC_STATE
        ID=\(id.uuidString)
        PHASE=OLD_MOVED
        TX=1
        LIVE=0
        OLD=1
        STAGE=1
        FAILED=0
        LOCK=1
        ARCHIVE=1
        VERIFIED=1
        END

        """
        let inspection = try LegacySyncCommands.parseInspection(Data(text.utf8),
                                                                   operationID: id)
        #expect(inspection.phase == .oldMoved)
        #expect(inspection.outcome == .firstRenameUncertain)
        let interruptedSecondRename = text
            .replacingOccurrences(of: "STAGE=1", with: "STAGE=0")
            .replacingOccurrences(of: "FAILED=0", with: "FAILED=1")
        let secondState = try LegacySyncCommands.parseInspection(
            Data(interruptedSecondRename.utf8), operationID: id)
        #expect(secondState.outcome == .firstRenameUncertain)
        let changed = text.replacingOccurrences(of: "ID=\(id.uuidString)", with: "ID=\(UUID().uuidString)")
        #expect(throws: (any Error).self) {
            try LegacySyncCommands.parseInspection(Data(changed.utf8), operationID: id)
        }
    }

    @Test func leaseRequestsExposeOnlyTypedStageOperations() throws {
        let id = UUID(), tree = String(repeating: "a", count: 64)
        let archive = String(repeating: "b", count: 64)
        #expect(try LegacyChangeRequest.verifyStage(id, archive, 8192, tree, 16_384, []).command
            .contains("verified.marker"))
        #expect(try LegacyChangeRequest.activateStage(id, tree, archive, 8192).command
            .contains("phase OLD_MOVED"))
        #expect(try LegacyChangeRequest.inspectStage(id, tree).command
            .contains("SYNC_STATE"))
        #expect(try LegacyChangeRequest.acceptStage(id, tree).command
            .contains("rmdir \"$lock\""))
    }

    @Test func acceptanceReleasesOnlyOwnedLockAndKeepsOldTree() throws {
        let id = UUID(), tree = String(repeating: "a", count: 64)
        let script = try LegacySyncCommands.accept(operationID: id, treeSHA256: tree)
        #expect(script.contains("rm \"$lock/owner\""))
        #expect(script.contains("rmdir \"$lock\""))
        #expect(script.contains("phase ACCEPTED"))
        #expect(script.range(of: "phase ACCEPTED")!.lowerBound
            < script.range(of: "rm \"$lock/owner\"")!.lowerBound)
        #expect(script.contains("MENU_STARTED|ACCEPTED"))
        #expect(!script.contains("rm -rf"))
        #expect(!script.contains("rmdir \"$old\""))
        #expect(!script.contains("mv \"$old\""))
        let expected = "ACCEPTED:\(id.uuidString):\(tree)\n"
        try LegacySyncCommands.requireAcceptedReceipt(
            SSHResult(stdout: expected, stderr: "", stdoutData: Data(expected.utf8), exitCode: 0),
            operationID: id, treeSHA256: tree)
        do {
            try LegacySyncCommands.requireAcceptedReceipt(
                SSHResult(stdout: "", stderr: "", stdoutData: Data(), exitCode: 87),
                operationID: id, treeSHA256: tree)
            Issue.record("A failed console precondition was accepted.")
        } catch {
            #expect(error.localizedDescription.contains("87"))
        }
    }

    @Test func recoveryCommandsAreBoundedAndShellValid() throws {
        let id = UUID(), tree = String(repeating: "a", count: 64)
        let discard = try LegacySyncCommands.discard(operationID: id, treeSHA256: tree)
        let rollback = try LegacySyncCommands.rollback(operationID: id, treeSHA256: tree)
        #expect(discard.contains("[ ! -e \"$old\" ]"))
        #expect(discard.contains("[ ! -e \"$lock\" ]"))
        #expect(discard.contains("rm -rf -- \"$stage\""))
        #expect(discard.contains("rm -rf -- \"$tx\""))
        #expect(!discard.contains("rm -rf -- \"$live\""))
        #expect(rollback.contains("mv \"$live\" \"$failed\""))
        #expect(rollback.contains("mv \"$old\" \"$live\""))
        #expect(rollback.contains("phase ROLLED_BACK"))
        #expect(rollback.contains("restart_ui || exit"))
        #expect(rollback.contains("rmdir \"$lock\""))
        #expect(rollback.contains("fd=${f##*/}"))
        #expect(!rollback.contains("fd=\\${f##*/}"))
        #expect(rollback.contains("stat -c '%d:%i' \"$live\""))
        #expect(rollback.contains("stat -c '%d:%i' \"$old\""))
        #expect(rollback.contains("old.identity"))
        #expect(!rollback.contains("canonical \"$base\" && canonical \"$tx\" && canonical \"$lock\" && canonical \"$old\""))
        let fdLine = try #require(rollback.split(separator: "\n")
            .map(String.init).first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("fd=") })
        let fdExpansion = Process()
        fdExpansion.executableURL = URL(fileURLWithPath: "/bin/sh")
        fdExpansion.arguments = ["-c", "f=/proc/self/fd/12\n" + fdLine + "\n[ \"$fd\" = 12 ]"]
        try fdExpansion.run(); fdExpansion.waitUntilExit()
        #expect(fdExpansion.terminationStatus == 0)
        #expect(!rollback.contains("rm -rf"))
        for (name, script) in [("discard", discard), ("rollback", rollback)] {
            let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent(name + ".sh")
            try Data(script.utf8).write(to: file)
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = ["-n", file.path]
            try shell.run(); shell.waitUntilExit()
            #expect(shell.terminationStatus == 0)
            #expect(script.utf8.count <= 65_536)
        }
    }

    @Test func recoveryInspectionAcceptsMissingTransactionAndRejectsMalformedState() throws {
        let id = UUID()
        let missing = """
        SYNC_STATE
        ID=\(id.uuidString)
        PHASE=MISSING
        TX=0
        LIVE=1
        OLD=0
        STAGE=0
        FAILED=0
        LOCK=0
        ARCHIVE=0
        VERIFIED=0
        END

        """
        let state = try LegacySyncCommands.parseInspection(Data(missing.utf8), operationID: id)
        #expect(!state.transaction && state.outcome == .beforeRename)
        #expect(throws: (any Error).self) {
            try LegacySyncCommands.parseInspection(
                Data(missing.replacingOccurrences(of: "TX=0", with: "TX=UNSAFE").utf8),
                operationID: id)
        }
    }
}
