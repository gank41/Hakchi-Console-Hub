import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@Suite(.serialized) struct SNESLibraryStartupCandidateTests {
    private static let cleanMaskLiteral = #"test "$mcp_sigblk" = 0000000000000000"#
    @Test func libraryStartupHasItsOwnManagementIdentity() throws {
        let expected = SNESStartupTrialExpectation(hwid: String(repeating: "1", count: 32), runtimeSHA256: String(repeating: "a", count: 64),
            wrapperSHA256: String(repeating: "b", count: 64), deviceVersion: 0x6a0b, menuWrapperSHA256: String(repeating: "c", count: 64))
        try expected.validate()
        #expect(expected.menuEnabled)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_LIBRARY_PARENT"] != nil))
    func reconstructsTheAcceptedParentAndPreservesItsKernelKeysAndOldRecipe() async throws {
        let env = ProcessInfo.processInfo.environment
        let operation = URL(fileURLWithPath: try #require(env["SWIFTHAKCHI_SNES_LIBRARY_PARENT"]))
        let review = try #require(env["SWIFTHAKCHI_SNES_LIBRARY_PARENT_REVIEW"])
        let pinned = try PinnedFELInputs.load(), recovery = RecoveryBootInputs(fes1: pinned.fes1, uboot: pinned.uboot, bootImage: pinned.bootImage)
        let journal = try await SNESFirmwareJournal.reopen(operation: operation, reviewSHA256: review, recovery: recovery)
        let parent: SNESMenuStartupParent
        do { parent = try await journal.libraryStartupParent(); try await journal.close() }
        catch { try? await journal.close(); throw error }
        let previous = parent.installed.trial.candidate
        #expect(previous.hasMenuSupport && !previous.hasNavigationLaunchSupport)
        #expect(parent.candidate.hasNavigationLaunchSupport && parent.candidate.managementVersion == 0x6a0b)
        try parent.require(parent.candidate)
        let savedParent = try Data(contentsOf: operation.appendingPathComponent("plan.json"))
        try SNESFirmwareJournal.requireUpgradeParent(parent, savedPlan: savedParent, directory: operation)
        var substitutedPlan = savedParent; substitutedPlan.append(32)
        #expect(throws: (any Error).self) { try SNESFirmwareJournal.requireUpgradeParent(parent, savedPlan: substitutedPlan, directory: operation) }
        let original = try LegacyBootImageBuilder.inspect(previous.image), changed = try LegacyBootImageBuilder.inspect(parent.candidate.image)
        #expect(changed.kernel == original.kernel && changed.header[64..<576] == original.header[64..<576])
        #expect(parent.candidate.image.count <= 4 * 1024 * 1024)
        try SNESColdBootPolicy.require(boot1: parent.candidate.material.support.source.preparation.source.boot1, image: parent.candidate.image)
        let changes: Set<String> = ["swifthakchi/prepare", "swifthakchi/service", "swifthakchi/menu-configure", "swifthakchi/runtime-files.sha256", "swifthakchi/files.sha256", "swifthakchi/library-selector", "swifthakchi/menu-change", "swifthakchi/menu-route"]
        for entry in original.archive.entries where !changes.contains(entry.name) {
            var actual = try #require(changed.archive.entries.first(where: { $0.name == entry.name }))
            // Archive-local inode numbering may shift for runtime assets; payloads and other metadata cannot.
            if entry.name.hasPrefix("swifthakchi/") { actual.fields[0] = entry.fields[0] }
            #expect(actual == entry)
        }
        #expect(Set(changed.archive.entries.map(\.name)).subtracting(original.archive.entries.map(\.name)) ==
            (previous.hasLibrarySupport ? Set(["swifthakchi/menu-launch"]):Set(["swifthakchi/library-selector", "swifthakchi/menu-route", "swifthakchi/menu-change", "swifthakchi/menu-launch"])))
        let manifest = try JSONSerialization.jsonObject(with: parent.candidate.checkedExport().manifest) as? [String: Any]
        #expect(manifest?["schemaVersion"] as? Int == 10)
        #expect(manifest?["firmwareInstallEligible"] as? Bool == false)
        try parent.validate()
        if let path=env["SWIFTHAKCHI_CLEAN_MENU_REPORT_EXPORT"] {
            let temporary=try testDirectory();defer {try? FileManager.default.removeItem(at:temporary)}
            let io=try MenuStartupPreflightFake(parent:parent,fault:"none")
            let result=try await SNESStartupPreflightService(wait:{}).capture(candidate:parent.candidate,inputs:recovery,io:io,parent:parent)
            let directory=try await RecoveryBootSnapshotStore(root:temporary).saveSNESStartupPreflight(result)
            let trial=try PreparedSNESStartupTrial.prepare(candidate:parent.candidate,evidence:directory,recovery:recovery,parent:parent)
            let script=try SNESStartupTrialCommands.script(trial:trial,challenge:UUID(uuidString:"11111111-1111-1111-1111-111111111111")!)
            #expect(script.contains("MCP_SIGBLK=%s") && script.contains("UI_SIGBLK=%s") && script.contains(Self.cleanMaskLiteral))
            try Data(script.utf8).write(to:URL(fileURLWithPath:path),options:.withoutOverwriting)
            #expect(await io.base.stages==1)
        }
        if let path = env["SWIFTHAKCHI_SNES_LIBRARY_CANDIDATE_EXPORT"] {
            let root = URL(fileURLWithPath: path), store = try RecoveryBootSnapshotStore(root: root)
            let directory = try await store.saveSNESStartupCandidate(parent.candidate)
            #expect(try SNESStartupAdapterCandidate.load(directory: directory).image == parent.candidate.image)
            let summary: [String: Any] = ["candidate": directory.path, "imageBytes": parent.candidate.image.count,
                "imageSHA256": BackupManifest.digest(parent.candidate.image), "parentOperation": operation.path,
                "parentReviewSHA256": review, "consoleAccessed": false, "firmwareWritten": false]
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("prepared.json"))
        }
    }
}
