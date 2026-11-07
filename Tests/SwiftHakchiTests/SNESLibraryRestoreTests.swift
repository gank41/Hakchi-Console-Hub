import Foundation
import Darwin
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

// These fixtures use a real 60-second inventory freshness window. Running all
// the publication fault cases at once can age an unrelated fixture past it.
@Suite(.serialized) @MainActor struct SNESLibraryRestoreTests {
    @Test func nativeSaveInspectionRequiresTheAppRecoveryFolder() throws {
        let root = try SNESLibraryJournalPolicy.root(), id = UUID()
        let operation = root.appendingPathComponent("SNESSaveTransfer-" + id.uuidString)
        try SNESReplacementSaveJournalPolicy.requireOperation(operation)
        #expect(throws: (any Error).self) { try SNESReplacementSaveJournalPolicy.requireOperation(root.appendingPathComponent("SNESSaveDraft-" + id.uuidString)) }
        #expect(throws: (any Error).self) { try SNESReplacementSaveJournalPolicy.requireOperation(URL(fileURLWithPath: "/tmp/SNESSaveTransfer-" + id.uuidString)) }
    }

    func backup(_ root: URL, originals: SNESOriginalGamesFrame, menu: SNESLibraryMenu? = nil, legacy: SNESOneGameMenu? = nil, builtinSelectorMode: Int? = nil, profileFiles: [String: Data] = [:], profileDirectories: [String] = [], profileModified: Int64 = 0, hwid: String? = nil) async throws -> SNESLibraryBackup {
        let fixture = SNESLibraryInventoryTests(), nonce = UUID(), catalog = try SNESLibraryCatalogIdentity.digest(originals)
        var payloads: [String: Data] = ["clover/settings.json": Data("{}".utf8)]
        var raw: Data
        if let legacy {
            let selector = Data("SWIFTHAKCHI_SNES_MENU_SELECTOR_V1\n\(legacy.id.uuidString)\n\(legacy.treeSHA256)\n".utf8)
            payloads["legacy/active-menu"] = selector
            payloads["legacy/menus/\(legacy.id.uuidString)/menu.manifest"] = legacy.manifest
            for (name, data) in legacy.files { payloads["legacy/menus/\(legacy.id.uuidString)/" + name] = data }
            var rows = ["SWIFTHAKCHI_SNES_LIBRARY_INVENTORY_V1 " + nonce.uuidString, "CONTEXT " + fixture.context, "HWID " + fixture.hwid,
                "CATALOG " + catalog, "SPACE 4096 76800 64000", "NAMESPACE absent absent",
                "SELECTOR legacy \(legacy.id.uuidString) \(legacy.treeSHA256) \(BackupManifest.digest(selector))",
                "MENU legacy \(legacy.id.uuidString) \(legacy.treeSHA256) \(legacy.manifest.count) 0 -", "DIR 636c6f766572 448"]
            for (index, path) in payloads.keys.sorted().enumerated() {
                let data = try #require(payloads[path])
                rows.append("FILE \(fixture.hex(path)) \(data.count) \(BackupManifest.digest(data)) 384 0 1 \(index+1) 0")
            }
            raw = Data((rows.joined(separator: "\n") + "\nEND\n").utf8)
        } else {
            raw = Data(String(decoding: try fixture.frame(challenge: nonce, menu: menu), as: UTF8.self).replacingOccurrences(of: "CATALOG " + fixture.catalog, with: "CATALOG " + catalog).utf8)
            if let menu {
                payloads["active-menu"] = Data("SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1\nMENU\n\(menu.id.uuidString)\n\(BackupManifest.digest(try SNESLibraryStartupScripts.manifest(for: menu)))\n".utf8)
                payloads["descriptions/\(menu.id.uuidString).json"] = menu.manifest
                payloads["menus/\(menu.id.uuidString)/menu.manifest"] = try SNESLibraryStartupScripts.manifest(for: menu)
                for (path, data) in menu.files { payloads["menus/\(menu.id.uuidString)/" + path] = data }
                for (path, data) in menu.objects { payloads["objects/" + path] = data }
            }
        }
        if let mode = builtinSelectorMode {
            let selector = Data("SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1\nBUILTIN\n".utf8)
            payloads["active-menu"] = selector
            var rows = String(decoding: raw, as: UTF8.self).components(separatedBy: "\n").filter { !$0.isEmpty && $0 != "END" }
            rows = rows.map { $0.hasPrefix("NAMESPACE ") ? "NAMESPACE ready ready" : ($0.hasPrefix("SELECTOR ") ? "SELECTOR builtin - - \(BackupManifest.digest(selector))" : $0) }
            rows.append("FILE \(fixture.hex("active-menu")) \(selector.count) \(BackupManifest.digest(selector)) \(mode) 0 1 999 0")
            rows.append("END"); raw = Data((rows.joined(separator: "\n") + "\n").utf8)
        }
        if !profileFiles.isEmpty || !profileDirectories.isEmpty {
            var rows = String(decoding: raw, as: UTF8.self).components(separatedBy: "\n").filter { !$0.isEmpty && $0 != "END" }
            var directories = Set<String>()
            for directory in profileDirectories {
                guard directory.hasPrefix("clover/profiles/") else { throw SNESLibraryInventory.failure() }
                var parent = directory
                while parent != "clover" { directories.insert(parent); parent = String(parent[..<parent.lastIndex(of: "/")!]) }
            }
            for (path, bytes) in profileFiles {
                guard path.hasPrefix("clover/profiles/") else { throw SNESLibraryInventory.failure() }
                payloads[path] = bytes
                var parent = String(path[..<path.lastIndex(of: "/")!])
                while parent != "clover" { directories.insert(parent); parent = String(parent[..<parent.lastIndex(of: "/")!]) }
            }
            for directory in directories.sorted() { rows.append("DIR \(fixture.hex(directory)) 448") }
            for (index, path) in profileFiles.keys.sorted().enumerated() {
                let bytes = try #require(profileFiles[path])
                rows.append("FILE \(fixture.hex(path)) \(bytes.count) \(BackupManifest.digest(bytes)) 384 \(profileModified) 1 \(20000+index) 0")
            }
            rows.append("END"); raw = Data((rows.joined(separator: "\n") + "\n").utf8)
        }
        let backupHWID = hwid ?? fixture.hwid
        if backupHWID != fixture.hwid {
            raw = Data(String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "HWID " + fixture.hwid, with: "HWID " + backupHWID).utf8)
        }
        let inventory = try SNESLibraryInventory(raw: raw, challenge: nonce, contextSHA256: fixture.context, hwid: backupHWID, catalogSHA256: catalog)
        let captured = payloads
        return try await SNESLibraryBackup.capture(inventory: inventory, root: root, read: { file, offset in
            let data = try #require(captured[file.path]); return Data(data[offset..<min(offset + SNESLibraryBackupChunk.maximumBytes, data.count)])
        }, refresh: { inventory })
    }
    @Test func sameConsoleSaveComparisonReportsChangesWithoutPreparingTransfer() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryMaterialTests(), (library, originals) = try fixture.fixture(root), menu = try fixture.menu(library, originals)
        let base = "clover/profiles/0/CLV-U-A0001/"
        let oldFiles = [base + "cartridge.sram": Data([1]), base + "cartridge.sram.hash": Data([2]),
                        base + "suspendpoint1/state.png": Data([3]), "clover/profiles/0/other.dat": Data([5])]
        let newFiles = [base + "cartridge.sram": Data([9]), base + "cartridge.sram.hash": Data([2]),
                        base + "suspendpoint2/state.png": Data([4]), "clover/profiles/0/CLV-P-BBBBB/save": Data([6])]
        let old = try await backup(root, originals: originals, menu: menu, profileFiles: oldFiles)
        let current = try await backup(root, originals: originals, menu: menu, profileFiles: newFiles)
        let comparison = try SNESLibrarySaveComparison.compare(backup: old, observed: current.inventory)
        #expect(comparison.matching == 1 && comparison.changed == 1)
        #expect(comparison.backupOnly == 2 && comparison.consoleOnly == 2)
        let game = try #require(comparison.gameDifferences.first { $0.gameCode == "CLV-U-A0001" })
        #expect(game.changed == 1 && game.backupOnly == 1 && game.consoleOnly == 1)
        let included = try #require(comparison.gameDifferences.first { $0.gameCode == "CLV-P-BBBBB" })
        #expect(included.changed == 0 && included.backupOnly == 0 && included.consoleOnly == 1)
        #expect(comparison.otherDifferences.backupOnly == 1)
        let other = try await backup(root, originals: originals, menu: menu, profileFiles: newFiles, hwid: String(repeating: "2", count: 32))
        #expect(throws: (any Error).self) { try SNESLibrarySaveComparison.compare(backup: old, observed: other.inventory) }
        try old.validate(); try current.validate()
        try Data("changed".utf8).write(to: old.directory.appendingPathComponent("manifest.json"))
        #expect(throws: (any Error).self) { try SNESLibrarySaveComparison.compare(backup: old, observed: current.inventory) }
    }
    @Test func libraryRestoreRetainsLayoutObjectsAndSavesWithoutOriginalMacFiles() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryMaterialTests(), (review, originals) = try fixture.fixture(root), menu = try fixture.menu(review, originals)
        let saved = try await backup(root, originals: originals, menu: menu)
        for directory in Set(menu.sources.map(\.directory)) { try FileManager.default.removeItem(at: URL(fileURLWithPath: directory)) }
        let anotherCapture = UUID()
        let recaptured = try SNESOriginalGamesFrame(originalGamesFrameFixture(challenge: anotherCapture), binding: originalGamesBinding(), challenge: anotherCapture)
        let id = UUID(), restored = try SNESLibraryRestore.prepare(backup: saved, originals: recaptured, expectedHWID: SNESLibraryInventoryTests().hwid, id: id)
        let next = try #require(restored.menu)
        #expect(next.id == id && next.graph == menu.graph && next.description.structure == menu.description.structure)
        #expect(next.objects == menu.objects && next.files == menu.files && next.sources.isEmpty)
        #expect(try saved.read(path: "clover/settings.json") == Data("{}".utf8))
        let material = try SNESLibraryMaterial.freeze(menu: next, in: root)
        try material.validate()
        #expect(throws: (any Error).self) { try SNESLibraryRestore.prepare(backup: saved, originals: originals, expectedHWID: String(repeating: "2", count: 32)) }
    }
    @Test func originalOneGameSnapshotMigratesToIndependentContentObjects() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let originals = try SNESOriginalGamesFrame(originalGamesFrameFixture(), binding: originalGamesBinding(), challenge: originalGamesChallenge)
        let legacy = try SNESOneGameMenu.prepare(originals: originals, code: "CLV-U-ABCDE", metadata: oneGameMetadata,
            rom: oneGameSyntheticROM(), artwork: oneGameSyntheticArt())
        let saved = try await backup(root, originals: originals, legacy: legacy)
        let restored = try SNESLibraryRestore.prepare(backup: saved, originals: originals, expectedHWID: SNESLibraryInventoryTests().hwid)
        let menu = try #require(restored.menu); try menu.validate()
        #expect(menu.graph.screens.flatMap(\.gameCodes).count == legacy.gameCount)
        #expect(menu.objects.values.contains(try #require(legacy.files["games/CLV-U-ABCDE/CLV-U-ABCDE.sfrom"])))
        let desktop = try #require(menu.files["pages/000/CLV-U-ABCDE/CLV-U-ABCDE.desktop"])
        #expect(String(decoding: desktop, as: UTF8.self).contains("Name=My Arkanoid – Édition"))
        #expect(!String(decoding: desktop, as: UTF8.self).contains("snes-v1/"))
        for (path, raw) in menu.files where path.contains("/CLV-P-") {
            let text = String(decoding: raw, as: UTF8.self)
            #expect(text.contains("SortRawTitle="), "Restored built-in menu entries must use the console's actual key spelling")
            #expect(!text.contains("\nsortrawtitle="))
        }
        #expect(menu.sources.isEmpty)
    }
    @Test func builtInOnlyBackupIsAnExplicitBuiltInSelection() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let originals = try SNESOriginalGamesFrame(originalGamesFrameFixture(), binding: originalGamesBinding(), challenge: originalGamesChallenge)
        let saved = try await backup(root, originals: originals)
        #expect(try SNESLibraryRestore.prepare(backup: saved, originals: originals, expectedHWID: SNESLibraryInventoryTests().hwid).menu == nil)
    }
    @Test func replacementPreparationKeepsGameFilesAndIdentifiesSavedProfilesWithoutWriting() async throws {
        let root=try testDirectory(); defer {try? FileManager.default.removeItem(at:root)}
        let fixture=SNESLibraryMaterialTests(), (review, originals)=try fixture.fixture(root), menu=try fixture.menu(review,originals)
        let savedPath="clover/profiles/0/CLV-U-A0001/save.bin"
        let builtinPath="clover/profiles/0/CLV-P-AAAAA/suspend/1.bin"
        let newPath="clover/profiles/0/CLV-U-A0002/save.bin"
        let otherNewPath="clover/profiles/0/CLV-P-BBBBB/save.bin"
        let directoryConflict="clover/profiles/0/CLV-U-A0001/directorySave"
        let unknownPath="clover/profiles/0/CLV-U-ZZZZZ/save.bin"
        let saved=try await backup(root,originals:originals,menu:menu,profileFiles:[savedPath:Data([1,2,3]),builtinPath:Data([8,9]),newPath:Data([5]),otherNewPath:Data([6]),directoryConflict:Data([11]),unknownPath:Data([4])])
        let target=String(repeating:"2",count:32), source=originalGamesBinding()
        let binding=SNESRuntimeBinding(sourceSnapshot:source.sourceSnapshot,setupManifestSHA256:source.setupManifestSHA256,expectedHWID:target)
        var frame=originalGamesFrameFixture()
        let header=Data(("HWID "+source.expectedHWID).utf8),range=try #require(frame.range(of:header))
        frame.replaceSubrange(range,with:Data(("HWID "+target).utf8))
        let targetOriginals=try SNESOriginalGamesFrame(frame,binding:binding,challenge:originalGamesChallenge)
        let plan=try SNESLibraryRestore.prepareReplacement(backup:saved,originals:targetOriginals,destinationHWID:target)
        #expect(plan.sourceHWID == source.expectedHWID && plan.destinationHWID == target)
        let restored=try #require(plan.menu)
        #expect(restored.graph == menu.graph && restored.objects == menu.objects)
        try restored.validate()
        let syncSource=try SNESLibraryRestore.prepareForSync(backup:saved,originals:targetOriginals,destinationHWID:target,scope:.replacementConsole)
        #expect(try #require(syncSource.menu).objects == menu.objects)
        #expect(throws:(any Error).self) {try SNESLibraryRestore.prepareForSync(backup:saved,originals:targetOriginals,destinationHWID:target,scope:.sameConsole)}
        let nativeMenu=try #require(syncSource.menu).withNativeArtwork()
        let frozen=try SNESLibraryMaterial.freeze(menu:nativeMenu,in:root)
        try frozen.validate()
        #expect(plan.saveFiles.map(\.path) == [builtinPath,otherNewPath,directoryConflict,savedPath,newPath])
        let originalFile = try #require(plan.saveFiles.first { $0.path == savedPath })
        let wrongMode = SNESLibraryInventory.File(path: originalFile.path, byteCount: originalFile.byteCount, sha256: originalFile.sha256,
            mode: originalFile.mode ^ 0o100, modified: originalFile.modified, identity: originalFile.identity)
        let wrongTime = SNESLibraryInventory.File(path: originalFile.path, byteCount: originalFile.byteCount, sha256: originalFile.sha256,
            mode: originalFile.mode, modified: originalFile.modified + 1, identity: originalFile.identity)
        #expect(SNESReplacementSaveReview.sameSavedFile(originalFile, originalFile))
        #expect(!SNESReplacementSaveReview.sameSavedFile(originalFile, wrongMode))
        #expect(!SNESReplacementSaveReview.sameSavedFile(originalFile, wrongTime))
        #expect(plan.unmatchedProfileFiles == [unknownPath])
        #expect(try plan.readSave(path:savedPath) == Data([1,2,3]))
        #expect(try plan.readSave(path:builtinPath) == Data([8,9]))
        #expect(throws:(any Error).self) {try plan.readSave(path:"clover/settings.json")}
        #expect(throws:(any Error).self) {try SNESLibraryRestore.prepareReplacement(backup:saved,originals:targetOriginals,destinationHWID:source.expectedHWID)}
        #expect(throws:(any Error).self) {try SNESLibraryRestore.prepareReplacement(backup:saved,originals:targetOriginals,destinationHWID:String(repeating:"3",count:32))}
        #expect(throws:(any Error).self) {try SNESLibraryRestore.prepare(backup:saved,originals:targetOriginals,expectedHWID:target)}
        var different=frame
        let romHash=Data(String(repeating:"c",count:64).utf8),hashRange=try #require(different.range(of:romHash))
        different.replaceSubrange(hashRange,with:Data(String(repeating:"d",count:64).utf8))
        let differentOriginals=try SNESOriginalGamesFrame(different,binding:binding,challenge:originalGamesChallenge)
        #expect(throws:(any Error).self) {try SNESLibraryRestore.prepareReplacement(backup:saved,originals:differentOriginals,destinationHWID:target)}
        let targetBackup=try await backup(root,originals:originals,profileFiles:[savedPath:Data([7]),builtinPath:Data([8,9]),directoryConflict+"/child.bin":Data([10]),"clover/profiles/0/CLV-U-A0002":Data([0])],hwid:target)
        let installation=SNESLibraryInstallationReference(hwid:target,operationID:UUID(),reviewSHA256:String(repeating:"c",count:64),
            catalog:root.appendingPathComponent("SNES-Original-Games-"+UUID().uuidString),catalogSHA256:String(repeating:"d",count:64))
        let syncPlan=try SNESLibrarySyncPlan.prepare(material:frozen,backup:targetBackup,before:targetBackup.inventory,
            capacity:targetBackup.inventory.capacity,installation:installation,originals:targetOriginals)
        #expect(syncPlan.before.hwid == target && syncPlan.backup.inventory.hwid == target)
        #expect(syncPlan.material.menu.objects == nativeMenu.objects)
        let comparison=try plan.compareSaves(to:targetBackup)
        #expect(comparison.entries.map(\.path) == [builtinPath,otherNewPath,directoryConflict,savedPath,newPath])
        #expect(comparison.entries.map(\.disposition) == [.unchanged,.new,.conflict,.conflict,.conflict])
        #expect(comparison.entries.map(\.gameMatch) == [.includedGame,.includedGame,.addedGameMissing,.addedGameMissing,.addedGameMissing])
        let targetWithGames=try await backup(root,originals:originals,menu:menu,hwid:target)
        let matchingGames=try plan.compareSaves(to:targetWithGames)
        #expect(matchingGames.entries.map(\.gameMatch) == [.includedGame,.includedGame,.matchingAddedGame,.matchingAddedGame,.matchingAddedGame])
        let changedRoot=root.appendingPathComponent("different-games")
        let (differentReview,_)=try fixture.fixture(changedRoot,romBytes:131072)
        let differentMenu=try fixture.menu(differentReview,originals)
        let targetWithDifferentGames=try await backup(root,originals:originals,menu:differentMenu,hwid:target)
        let differentGames=try plan.compareSaves(to:targetWithDifferentGames)
        #expect(differentGames.entries.map(\.gameMatch) == [.includedGame,.includedGame,.addedGameDifferent,.addedGameDifferent,.addedGameDifferent])
        let savePlan=try SNESReplacementSavePlan.prepare(replacement:plan,destination:targetWithGames,gameCodes:["CLV-U-A0001"])
        #expect(savePlan.files.map(\.path) == [directoryConflict,savedPath])
        #expect(try savePlan.read(path:savedPath) == Data([1,2,3]))
        #expect(throws:(any Error).self) {try savePlan.read(path:newPath)}
        #expect(throws:(any Error).self) {try SNESReplacementSavePlan.prepare(replacement:plan,destination:targetBackup,gameCodes:["CLV-U-A0001"])}
        #expect(throws:(any Error).self) {try SNESReplacementSavePlan.prepare(replacement:plan,destination:targetWithDifferentGames,gameCodes:["CLV-U-A0001"])}
        #expect(throws:(any Error).self) {try SNESReplacementSavePlan.prepare(replacement:plan,destination:targetWithGames,gameCodes:["CLV-U-ZZZZZ"])}
        let gameWithConflictingSave=try await backup(root,originals:originals,menu:menu,profileFiles:[savedPath:Data([7])],hwid:target)
        #expect(throws:(any Error).self) {try SNESReplacementSavePlan.prepare(replacement:plan,destination:gameWithConflictingSave,gameCodes:["CLV-U-A0001"])}
        #expect(throws:(any Error).self) {try plan.compareSaves(to:saved)}
        let targetBlobs=try FileManager.default.contentsOfDirectory(at:targetBackup.directory.appendingPathComponent("data-0"),includingPropertiesForKeys:nil)
        let changedTarget=try #require(targetBlobs.first { (try? Data(contentsOf:$0)) == Data([7]) })
        try Data([12]).write(to:changedTarget)
        #expect(throws:(any Error).self) {try comparison.validate()}
        try Data([7]).write(to:changedTarget)
        let sourceCheck=try plan.compareSaves(to:targetBackup)
        let blobs=try FileManager.default.contentsOfDirectory(at:saved.directory.appendingPathComponent("data-0"),includingPropertiesForKeys:nil)
        let saveBlob=try #require(blobs.first { (try? Data(contentsOf:$0)) == Data([1,2,3]) })
        try Data([9,9,9]).write(to:saveBlob)
        #expect(throws:(any Error).self) {try plan.readSave(path:savedPath)}
        #expect(throws:(any Error).self) {try sourceCheck.validate()}
        #expect(throws:(any Error).self) {try savePlan.validate()}
    }

    @Test(arguments: ["valid", "large", "empty", "space", "truncated", "truncated-body", "truncated-plan", "empty-stage", "before-plan", "after-plan", "missing-file", "gap", "short-gap", "incomplete-extra", "wrong-stage-challenge", "corrupt", "occupied", "linked", "game", "changed-selector", "staged-mutation", "plan-mutation", "extra", "foreign-device", "inspection-race"])
    func saveStageCopiesOnlyReviewedDataWithoutChangingLiveSaves(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryMaterialTests(), (library, originals) = try fixture.fixture(root), menu = try fixture.menu(library, originals)
        let base = "clover/profiles/0/CLV-U-A0001/", data = fault == "large" ? Data(repeating: 21, count: 524300) : (fault == "empty" ? Data() : Data([1, 2, 3])), hash = Data([4, 5])
        let source = try await backup(root, originals: originals, menu: menu, profileFiles: [base + "cartridge.sram": data, base + "cartridge.sram.hash": hash])
        let target = String(repeating: "2", count: 32), old = originalGamesBinding()
        var frame = originalGamesFrameFixture()
        let range = try #require(frame.range(of: Data(("HWID " + old.expectedHWID).utf8)))
        frame.replaceSubrange(range, with: Data(("HWID " + target).utf8))
        let binding = SNESRuntimeBinding(sourceSnapshot: old.sourceSnapshot, setupManifestSHA256: old.setupManifestSHA256, expectedHWID: target)
        let targetOriginals = try SNESOriginalGamesFrame(frame, binding: binding, challenge: originalGamesChallenge)
        let replacement = try SNESLibraryRestore.prepareReplacement(backup: source, originals: targetOriginals, destinationHWID: target)
        let destination = try await backup(root, originals: originals, menu: menu, hwid: target)
        let plan = try SNESReplacementSavePlan.prepare(replacement: replacement, destination: destination, gameCodes: ["CLV-U-A0001"])
        let review = try SNESReplacementSaveEnvelope.prepare(plan: plan), challenge = UUID(), id = UUID()
        let runtimeHash = String(repeating: "b", count: 64)
        let request = try SNESReplacementSaveStageCommands.prepare(review: review, group: 0, before: destination.inventory,
            runtimeSHA256: runtimeHash, challenge: challenge, stageID: id)
        let stream = try request.stream()
        #expect(stream.input == Data(request.script.trimmingCharacters(in: .newlines).utf8) + request.input)
        #expect(stream.command.utf8.count < 1020)
        let dataRoot = root.appendingPathComponent("fake-data"), runtime = root.appendingPathComponent("fake-runtime")
        let namespace = dataRoot.appendingPathComponent("swifthakchi/snes-v2"), stageRoot = namespace.appendingPathComponent("save-staging"), stage = stageRoot.appendingPathComponent(id.uuidString)
        for directory in [runtime, dataRoot.appendingPathComponent("clover/profiles/0/CLV-U-A0001"), namespace.appendingPathComponent("objects"), namespace.appendingPathComponent("menus"), namespace.appendingPathComponent("descriptions")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let sentinel = Data("existing progress stays".utf8), selector = try destination.read(path: "active-menu")
        let existing = dataRoot.appendingPathComponent("clover/profiles/0/CLV-U-A0001/existing")
        try sentinel.write(to: existing)
        let selectorPath = namespace.appendingPathComponent("active-menu")
        try (fault == "changed-selector" ? sentinel : selector).write(to: selectorPath)
        if fault == "occupied" {
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            try sentinel.write(to: stage.appendingPathComponent("foreign"))
        } else if fault == "linked" {
            try FileManager.default.createSymbolicLink(at: stageRoot, withDestinationURL: runtime)
        }
        let pin = try SNESLibraryCopyCommandsTests().makeRuntime(root: root, data: dataRoot, runtime: runtime, fault: fault)
        let actualRuntimeHash = BackupManifest.digest(try Data(contentsOf: runtime.appendingPathComponent("runtime-files.sha256")))
        var script = request.script.replacingOccurrences(of: "/mnt/swifthakchi", with: runtime.path)
            .replacingOccurrences(of: "/var/lib", with: dataRoot.path).replacingOccurrences(of: "/etc/clover", with: root.path)
            .replacingOccurrences(of: "/proc/mounts", with: root.appendingPathComponent("mounts").path)
            .replacingOccurrences(of: "440b72b46c50939356768f35ea02b682176ca49ef07b3702ee75912af74aabd6", with: pin)
            .replacingOccurrences(of: runtimeHash, with: actualRuntimeHash)
            .replacingOccurrences(of: "test \"$chip\" = '\(target)'", with: "test \"$chip\" = '\(String(repeating: "1", count: 32))'")
            .replacingOccurrences(of: "stat -L -c '%s' \"/proc/$$/fd/7\"", with: "stat -c '%s' \"$output\"")
        if fault == "staged-mutation" { script = script.replacingOccurrences(of: "\"$B\" sync\n", with: "printf damaged > \"$stage/0000\"\n\"$B\" sync\n") }
        if fault == "plan-mutation" { script = script.replacingOccurrences(of: "\"$B\" sync\n", with: "printf damaged > \"$stage/plan\"\n\"$B\" sync\n") }
        if fault == "extra" { script = script.replacingOccurrences(of: "\"$B\" sync\n", with: "printf foreign > \"$stage/foreign\"\n\"$B\" sync\n") }
        if fault == "gap" { script = script.replacingOccurrences(of: "\"$B\" sync\n", with: "\"$B\" rm \"$stage/0000\"\n\"$B\" sync\n") }
        if fault == "short-gap" { script = script.replacingOccurrences(of: "\"$B\" sync\n", with: "printf x > \"$stage/0000\"\n\"$B\" sync\n") }
        if fault == "before-plan" { script = script.replacingOccurrences(of: "test ! -e \"$stage/plan\"", with: "exit 1\ntest ! -e \"$stage/plan\"") }
        if fault == "after-plan" { script = script.replacingOccurrences(of: "exec 4< \"$stage/plan\"", with: "exit 1\nexec 4< \"$stage/plan\"") }
        if fault == "space" { script = script.replacingOccurrences(of: "space=$(\"$B\" stat -f -c '%S %b %a' \(dataRoot.path))", with: "space='4096 76800 0'") }
        var input = request.input
        if fault == "truncated" { input = input.prefix(input.count - 3) }
        if fault == "truncated-body" || fault == "incomplete-extra" { input = input.prefix(request.tableBytes + 1) }
        if fault == "truncated-plan" { input = input.prefix(request.tableBytes - 1) }
        if fault == "empty-stage" { input = Data() }
        if fault == "missing-file" { input = input.prefix(request.tableBytes + data.count) }
        if fault == "corrupt" { input[request.tableBytes] ^= 1 }
        let inputPath = root.appendingPathComponent("save-input"), scriptPath = root.appendingPathComponent("save-stage.sh")
        try input.write(to: inputPath); try Data(script.utf8).write(to: scriptPath)
        let process = Process(), out = Pipe(), err = Pipe(), handle = try FileHandle(forReadingFrom: inputPath)
        defer { try? handle.close() }
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [scriptPath.path]
        process.standardInput = handle; process.standardOutput = out; process.standardError = err
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: deadline); defer { deadline.cancel() }
        let reply = out.fileHandleForReading.readDataToEndOfFile(), errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if fault == "incomplete-extra" { try Data("foreign".utf8).write(to: stage.appendingPathComponent("foreign")) }
        if fault == "wrong-stage-challenge" {
            let planPath = stage.appendingPathComponent("plan")
            let plan = try String(contentsOf: planPath, encoding: .utf8)
            try plan.replacingOccurrences(of: challenge.uuidString, with: UUID().uuidString).write(to: planPath, atomically: false, encoding: .utf8)
        }
        #expect(try Data(contentsOf: existing) == sentinel)
        #expect(try Data(contentsOf: selectorPath) == (fault == "changed-selector" ? sentinel : selector))
        if ["valid", "large", "empty", "inspection-race", "wrong-stage-challenge"].contains(fault) {
            #expect(process.terminationStatus == 0, "\(String(decoding: errors, as: UTF8.self))")
            _ = try SNESReplacementSaveStageReceipt(reply, request: request)
            #expect(try Data(contentsOf: stage.appendingPathComponent("0000")) == data)
            #expect(try Data(contentsOf: stage.appendingPathComponent("0001")) == hash)
        } else {
            #expect(process.terminationStatus != 0)
            #expect(throws: (any Error).self) { try SNESReplacementSaveStageReceipt(reply, request: request) }
            if fault == "occupied" { #expect(try Data(contentsOf: stage.appendingPathComponent("foreign")) == sentinel) }
        }
        if ["valid", "space", "truncated-body", "truncated-plan", "empty-stage", "before-plan", "after-plan", "missing-file", "gap", "short-gap", "incomplete-extra", "wrong-stage-challenge", "corrupt", "occupied", "linked", "extra", "staged-mutation", "plan-mutation", "inspection-race"].contains(fault) {
            func stageSnapshot() throws -> [String: Data]? {
                guard FileManager.default.fileExists(atPath: stage.path) else { return nil }
                let names = try FileManager.default.contentsOfDirectory(atPath: stage.path)
                return try Dictionary(uniqueKeysWithValues: names.map { ($0, try Data(contentsOf: stage.appendingPathComponent($0))) })
            }
            let beforeInspection = try stageSnapshot()
            let inspect = try SNESReplacementSaveStageInspection.prepare(review: review, group: 0, before: destination.inventory,
                runtimeSHA256: runtimeHash, challenge: UUID(), stageID: id, stagedChallenge: challenge)
            try inspect.requireBinding(contextSHA256: destination.inventory.contextSHA256, hwid: target, runtimeSHA256: runtimeHash)
            try inspect.requireInventory(destination.inventory)
            #expect(throws: (any Error).self) { try inspect.requireInventory(source.inventory) }
            #expect(throws: (any Error).self) {
                try inspect.requireBinding(contextSHA256: destination.inventory.contextSHA256, hwid: String(repeating: "3", count: 32), runtimeSHA256: runtimeHash)
            }
            if fault == "valid" {
                var sends = 0
                let result = try await SNESReplacementSaveStageInspection.dispatch(inspect,
                    contextSHA256: destination.inventory.contextSHA256, hwid: target, runtimeSHA256: runtimeHash) { request in
                        sends += 1; return request.absent
                    }
                #expect(result == .absent && sends == 1)
                await #expect(throws: (any Error).self) {
                    try await SNESReplacementSaveStageInspection.dispatch(inspect,
                        contextSHA256: destination.inventory.contextSHA256, hwid: String(repeating: "3", count: 32), runtimeSHA256: runtimeHash) { _ in
                            sends += 1; return inspect.absent
                        }
                }
                #expect(sends == 1)
                await #expect(throws: (any Error).self) {
                    try await SNESReplacementSaveStageInspection.dispatch(inspect,
                        contextSHA256: destination.inventory.contextSHA256, hwid: target, runtimeSHA256: runtimeHash) { _ in Data("bad".utf8) }
                }
            }
            let inspectStream = try inspect.stream()
            #expect(inspectStream.input == Data(inspect.script.trimmingCharacters(in: .newlines).utf8) + inspect.input)
            var inspectScript = inspect.script.replacingOccurrences(of: "/mnt/swifthakchi", with: runtime.path)
                .replacingOccurrences(of: "/var/lib", with: dataRoot.path).replacingOccurrences(of: "/etc/clover", with: root.path)
                .replacingOccurrences(of: "/proc/mounts", with: root.appendingPathComponent("mounts").path)
                .replacingOccurrences(of: "440b72b46c50939356768f35ea02b682176ca49ef07b3702ee75912af74aabd6", with: pin)
                .replacingOccurrences(of: runtimeHash, with: actualRuntimeHash)
                .replacingOccurrences(of: "test \"$chip\" = '\(target)'", with: "test \"$chip\" = '\(String(repeating: "1", count: 32))'")
            if fault == "inspection-race" {
                inspectScript = inspectScript.replacingOccurrences(of: "value=$(\"$B\" sha256sum \"$file\")\n", with: "value=$(\"$B\" sha256sum \"$file\");printf changed > \"$file\"\n")
            }
            let inspectPath = root.appendingPathComponent("inspect.sh"), inspectInput = root.appendingPathComponent("inspect-input")
            try Data(inspectScript.utf8).write(to: inspectPath); try inspect.input.write(to: inspectInput)
            let inspector = Process(), inspectOut = Pipe(), inspectErr = Pipe(), inspectHandle = try FileHandle(forReadingFrom: inspectInput)
            defer { try? inspectHandle.close() }
            inspector.executableURL = URL(fileURLWithPath: "/bin/sh"); inspector.arguments = [inspectPath.path]
            inspector.standardInput = inspectHandle; inspector.standardOutput = inspectOut; inspector.standardError = inspectErr
            try inspector.run()
            let timeout = DispatchWorkItem { if inspector.isRunning { inspector.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout); defer { timeout.cancel() }
            let observation = inspectOut.fileHandleForReading.readDataToEndOfFile(), details = inspectErr.fileHandleForReading.readDataToEndOfFile()
            inspector.waitUntilExit()
            #expect(try Data(contentsOf: existing) == sentinel)
            if fault != "inspection-race" { #expect(try stageSnapshot() == beforeInspection) }
            if fault == "valid" {
                #expect(inspector.terminationStatus == 0, "\(String(decoding: details, as: UTF8.self))")
                #expect(try SNESReplacementSaveStageInspectionReceipt(observation, request: inspect).outcome == .verified)
            } else if fault == "space" {
                #expect(inspector.terminationStatus == 0, "\(String(decoding: details, as: UTF8.self))")
                #expect(try SNESReplacementSaveStageInspectionReceipt(observation, request: inspect).outcome == .absent)
            } else if ["truncated-body", "truncated-plan", "empty-stage", "before-plan", "after-plan", "missing-file"].contains(fault) {
                #expect(inspector.terminationStatus == 0, "\(String(decoding: details, as: UTF8.self))")
                #expect(String(decoding: observation, as: UTF8.self).contains("\nSTATUS INCOMPLETE\n"))
                _ = try SNESReplacementSaveStageInspectionReceipt(observation, request: inspect)
            } else {
                #expect(inspector.terminationStatus != 0)
                #expect(throws: (any Error).self) { try SNESReplacementSaveStageInspectionReceipt(observation, request: inspect) }
            }
        }
    }

    @Test(arguments: ProcessInfo.processInfo.environment["SNES_PUBLICATION_TEST_CASE"].map { [$0] } ?? ["valid", "suspend", "occupied", "symlink", "bad-stage", "wrong-stage", "selector", "no-space", "ready-tamper", "destination-race", "extra-after-rename", "interrupted-before-rename", "interrupted-after-rename", "helper-missing", "helper-changed", "game", "slot-valid", "slot-occupied", "slot-prior-tamper", "slot-prior-race", "slot-profile-mode", "slot-interrupted-before", "slot-interrupted-after"])
    func newProfilePublicationKeepsExistingProgressAndPublishesWholeSave(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryMaterialTests(), (library, originals) = try fixture.fixture(root), menu = try fixture.menu(library, originals)
        let code = "CLV-U-A0001", base = "clover/profiles/0/\(code)/", save = Data([1, 2, 3]), hash = Data([4, 5])
        let isSlot = fault.hasPrefix("slot-")
        let contents: [String: Data] = fault == "suspend" || isSlot ? [
            "suspendpoint1/state.png": Data([10]), "suspendpoint1/state.time": Data([11]),
            "suspendpoint1/rollback/sram.hash": Data([12]), "suspendpoint1/rollback/0.break": Data([13])
        ] : ["cartridge.sram": save, "cartridge.sram.hash": hash]
        let profileFiles = Dictionary(uniqueKeysWithValues: contents.map { (base + $0.key, $0.value) })
        let priorFiles = [base + "cartridge.sram": Data([21, 22]), base + "cartridge.sram.hash": Data([23])]
        let source = try await backup(root, originals: originals, menu: menu,
            profileFiles: isSlot ? profileFiles.merging(priorFiles) { _, new in new } : profileFiles, profileModified: 1700000000)
        let target = String(repeating: "2", count: 32), old = originalGamesBinding()
        var frame = originalGamesFrameFixture()
        let range = try #require(frame.range(of: Data(("HWID " + old.expectedHWID).utf8)))
        frame.replaceSubrange(range, with: Data(("HWID " + target).utf8))
        let binding = SNESRuntimeBinding(sourceSnapshot: old.sourceSnapshot, setupManifestSHA256: old.setupManifestSHA256, expectedHWID: target)
        let targetOriginals = try SNESOriginalGamesFrame(frame, binding: binding, challenge: originalGamesChallenge)
        let replacement = try SNESLibraryRestore.prepareReplacement(backup: source, originals: targetOriginals, destinationHWID: target)
        let destination = try await backup(root, originals: originals, menu: menu, profileFiles: isSlot ? priorFiles : [:],
                                           profileModified: isSlot ? 1700000000 : 0, hwid: target)
        let plan = try SNESReplacementSavePlan.prepare(replacement: replacement, destination: destination, gameCodes: [code])
        let review = try SNESReplacementSaveEnvelope.prepare(plan: plan), stageID = UUID(), stagedChallenge = UUID(), challenge = UUID()
        let runtimeHash = String(repeating: "b", count: 64)
        let dataRoot = root.appendingPathComponent("fake-data"), runtime = root.appendingPathComponent("fake-runtime")
        let namespace = dataRoot.appendingPathComponent("swifthakchi/snes-v2"), stage = namespace.appendingPathComponent("save-staging/" + stageID.uuidString)
        let profiles = dataRoot.appendingPathComponent("clover/profiles/0"), targetPath = profiles.appendingPathComponent(code)
        let publicationTarget = isSlot ? targetPath.appendingPathComponent("suspendpoint1") : targetPath
        let helperText = "#!/bin/sh\n[ \"$#\" = \(isSlot ? 9 : 6) ] || exit 1\nexec /usr/bin/python3 -c 'import os,sys;os.rename(sys.argv[1],sys.argv[2]);print(\"PROFILE_SWITCHED\")' \"\(stage.path)/publication\" \"\(publicationTarget.path)\"\n"
        let helperHash = BackupManifest.digest(Data(helperText.utf8))
        if fault == "valid" {
            let existing = try await backup(root, originals: originals, menu: menu,
                profileFiles: [base + "save/system-save.json/data": Data([6]), base + "save/system-save.json/hash": Data([7])], hwid: target)
            let existingPlan = try SNESReplacementSavePlan.prepare(replacement: replacement, destination: existing, gameCodes: [code])
            let existingReview = try SNESReplacementSaveEnvelope.prepare(plan: existingPlan)
            #expect(throws: (any Error).self) {
                try SNESReplacementSaveProfilePublication.prepare(review: existingReview, group: 0, before: existing.inventory,
                    runtimeSHA256: runtimeHash, switcherSHA256: helperHash, challenge: challenge, stageID: stageID, stagedChallenge: stagedChallenge)
            }
        }
        let request = try SNESReplacementSaveProfilePublication.prepare(review: review, group: 0, before: destination.inventory,
            runtimeSHA256: runtimeHash, switcherSHA256: helperHash, challenge: challenge, stageID: stageID, stagedChallenge: stagedChallenge)
        let payload = try SNESReplacementSavePayload.prepare(review: review, group: 0, challenge: stagedChallenge)
        // Optional export contains only this test's synthetic save data. It is
        // used by the isolated ARM test; it never contacts a real console.
        let fixtureKey = isSlot ? "SNES_PUBLICATION_ARM_FIXTURE_SLOT" : (fault == "suspend" ? "SNES_PUBLICATION_ARM_FIXTURE_SUSPEND" : "SNES_PUBLICATION_ARM_FIXTURE")
        if ["valid", "suspend", "slot-valid"].contains(fault), let directory = ProcessInfo.processInfo.environment[fixtureKey],
           let armHelperHash = ProcessInfo.processInfo.environment["SNES_PUBLICATION_ARM_HELPER_SHA"] {
            let exported = try SNESReplacementSaveProfilePublication.prepare(review: review, group: 0, before: destination.inventory,
                runtimeSHA256: runtimeHash, switcherSHA256: armHelperHash, challenge: challenge, stageID: stageID, stagedChallenge: stagedChallenge)
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try Data(exported.script.utf8).write(to: output.appendingPathComponent("script"))
            try exported.receipt.write(to: output.appendingPathComponent("receipt"))
            try payload.table.write(to: output.appendingPathComponent("plan"))
            try Data(stageID.uuidString.utf8).write(to: output.appendingPathComponent("stage-id"))
            try destination.read(path: "active-menu").write(to: output.appendingPathComponent("selector"))
            var mapping: [String: String] = [:]
            for (index, name) in contents.keys.sorted().enumerated() {
                let stagedName = String(format: "%04d", index)
                mapping[name] = stagedName
                try #require(contents[name]).write(to: output.appendingPathComponent(stagedName))
            }
            try JSONSerialization.data(withJSONObject: mapping, options: [.sortedKeys]).write(to: output.appendingPathComponent("mapping.json"))
            if isSlot {
                try Data("slot".utf8).write(to: output.appendingPathComponent("kind"))
                try Data([21, 22]).write(to: output.appendingPathComponent("prior-sram"))
                try Data([23]).write(to: output.appendingPathComponent("prior-hash"))
            }
        }
        for dir in [runtime, profiles, namespace.appendingPathComponent("objects"), namespace.appendingPathComponent("menus"), stage] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let unrelated = profiles.appendingPathComponent("CLV-U-ZZZZZ")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        let unrelatedFile = unrelated.appendingPathComponent("cartridge.sram"), unrelatedContent = Data("existing unrelated save".utf8)
        try unrelatedContent.write(to: unrelatedFile)
        try (fault == "selector" ? Data("changed".utf8) : destination.read(path: "active-menu")).write(to: namespace.appendingPathComponent("active-menu"))
        let stagePlan = fault == "wrong-stage" ? try SNESReplacementSavePayload.prepare(review: review, group: 0, challenge: UUID()).table : payload.table
        try stagePlan.write(to: stage.appendingPathComponent("plan"))
        for (index, name) in contents.keys.sorted().enumerated() {
            let data = fault == "bad-stage" && index == 0 ? Data([9]) : try #require(contents[name])
            try data.write(to: stage.appendingPathComponent(String(format: "%04d", index)))
        }
        let sentinel = Data("do not change".utf8)
        if isSlot {
            try FileManager.default.createDirectory(at: targetPath, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: targetPath.path)
            for (path, data) in priorFiles {
                let file = targetPath.appendingPathComponent(String(path.dropFirst(base.count)))
                try data.write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o600, .modificationDate: Date(timeIntervalSince1970: 1700000000)], ofItemAtPath: file.path)
            }
            if fault == "slot-occupied" {
                try FileManager.default.createDirectory(at: publicationTarget, withIntermediateDirectories: false)
                try sentinel.write(to: publicationTarget.appendingPathComponent("existing"))
            }
            if fault == "slot-prior-tamper" { try Data([99]).write(to: targetPath.appendingPathComponent("cartridge.sram")) }
            if fault == "slot-profile-mode" { try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: targetPath.path) }
        }
        if fault == "occupied" {
            try FileManager.default.createDirectory(at: targetPath, withIntermediateDirectories: false)
            try sentinel.write(to: targetPath.appendingPathComponent("existing"))
        } else if fault == "symlink" {
            try FileManager.default.createSymbolicLink(at: targetPath, withDestinationURL: runtime)
        }
        _ = try SNESLibraryCopyCommandsTests().makeRuntime(root: root, data: dataRoot, runtime: runtime, fault: fault)
        if fault != "helper-missing" {
            let helper = runtime.appendingPathComponent("snes-save-profile-switch")
            try Data((fault == "helper-changed" ? "changed" : helperText).utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        }
        let busybox = runtime.appendingPathComponent("busybox"), runtimeList = runtime.appendingPathComponent("runtime-files.sha256")
        var shim = try String(contentsOf: busybox, encoding: .utf8)
        shim = shim.replacingOccurrences(of: "      %s) exec /usr/bin/stat -f '%z' \"$4\";;", with: "      %s) exec /usr/bin/stat -f '%z' \"$4\";;\n      '%d %s') exec /usr/bin/stat -f '%d %z' \"$4\";;\n      '%d %s %Y %a') exec /usr/bin/stat -f '%d %z %m %Lp' \"$4\";;")
        try Data(shim.utf8).write(to: busybox)
        let pin = BackupManifest.digest(Data(shim.utf8))
        try Data((pin + "  " + busybox.path + "\n").utf8).write(to: runtimeList)
        let actualRuntimeHash = BackupManifest.digest(try Data(contentsOf: runtimeList))
        var script = request.script.replacingOccurrences(of: "/mnt/swifthakchi", with: runtime.path)
            .replacingOccurrences(of: "/var/lib", with: dataRoot.path).replacingOccurrences(of: "/etc/clover", with: root.path)
            .replacingOccurrences(of: "/proc/mounts", with: root.appendingPathComponent("mounts").path)
            .replacingOccurrences(of: "440b72b46c50939356768f35ea02b682176ca49ef07b3702ee75912af74aabd6", with: pin)
            .replacingOccurrences(of: runtimeHash, with: actualRuntimeHash)
            .replacingOccurrences(of: "test \"$chip\" = '\(target)'", with: "test \"$chip\" = '\(String(repeating: "1", count: 32))'")
        if fault == "interrupted-before-rename" || fault == "slot-interrupted-before" {
            script = script.replacingOccurrences(of: "result=$(\"$H\" ", with: "exit 99\nresult=$(\"$H\" ")
        }
        if fault == "interrupted-after-rename" || fault == "slot-interrupted-after" {
            script = script.replacingOccurrences(of: "test \"$result\" = PROFILE_SWITCHED\n", with: "test \"$result\" = PROFILE_SWITCHED\nexit 98\n")
        }
        if fault == "ready-tamper" {
            script = script.replacingOccurrences(of: "\"$B\" sync\n", with: "printf x > \"$ready/cartridge.sram\"\n\"$B\" sync\n")
        }
        if fault == "no-space" {
            script = script.replacingOccurrences(of: "space=$(\"$B\" stat -f -c '%S %b %a' \(dataRoot.path))", with: "space='4096 76800 0'")
        }
        if fault == "destination-race" {
            script = script.replacingOccurrences(of: "result=$(\"$H\" ", with: "printf other > \"$target/other\"\nresult=$(\"$H\" ")
        }
        if fault == "slot-prior-race" {
            script = script.replacingOccurrences(of: "verify_ready;roots;current_selection;no_game;verify_existing 1", with: "printf changed > \"$parent/cartridge.sram\"\nverify_ready;roots;current_selection;no_game;verify_existing 1")
        }
        if fault == "extra-after-rename" {
            script = script.replacingOccurrences(of: "test \"$result\" = PROFILE_SWITCHED\n", with: "test \"$result\" = PROFILE_SWITCHED\nprintf foreign > \"$target/foreign\"\n")
        }
        let path = root.appendingPathComponent("publish.sh"); try Data(script.utf8).write(to: path)
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [path.path]
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: deadline); defer { deadline.cancel() }
        let reply = output.fileHandleForReading.readDataToEndOfFile(), error = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(try Data(contentsOf: unrelatedFile) == unrelatedContent)
        for (index, name) in contents.keys.sorted().enumerated() where fault != "bad-stage" || index != 0 {
            #expect(try Data(contentsOf: stage.appendingPathComponent(String(format: "%04d", index))) == contents[name])
        }
        if fault == "valid" || fault == "suspend" || fault == "slot-valid" {
            #expect(process.terminationStatus == 0, "\(String(decoding: error, as: UTF8.self))")
            #expect(reply == request.receipt)
            for (name, data) in contents {
                let file = targetPath.appendingPathComponent(name)
                #expect(try Data(contentsOf: file) == data)
                let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
                #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
                #expect((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 == 1700000000)
            }
        } else {
            #expect(process.terminationStatus != 0)
            if fault == "occupied" { #expect(try Data(contentsOf: targetPath.appendingPathComponent("existing")) == sentinel) }
            if fault == "symlink" { #expect(try FileManager.default.destinationOfSymbolicLink(atPath: targetPath.path) == runtime.path) }
            if fault == "interrupted-before-rename" {
                #expect(try FileManager.default.contentsOfDirectory(atPath: targetPath.path).isEmpty)
                #expect(try Data(contentsOf: stage.appendingPathComponent("publication/cartridge.sram")) == save)
            }
            if fault == "interrupted-after-rename" {
                #expect(try Data(contentsOf: targetPath.appendingPathComponent("cartridge.sram")) == save)
                #expect(try Data(contentsOf: targetPath.appendingPathComponent("cartridge.sram.hash")) == hash)
                #expect(reply.isEmpty)
            }
            if fault == "ready-tamper" {
                #expect(!FileManager.default.fileExists(atPath: targetPath.appendingPathComponent("cartridge.sram").path))
            }
            if fault == "no-space" {
                #expect(!FileManager.default.fileExists(atPath: stage.appendingPathComponent("publication").path))
                #expect(!FileManager.default.fileExists(atPath: targetPath.path))
            }
            if fault == "helper-missing" || fault == "helper-changed" { #expect(!FileManager.default.fileExists(atPath: targetPath.path)) }
            if fault == "destination-race" { #expect(try Data(contentsOf: targetPath.appendingPathComponent("other")) == Data("other".utf8)) }
            if fault == "extra-after-rename" { #expect(try Data(contentsOf: targetPath.appendingPathComponent("foreign")) == Data("foreign".utf8)) }
            if fault == "slot-occupied" { #expect(try Data(contentsOf: publicationTarget.appendingPathComponent("existing")) == sentinel) }
            if fault == "slot-prior-tamper" { #expect(try Data(contentsOf: targetPath.appendingPathComponent("cartridge.sram")) == Data([99])) }
            if fault == "slot-prior-race" { #expect(try Data(contentsOf: targetPath.appendingPathComponent("cartridge.sram")) == Data("changed".utf8)) }
            if fault == "slot-profile-mode" { #expect(!FileManager.default.fileExists(atPath: stage.appendingPathComponent("publication").path)) }
            if fault == "slot-interrupted-before" {
                #expect(try FileManager.default.contentsOfDirectory(atPath: publicationTarget.path).isEmpty)
                #expect(try Data(contentsOf: stage.appendingPathComponent("publication/state.png")) == Data([10]))
            }
            if fault == "slot-interrupted-after" { #expect(try Data(contentsOf: publicationTarget.appendingPathComponent("state.png")) == Data([10])) }
        }
        if isSlot && fault != "slot-prior-tamper" && fault != "slot-prior-race" {
            #expect(try Data(contentsOf: targetPath.appendingPathComponent("cartridge.sram")) == Data([21, 22]))
            #expect(try Data(contentsOf: targetPath.appendingPathComponent("cartridge.sram.hash")) == Data([23]))
        }
    }

    @Test(arguments: [false, true])
    func newProfileRecoveryDistinguishesReservationPublicationAndConflicts(_ suspend: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryMaterialTests(), (library, originals) = try fixture.fixture(root), menu = try fixture.menu(library, originals)
        let code = "CLV-U-A0001", base = "clover/profiles/0/\(code)/", save = Data([1, 2, 3]), hash = Data([4, 5])
        let files: [String: Data] = suspend ? [
            base + "suspendpoint1/state.png": Data([10]), base + "suspendpoint1/state.time": Data([11]),
            base + "suspendpoint1/rollback/sram.hash": Data([12]), base + "suspendpoint1/rollback/0.break": Data([13])
        ] : [base + "cartridge.sram": save, base + "cartridge.sram.hash": hash]
        let source = try await backup(root, originals: originals, menu: menu, profileFiles: files)
        let target = String(repeating: "2", count: 32), old = originalGamesBinding()
        var frame = originalGamesFrameFixture()
        let range = try #require(frame.range(of: Data(("HWID " + old.expectedHWID).utf8)))
        frame.replaceSubrange(range, with: Data(("HWID " + target).utf8))
        let binding = SNESRuntimeBinding(sourceSnapshot: old.sourceSnapshot, setupManifestSHA256: old.setupManifestSHA256, expectedHWID: target)
        let targetOriginals = try SNESOriginalGamesFrame(frame, binding: binding, challenge: originalGamesChallenge)
        let replacement = try SNESLibraryRestore.prepareReplacement(backup: source, originals: targetOriginals, destinationHWID: target)
        let before = try await backup(root, originals: originals, menu: menu, hwid: target)
        let plan = try SNESReplacementSavePlan.prepare(replacement: replacement, destination: before, gameCodes: [code])
        let review = try SNESReplacementSaveEnvelope.prepare(plan: plan)
        let reserved = try await backup(root, originals: originals, menu: menu, profileDirectories: [String(base.dropLast())], hwid: target)
        let complete = try await backup(root, originals: originals, menu: menu, profileFiles: files, hwid: target)
        let firstPath = try #require(files.keys.sorted().first), firstData = try #require(files[firstPath])
        let partial = try await backup(root, originals: originals, menu: menu, profileFiles: [firstPath: firstData], hwid: target)
        let conflicting = try await backup(root, originals: originals, menu: menu, profileFiles: [firstPath: Data([99])], hwid: target)
        let unrelated = try await backup(root, originals: originals, menu: menu,
            profileFiles: [firstPath: firstData, "clover/profiles/0/CLV-U-ZZZZZ/cartridge.sram": save], hwid: target)
        if !suspend {
            let journalRoot = root.appendingPathComponent("profile-journals")
            try FileManager.default.createDirectory(at: journalRoot, withIntermediateDirectories: false)
            let prepared = try SNESReplacementSaveJournal.prepare(review: review, root: journalRoot)
            let journal = try SNESReplacementSaveJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, originals: targetOriginals)
            let runtime = String(repeating: "b", count: 64), stageChallenge = UUID(), publishChallenge = UUID()
            _ = try await journal.recordStageIntent(group: 0, before: before.inventory, runtimeSHA256: runtime, challenge: stageChallenge, approved: true)
            let recorded = try #require(try await journal.recordedStage())
            await #expect(throws: (any Error).self) {
                try await journal.prepareProfilePublication(group: 0, before: before.inventory, runtimeSHA256: runtime, switcherSHA256: String(repeating: "d", count: 64), challenge: publishChallenge)
            }
            try await journal.markUncertain()
            // Reconnecting creates a fresh session context even when the
            // same console and its saved files are unchanged.
            let freshContext = String(repeating: "e", count: 64)
            let reboundFrame = Data(String(decoding: before.inventory.rawFrame, as: UTF8.self)
                .replacingOccurrences(of: "CONTEXT " + before.inventory.contextSHA256, with: "CONTEXT " + freshContext).utf8)
            let rebound = try SNESLibraryInventory(raw: reboundFrame, challenge: before.inventory.challenge, contextSHA256: freshContext,
                hwid: before.inventory.hwid, catalogSHA256: before.inventory.catalogSHA256)
            #expect(rebound.stateSHA256 == before.inventory.stateSHA256 && rebound.contextSHA256 != before.inventory.contextSHA256)
            _ = try await journal.prepareStageInspection(group: 0, before: rebound, runtimeSHA256: runtime, challenge: UUID())
            await #expect(throws: (any Error).self) {
                try await journal.prepareStageInspection(group: 0, before: partial.inventory, runtimeSHA256: runtime, challenge: UUID())
            }
            await #expect(throws: (any Error).self) {
                try await journal.prepareStageInspection(group: 0, before: rebound, runtimeSHA256: String(repeating: "c", count: 64), challenge: UUID())
            }
            await #expect(throws: (any Error).self) { try await journal.inspectProfilePublication(observed: before.inventory) }
            let request = try await journal.prepareProfilePublication(group: 0, before: before.inventory, runtimeSHA256: runtime, switcherSHA256: String(repeating: "d", count: 64), challenge: publishChallenge)
            #expect(String(decoding: request.receipt, as: UTF8.self).contains("\nSTAGE \(recorded.stageID.uuidString)\n"))
            #expect(String(decoding: request.receipt, as: UTF8.self).contains("\nHELPER \(String(repeating: "d", count: 64))\n"))
            let otherHelper = try await journal.prepareProfilePublication(group: 0, before: before.inventory, runtimeSHA256: runtime, switcherSHA256: String(repeating: "e", count: 64), challenge: publishChallenge)
            #expect(otherHelper.receipt != request.receipt && otherHelper.script != request.script)
            await #expect(throws: (any Error).self) {
                try await journal.prepareProfilePublication(group: 0, before: before.inventory, runtimeSHA256: runtime, switcherSHA256: "invalid", challenge: publishChallenge)
            }
            await #expect(throws: (any Error).self) {
                try await journal.prepareProfilePublication(group: 1, before: before.inventory, runtimeSHA256: runtime, switcherSHA256: String(repeating: "d", count: 64), challenge: publishChallenge)
            }
            await #expect(throws: (any Error).self) {
                try await journal.prepareProfilePublication(group: 0, before: before.inventory, runtimeSHA256: String(repeating: "c", count: 64), switcherSHA256: String(repeating: "d", count: 64), challenge: publishChallenge)
            }
            await #expect(throws: (any Error).self) {
                try await journal.recordProfilePublicationIntent(group: 0, before: before.inventory, runtimeSHA256: runtime,
                    switcherSHA256: String(repeating: "d", count: 64), challenge: publishChallenge, approved: false)
            }
            #expect(try await journal.phase() == .uncertain)
            try await journal.recordProfilePublicationIntent(group: 0, before: before.inventory, runtimeSHA256: runtime,
                switcherSHA256: String(repeating: "d", count: 64), challenge: publishChallenge, approved: true)
            #expect(try await journal.phase() == .publicationIntent)
            #expect(try await journal.inspectProfilePublication(observed: before.inventory) == .absent)
            #expect(try await journal.inspectProfilePublication(observed: rebound) == .absent)
            #expect(try await journal.inspectProfilePublication(observed: reserved.inventory) == .reserved)
            #expect(try await journal.inspectProfilePublication(observed: complete.inventory) == .published)
            let freshCompleteFrame = Data(String(decoding: complete.inventory.rawFrame, as: UTF8.self)
                .replacingOccurrences(of: "CONTEXT " + complete.inventory.contextSHA256, with: "CONTEXT " + freshContext).utf8)
            let freshComplete = try SNESLibraryInventory(raw: freshCompleteFrame, challenge: complete.inventory.challenge,
                contextSHA256: freshContext, hwid: complete.inventory.hwid, catalogSHA256: complete.inventory.catalogSHA256)
            #expect(try await journal.inspectProfilePublication(observed: freshComplete) == .published)
            #expect(try await journal.inspectProfilePublication(observed: partial.inventory) == .needsReview)
            await #expect(throws: (any Error).self) { try await journal.inspectProfilePublication(observed: unrelated.inventory) }
            await #expect(throws: (any Error).self) {
                try await journal.recordProfilePublicationIntent(group: 0, before: before.inventory, runtimeSHA256: runtime,
                    switcherSHA256: String(repeating: "d", count: 64), challenge: publishChallenge, approved: true)
            }
            try await journal.close()
            #expect(throws: (any Error).self) { try SNESLibraryJournal.firmwareLease(hwid: target, root: journalRoot) }
            #expect(throws: (any Error).self) { try SNESLibraryJournal.backupDeletionLease(directory: source.directory, root: journalRoot) }
            let interrupted = try SNESReplacementSaveJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, originals: targetOriginals)
            #expect(try await interrupted.phase() == .publicationIntent)
            #expect(try await interrupted.inspectProfilePublication(observed: reserved.inventory) == .reserved)
            try await interrupted.markProfilePublicationUncertain()
            #expect(try await interrupted.phase() == .publicationUncertain)
            try await interrupted.close()
            let reopened = try SNESReplacementSaveJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, originals: targetOriginals)
            #expect(try await reopened.phase() == .publicationUncertain)
            #expect(try await reopened.inspectProfilePublication(observed: complete.inventory) == .published)
            await #expect(throws: (any Error).self) { try await reopened.markProfilePublicationUncertain() }
            await #expect(throws: (any Error).self) {
                try await reopened.recordProfilePublicationIntent(group: 0, before: before.inventory, runtimeSHA256: runtime,
                    switcherSHA256: String(repeating: "d", count: 64), challenge: publishChallenge, approved: true)
            }
            let again = try await reopened.prepareProfilePublication(group: 0, before: before.inventory, runtimeSHA256: runtime, switcherSHA256: String(repeating: "d", count: 64), challenge: publishChallenge)
            #expect(again.script == request.script && again.receipt == request.receipt)
            await #expect(throws: (any Error).self) {
                try await reopened.prepareProfilePublication(group: 0, before: before.inventory, runtimeSHA256: runtime,
                    switcherSHA256: String(repeating: "e", count: 64), challenge: publishChallenge)
            }
            await #expect(throws: (any Error).self) {
                try await reopened.prepareProfilePublication(group: 0, before: before.inventory, runtimeSHA256: runtime,
                    switcherSHA256: String(repeating: "d", count: 64), challenge: UUID())
            }
            try await reopened.close()
        }
        #expect(try SNESReplacementSaveProfileRecovery.inspect(review: review, group: 0, observed: before.inventory) == .absent)
        #expect(try SNESReplacementSaveProfileRecovery.inspect(review: review, group: 0, observed: reserved.inventory) == .reserved)
        #expect(try SNESReplacementSaveProfileRecovery.inspect(review: review, group: 0, observed: complete.inventory) == .published)
        #expect(try SNESReplacementSaveProfileRecovery.inspect(review: review, group: 0, observed: partial.inventory) == .needsReview)
        #expect(try SNESReplacementSaveProfileRecovery.inspect(review: review, group: 0, observed: conflicting.inventory) == .needsReview)
        #expect(throws: (any Error).self) { try SNESReplacementSaveProfileRecovery.inspect(review: review, group: 0, observed: unrelated.inventory) }
        #expect(throws: (any Error).self) { try SNESReplacementSaveProfileRecovery.inspect(review: review, group: 0, observed: source.inventory) }
        #expect(throws: (any Error).self) { try SNESReplacementSaveProfileRecovery.inspect(review: review, group: 1, observed: before.inventory) }
    }

    @Test func existingProfileSlotRecoveryKeepsTheExistingSave() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryMaterialTests(), (library, originals) = try fixture.fixture(root), menu = try fixture.menu(library, originals)
        let code = "CLV-U-A0001", base = "clover/profiles/0/\(code)/"
        let existing = [base + "cartridge.sram": Data([1, 2]), base + "cartridge.sram.hash": Data([3])]
        let slot = [base + "suspendpoint1/state.png": Data([4]), base + "suspendpoint1/state.time": Data([5]),
                    base + "suspendpoint1/rollback/sram.hash": Data([6]), base + "suspendpoint1/rollback/0.break": Data([7])]
        let source = try await backup(root, originals: originals, menu: menu, profileFiles: existing.merging(slot) { _, new in new })
        let target = String(repeating: "2", count: 32), old = originalGamesBinding()
        var frame = originalGamesFrameFixture()
        let range = try #require(frame.range(of: Data(("HWID " + old.expectedHWID).utf8)))
        frame.replaceSubrange(range, with: Data(("HWID " + target).utf8))
        let binding = SNESRuntimeBinding(sourceSnapshot: old.sourceSnapshot, setupManifestSHA256: old.setupManifestSHA256, expectedHWID: target)
        let targetOriginals = try SNESOriginalGamesFrame(frame, binding: binding, challenge: originalGamesChallenge)
        let replacement = try SNESLibraryRestore.prepareReplacement(backup: source, originals: targetOriginals, destinationHWID: target)
        let before = try await backup(root, originals: originals, menu: menu, profileFiles: existing, hwid: target)
        let plan = try SNESReplacementSavePlan.prepare(replacement: replacement, destination: before, gameCodes: [code])
        let review = try SNESReplacementSaveEnvelope.prepare(plan: plan)
        let options = try SNESReplacementSaveJournal.stagingOptions(review: review, before: before.inventory, runtimeSHA256: String(repeating: "b", count: 64))
        #expect(options.count == 1 && options[0].group == 0)
        #expect(options[0].summary.gameCode == code && options[0].summary.saveDescription == "Suspend point 1")
        let reserved = try await backup(root, originals: originals, menu: menu, profileFiles: existing,
                                        profileDirectories: [base + "suspendpoint1"], hwid: target)
        let complete = try await backup(root, originals: originals, menu: menu, profileFiles: existing.merging(slot) { _, new in new }, hwid: target)
        let partial = try await backup(root, originals: originals, menu: menu, profileFiles: existing.merging([base + "suspendpoint1/state.png": Data([4])]) { _, new in new }, hwid: target)
        var badSlot = slot; badSlot[base + "suspendpoint1/state.png"] = Data([99])
        let conflicting = try await backup(root, originals: originals, menu: menu, profileFiles: existing.merging(badSlot) { _, new in new }, hwid: target)
        let altered = try await backup(root, originals: originals, menu: menu, profileFiles: [base + "cartridge.sram": Data([99]), base + "cartridge.sram.hash": Data([3])], hwid: target)
        // A post-copy snapshot must be proven before accepting changes made
        // during a game test. Files belonging to other games remain protected.
        let changedByPlay = [base + "cartridge.sram": Data([42, 43]), base + "cartridge.sram.hash": Data([44])].merging(slot) { _, new in new }
        let played = try await backup(root, originals: originals, menu: menu, profileFiles: changedByPlay, hwid: target)
        let otherGame = "clover/profiles/0/CLV-U-A0002/cartridge.sram"
        let unrelated = try await backup(root, originals: originals, menu: menu, profileFiles: changedByPlay.merging([otherGame: Data([88])]) { _, new in new }, hwid: target)
        let removed = try await backup(root, originals: originals, menu: menu, profileFiles: existing, hwid: target)
        let otherSlot = try await backup(root, originals: originals, menu: menu,
            profileFiles: changedByPlay.merging([base + "suspendpoint2/state.png": Data([55])]) { _, new in new }, hwid: target)
        let halfSystemSave = try await backup(root, originals: originals, menu: menu,
            profileFiles: changedByPlay.merging([base + "save/system-save.json/data": Data([56])]) { _, new in new }, hwid: target)
        let changes = try SNESReplacementSaveProfileRecovery.changesAfterGameTest(review: review, group: 0, published: complete.inventory, observed: played.inventory)
        #expect(changes == [base + "cartridge.sram", base + "cartridge.sram.hash"])
        #expect(throws: (any Error).self) { try SNESReplacementSaveProfileRecovery.changesAfterGameTest(review: review, group: 0, published: complete.inventory, observed: unrelated.inventory) }
        #expect(throws: (any Error).self) { try SNESReplacementSaveProfileRecovery.changesAfterGameTest(review: review, group: 0, published: complete.inventory, observed: otherSlot.inventory) }
        #expect(throws: (any Error).self) { try SNESReplacementSaveProfileRecovery.changesAfterGameTest(review: review, group: 0, published: complete.inventory, observed: halfSystemSave.inventory) }
        #expect(throws: (any Error).self) { try SNESReplacementSaveProfileRecovery.changesAfterGameTest(review: review, group: 0, published: complete.inventory, observed: removed.inventory) }
        #expect(throws: (any Error).self) { try SNESReplacementSaveProfileRecovery.changesAfterGameTest(review: review, group: 0, published: partial.inventory, observed: played.inventory) }
        #expect(try SNESReplacementSaveProfileRecovery.inspect(review: review, group: 0, observed: before.inventory) == .absent)
        #expect(try SNESReplacementSaveProfileRecovery.inspect(review: review, group: 0, observed: reserved.inventory) == .reserved)
        #expect(try SNESReplacementSaveProfileRecovery.inspect(review: review, group: 0, observed: complete.inventory) == .published)
        #expect(try SNESReplacementSaveProfileRecovery.inspect(review: review, group: 0, observed: partial.inventory) == .needsReview)
        #expect(try SNESReplacementSaveProfileRecovery.inspect(review: review, group: 0, observed: conflicting.inventory) == .needsReview)
        #expect(throws: (any Error).self) { try SNESReplacementSaveProfileRecovery.inspect(review: review, group: 0, observed: altered.inventory) }
        #expect(throws: (any Error).self) { try SNESReplacementSaveProfileRecovery.inspect(review: review, group: 1, observed: before.inventory) }
        let journals = root.appendingPathComponent("slot-journals")
        try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: false)
        let prepared = try SNESReplacementSaveJournal.prepare(review: review, root: journals)
        let journal = try SNESReplacementSaveJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, originals: targetOriginals)
        let runtime = String(repeating: "b", count: 64), helper = SNESReplacementSaveHelper.sha256
        await #expect(throws: (any Error).self) { try await journal.publicationSummary(group: 0) }
        _ = try await journal.recordStageIntent(group: 0, before: before.inventory, runtimeSHA256: runtime, challenge: UUID(), approved: true)
        try await journal.markUncertain()
        let summary = try await journal.publicationSummary(group: 0)
        #expect(summary.gameCode == code && summary.saveDescription == "Suspend point 1")
        #expect(summary.fileCount == 4 && summary.byteCount == 4 && summary.existingProfile)
        await #expect(throws: (any Error).self) { try await journal.publicationSummary(group: 1) }
        let delivery = try SNESReplacementSaveHelperDelivery.prepare(helper: SNESReplacementSaveHelper.bundled(), hwid: before.inventory.hwid,
            contextSHA256: before.inventory.contextSHA256, runtimeSHA256: runtime, selection: before.inventory.selection, challenge: UUID())
        let publicationChallenge = UUID()
        let preparedPublication = try await journal.prepareProfilePublication(group: 0, before: before.inventory, runtimeSHA256: runtime,
            switcherSHA256: helper, challenge: publicationChallenge)
        let preview = SNESReplacementSavePublicationPreview(request: preparedPublication, helperDelivery: delivery,
            helper: try SNESReplacementSaveHelper.bundled(), inventory: before.inventory, summary: summary, group: 0)
        let offlineIO = DisconnectedSaveInspectionIO()
        let offlineSession = SNESLibraryConnectionSession(attachment: SNESLibraryContextTests.device(), io: offlineIO)
        await #expect(throws: (any Error).self) { try await offlineSession.deliverReplacementSaveHelper(journal: journal, preview: preview, approved: false) }
        await #expect(throws: (any Error).self) { try await offlineSession.deliverReplacementSaveHelper(journal: journal, preview: preview, approved: true) }
        await #expect(throws: (any Error).self) { try await offlineSession.publishReplacementSave(journal: journal, preview: preview, approved: false) }
        await #expect(throws: (any Error).self) { try await offlineSession.publishReplacementSave(journal: journal, preview: preview, approved: true) }
        await #expect(throws: (any Error).self) { try await offlineSession.verifyReplacementSaveBeforeTesting(journal: journal, backupRoot: root) }
        await #expect(throws: (any Error).self) { try await offlineSession.finishReplacementSavePublication(journal: journal, backupRoot: root, confirmed: false) }
        await #expect(throws: (any Error).self) { try await offlineSession.finishReplacementSavePublication(journal: journal, backupRoot: root, confirmed: true) }
        #expect(await offlineIO.calls == 0)
        await #expect(throws: (any Error).self) { try await journal.authorizeHelperDelivery(request: delivery, before: before.inventory, approved: false) }
        let helperPermit = try await journal.authorizeHelperDelivery(request: delivery, before: before.inventory, approved: true)
        try helperPermit.require(request: delivery, before: before.inventory)
        #expect(throws: (any Error).self) { try helperPermit.require(request: delivery, before: altered.inventory) }
        var sends = 0
        try await SNESReplacementSaveHelperDelivery.dispatch(request: delivery, before: before.inventory, permit: helperPermit) { request in
            sends += 1; return request.receipt
        }
        await #expect(throws: (any Error).self) {
            try await SNESReplacementSaveHelperDelivery.dispatch(request: delivery, before: before.inventory, permit: helperPermit) { request in
                sends += 1; return request.receipt
            }
        }
        #expect(sends == 1)
        let failedPermit = try await journal.authorizeHelperDelivery(request: delivery, before: before.inventory, approved: true)
        await #expect(throws: (any Error).self) {
            try await SNESReplacementSaveHelperDelivery.dispatch(request: delivery, before: before.inventory, permit: failedPermit) { _ in
                sends += 1; return Data("invalid receipt".utf8)
            }
        }
        await #expect(throws: (any Error).self) {
            try await SNESReplacementSaveHelperDelivery.dispatch(request: delivery, before: before.inventory, permit: failedPermit) { request in
                sends += 1; return request.receipt
            }
        }
        #expect(sends == 2)
        let forged = SNESReplacementSaveProfilePublication.Request(script: preparedPublication.script + "\n# changed", receipt: preparedPublication.receipt, challenge: publicationChallenge)
        await #expect(throws: (any Error).self) {
            try await journal.authorizeProfilePublication(request: forged, group: 0, before: before.inventory,
                                                          runtimeSHA256: runtime, challenge: publicationChallenge, approved: true)
        }
        #expect(try await journal.phase() == .uncertain)
        await #expect(throws: (any Error).self) {
            try await journal.authorizeProfilePublication(request: preparedPublication, group: 0, before: before.inventory,
                                                          runtimeSHA256: runtime, challenge: publicationChallenge, approved: false)
        }
        let publicationPermit = try await journal.authorizeProfilePublication(request: preparedPublication, group: 0, before: before.inventory,
                                                                              runtimeSHA256: runtime, challenge: publicationChallenge, approved: true)
        var publicationSends = 0
        try await SNESReplacementSaveProfilePublication.dispatch(request: preparedPublication, before: before.inventory, permit: publicationPermit) { request in
            publicationSends += 1; return request.receipt
        }
        await #expect(throws: (any Error).self) {
            try await SNESReplacementSaveProfilePublication.dispatch(request: preparedPublication, before: before.inventory, permit: publicationPermit) { request in
                publicationSends += 1; return request.receipt
            }
        }
        #expect(publicationSends == 1)
        #expect(throws: (any Error).self) { try helperPermit.require(request: delivery, before: before.inventory) }
        #expect(try await journal.inspectProfilePublication(observed: reserved.inventory) == .reserved)
        #expect(try await journal.inspectProfilePublication(observed: complete.inventory) == .published)
        #expect(try await journal.inspectProfilePublication(observed: partial.inventory) == .needsReview)
        try await journal.markProfilePublicationUncertain()
        try await journal.close()
        let reopened = try SNESReplacementSaveJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, originals: targetOriginals)
        #expect(try await reopened.phase() == .publicationUncertain)
        #expect(try await reopened.inspectProfilePublication(observed: complete.inventory) == .published)
        await #expect(throws: (any Error).self) { try await reopened.finishVerifiedPublication(backup: complete, observed: complete.inventory, confirmed: false) }
        await #expect(throws: (any Error).self) { try await reopened.finishVerifiedPublication(backup: before, observed: complete.inventory, confirmed: true) }
        await #expect(throws: (any Error).self) { try await reopened.finishVerifiedPublication(backup: complete, observed: partial.inventory, confirmed: true) }
        #expect(try await reopened.phase() == .publicationUncertain)
        // The exact post-copy backup is recorded before gameplay. Merely
        // presenting a changed later backup must not finish the transaction.
        await #expect(throws: (any Error).self) { try await reopened.finishVerifiedPublication(backup: played, observed: played.inventory, confirmed: true) }
        try await reopened.recordVerifiedPublication(backup: complete, observed: complete.inventory)
        #expect(try await reopened.phase() == .publicationVerified)
        try await reopened.close()
        #expect(throws: (any Error).self) { try SNESLibraryJournal.backupDeletionLease(directory: complete.directory, root: journals) }
        let checked = try SNESReplacementSaveJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, originals: targetOriginals)
        #expect(try await checked.phase() == .publicationVerified)
        let recoveredSummary = try await checked.publicationSummary(group: 0)
        #expect(recoveredSummary.gameCode == code && recoveredSummary.saveDescription == "Suspend point 1")
        await #expect(throws: (any Error).self) { try await checked.finishVerifiedPublication(backup: unrelated, observed: unrelated.inventory, confirmed: true) }
        await #expect(throws: (any Error).self) { try await checked.finishVerifiedPublication(backup: otherSlot, observed: otherSlot.inventory, confirmed: true) }
        await #expect(throws: (any Error).self) { try await checked.finishVerifiedPublication(backup: removed, observed: removed.inventory, confirmed: true) }
        await #expect(throws: (any Error).self) { try await checked.finishVerifiedPublication(backup: played, observed: played.inventory, confirmed: false) }
        let interruptedDraft = journals.appendingPathComponent(".snes-save-completion-interrupted")
        try Data("partial".utf8).write(to: interruptedDraft)
        #expect(try await checked.phase() == .publicationVerified)
        try await checked.finishVerifiedPublication(backup: played, observed: played.inventory, confirmed: true)
        #expect(try await checked.phase() == .completed)
        try await checked.close()
        #expect(try SNESReplacementSaveJournal.pending(root: journals, hwid: target) == nil)
        #expect(try Data(contentsOf: interruptedDraft) == Data("partial".utf8))
        let finished = try SNESReplacementSaveJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, originals: targetOriginals)
        #expect(try await finished.phase() == .completed)
        try await finished.close()
        let firmwareAfterCompletion = try SNESLibraryJournal.firmwareLease(hwid: target, root: journals)
        try firmwareAfterCompletion.closeLease()
        let backupAfterCompletion = try SNESLibraryJournal.backupDeletionLease(directory: source.directory, root: journals)
        try backupAfterCompletion.closeLease()
        try source.validate(); try before.validate(); try complete.validate()

        let failedRoot = root.appendingPathComponent("slot-failed-publication")
        try FileManager.default.createDirectory(at: failedRoot, withIntermediateDirectories: false)
        let failedPrepared = try SNESReplacementSaveJournal.prepare(review: review, root: failedRoot)
        let failedJournal = try SNESReplacementSaveJournal(operation: failedPrepared.operation, reviewSHA256: failedPrepared.reviewSHA256, originals: targetOriginals)
        _ = try await failedJournal.recordStageIntent(group: 0, before: before.inventory, runtimeSHA256: runtime, challenge: UUID(), approved: true)
        try await failedJournal.markUncertain()
        let failedChallenge = UUID()
        let failedRequest = try await failedJournal.prepareProfilePublication(group: 0, before: before.inventory, runtimeSHA256: runtime,
                                                                               switcherSHA256: helper, challenge: failedChallenge)
        let failedPublicationPermit = try await failedJournal.authorizeProfilePublication(request: failedRequest, group: 0, before: before.inventory,
                                                                                          runtimeSHA256: runtime, challenge: failedChallenge, approved: true)
        var failedSends = 0
        await #expect(throws: (any Error).self) {
            try await SNESReplacementSaveProfilePublication.dispatch(request: failedRequest, before: before.inventory, permit: failedPublicationPermit) { _ in
                failedSends += 1; return Data("invalid receipt".utf8)
            }
        }
        await #expect(throws: (any Error).self) {
            try await SNESReplacementSaveProfilePublication.dispatch(request: failedRequest, before: before.inventory, permit: failedPublicationPermit) { request in
                failedSends += 1; return request.receipt
            }
        }
        #expect(failedSends == 1)
        #expect(try await failedJournal.phase() == .publicationIntent)
        try await failedJournal.markProfilePublicationUncertain(); try await failedJournal.close()
        let failedReopened = try SNESReplacementSaveJournal(operation: failedPrepared.operation, reviewSHA256: failedPrepared.reviewSHA256, originals: targetOriginals)
        #expect(try await failedReopened.inspectProfilePublication(observed: before.inventory) == .absent)
        let proofRoot = root.appendingPathComponent("proof-tamper-backups")
        try FileManager.default.createDirectory(at: proofRoot, withIntermediateDirectories: false)
        let tamperedProof = try await backup(proofRoot, originals: originals, menu: menu,
            profileFiles: existing.merging(slot) { _, new in new }, hwid: target)
        try await failedReopened.recordVerifiedPublication(backup: tamperedProof, observed: tamperedProof.inventory)
        try Data("corrupt".utf8).write(to: tamperedProof.directory.appendingPathComponent("manifest.json"))
        await #expect(throws: (any Error).self) { try await failedReopened.inspectAfterGameTest(observed: played.inventory) }
        await #expect(throws: (any Error).self) { try await failedReopened.finishVerifiedPublication(backup: played, observed: played.inventory, confirmed: true) }
        #expect(try await failedReopened.phase() == .publicationVerified)
        try await failedReopened.close()
        #expect(try SNESReplacementSaveJournal.pending(root: failedRoot, hwid: target) != nil)

        // A review can be created before the console reconnects. Its later
        // publication record must still be recoverable after another reconnect.
        let reboundContext = String(repeating: "e", count: 64)
        let reboundFrame = Data(String(decoding: before.inventory.rawFrame, as: UTF8.self)
            .replacingOccurrences(of: "CONTEXT " + before.inventory.contextSHA256, with: "CONTEXT " + reboundContext).utf8)
        let rebound = try SNESLibraryInventory(raw: reboundFrame, challenge: before.inventory.challenge, contextSHA256: reboundContext,
                                               hwid: before.inventory.hwid, catalogSHA256: before.inventory.catalogSHA256)
        for (index, publicationInventory) in [rebound, before.inventory].enumerated() {
            let reconnectRoot = root.appendingPathComponent("slot-reconnect-journals-\(index)")
            try FileManager.default.createDirectory(at: reconnectRoot, withIntermediateDirectories: false)
            let reboundPrepared = try SNESReplacementSaveJournal.prepare(review: review, root: reconnectRoot)
            let reboundJournal = try SNESReplacementSaveJournal(operation: reboundPrepared.operation, reviewSHA256: reboundPrepared.reviewSHA256, originals: targetOriginals)
            _ = try await reboundJournal.recordStageIntent(group: 0, before: rebound, runtimeSHA256: runtime, challenge: UUID(), approved: true)
            try await reboundJournal.markUncertain()
            do {
                try await reboundJournal.recordProfilePublicationIntent(group: 0, before: publicationInventory, runtimeSHA256: runtime,
                                                                        switcherSHA256: helper, challenge: UUID(), approved: true)
            } catch { Issue.record("Could not record publication after reconnect case \(index): \(error)"); throw error }
            do {
                #expect(try await reboundJournal.inspectProfilePublication(observed: complete.inventory) == .published)
            } catch { Issue.record("Could not inspect publication after reconnect case \(index): \(error)"); throw error }
            try await reboundJournal.close()
        }
    }

    @Test func transferPayloadKeepsDifferentSaveSetsSeparate() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryMaterialTests(), (library, originals) = try fixture.fixture(root), menu = try fixture.menu(library, originals)
        let code = "CLV-U-A0001", base = "clover/profiles/0/\(code)/"
        let cartridge = Data([1, 2, 3]), cartridgeHash = Data([4, 5]), system = Data([6]), systemHash = Data([7, 8])
        let source = try await backup(root, originals: originals, menu: menu, profileFiles: [
            base + "cartridge.sram": cartridge, base + "cartridge.sram.hash": cartridgeHash,
            base + "save/system-save.json/data": system, base + "save/system-save.json/hash": systemHash
        ])
        let target = String(repeating: "2", count: 32), old = originalGamesBinding()
        var frame = originalGamesFrameFixture()
        let range = try #require(frame.range(of: Data(("HWID " + old.expectedHWID).utf8)))
        frame.replaceSubrange(range, with: Data(("HWID " + target).utf8))
        let binding = SNESRuntimeBinding(sourceSnapshot: old.sourceSnapshot, setupManifestSHA256: old.setupManifestSHA256, expectedHWID: target)
        let targetOriginals = try SNESOriginalGamesFrame(frame, binding: binding, challenge: originalGamesChallenge)
        let replacement = try SNESLibraryRestore.prepareReplacement(backup: source, originals: targetOriginals, destinationHWID: target)
        let destination = try await backup(root, originals: originals, menu: menu, hwid: target)
        let plan = try SNESReplacementSavePlan.prepare(replacement: replacement, destination: destination, gameCodes: [code])
        let review = try SNESReplacementSaveEnvelope.prepare(plan: plan), challenge = UUID()
        let unsupported = try SNESReplacementSaveJournal.stagingOptions(review: review, before: destination.inventory, runtimeSHA256: String(repeating: "b", count: 64))
        #expect(unsupported.isEmpty)
        #expect(throws: (any Error).self) {
            try SNESReplacementSaveProfilePublication.prepare(review: review, group: 0, before: destination.inventory,
                runtimeSHA256: String(repeating: "b", count: 64), switcherSHA256: String(repeating: "d", count: 64), challenge: UUID(), stageID: UUID(), stagedChallenge: challenge)
        }
        let first = try SNESReplacementSavePayload.prepare(review: review, group: 0, challenge: challenge)
        let second = try SNESReplacementSavePayload.prepare(review: review, group: 1, challenge: challenge)
        #expect(first.body == cartridge + cartridgeHash)
        #expect(second.body == system + systemHash)
        #expect(first.tableSHA256 != second.tableSHA256)
        let combined = try SNESReplacementSavePayload.prepareGame(review: review, gameCode: code, challenge: challenge)
        #expect(combined.fileCount == 4)
        #expect(combined.body == cartridge + cartridgeHash + system + systemHash)
        #expect(throws: (any Error).self) {
            try SNESReplacementSavePayload.prepareGame(review: review, gameCode: "CLV-U-Z9999", challenge: challenge)
        }
        // An existing complete cartridge set must be kept out of the new
        // payload when another complete set still needs to be copied.
        let existing = try await backup(root, originals: originals, menu: menu, profileFiles: [
            base + "cartridge.sram": cartridge, base + "cartridge.sram.hash": cartridgeHash
        ], hwid: target)
        let existingPlan = try SNESReplacementSavePlan.prepare(replacement: replacement, destination: existing, gameCodes: [code])
        let existingReview = try SNESReplacementSaveEnvelope.prepare(plan: existingPlan)
        let remaining = try SNESReplacementSavePayload.prepareGame(review: existingReview, gameCode: code, challenge: challenge)
        #expect(remaining.fileCount == 2 && remaining.body == system + systemHash)
        let unchanged = try await backup(root, originals: originals, menu: menu, profileFiles: [
            base + "cartridge.sram": cartridge, base + "cartridge.sram.hash": cartridgeHash,
            base + "save/system-save.json/data": system, base + "save/system-save.json/hash": systemHash
        ], hwid: target)
        let unchangedPlan = try SNESReplacementSavePlan.prepare(replacement: replacement, destination: unchanged, gameCodes: [code])
        #expect(throws: (any Error).self) {
            try SNESReplacementSaveEnvelope.prepare(plan: unchangedPlan)
        }
        #expect(throws: (any Error).self) { try SNESReplacementSavePayload.prepare(review: review, group: 2, challenge: challenge) }
        let journals = root.appendingPathComponent("separate-save-journals")
        try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: false)
        let prepared = try SNESReplacementSaveJournal.prepare(review: review, root: journals)
        let journal = try SNESReplacementSaveJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, originals: targetOriginals)
        let journalPayload = try await journal.prepareGamePayload(gameCode: code, challenge: challenge)
        #expect(journalPayload.table == combined.table && journalPayload.body == combined.body)
        await #expect(throws: (any Error).self) {
            try await journal.prepareGamePayload(gameCode: "CLV-U-Z9999", challenge: challenge)
        }
        let stage1 = try await journal.prepareStage(group: 0, before: destination.inventory, runtimeSHA256: String(repeating: "b", count: 64), challenge: challenge)
        let stage2 = try await journal.prepareStage(group: 1, before: destination.inventory, runtimeSHA256: String(repeating: "b", count: 64), challenge: challenge)
        let name1 = try #require(String(data: stage1.receipt, encoding: .utf8)?.components(separatedBy: "\n").first { $0.hasPrefix("STAGE ") })
        let name2 = try #require(String(data: stage2.receipt, encoding: .utf8)?.components(separatedBy: "\n").first { $0.hasPrefix("STAGE ") })
        #expect(name1 != name2)
        try await journal.cancelUnsent(); try await journal.close()

        let next = try SNESReplacementSaveJournal.prepare(review: review, root: journals)
        let bound = try SNESReplacementSaveJournal(operation: next.operation, reviewSHA256: next.reviewSHA256, originals: targetOriginals)
        let runtime = String(repeating: "b", count: 64)
        await #expect(throws: (any Error).self) {
            try await bound.recordStageIntent(group: 0, before: destination.inventory, runtimeSHA256: runtime, challenge: challenge, approved: false)
        }
        #expect(try await bound.phase() == .prepared)
        let expectedStage = try await bound.prepareStage(group: 0, before: destination.inventory, runtimeSHA256: runtime, challenge: challenge)
        let permit = try await bound.recordStageIntent(group: 0, before: destination.inventory, runtimeSHA256: runtime, challenge: challenge, approved: true)
        let recorded = try #require(try await bound.recordedStage())
        #expect(recorded.group == 0 && recorded.challenge == challenge)
        try permit.require(request: expectedStage, before: destination.inventory)
        #expect(throws: (any Error).self) { try permit.require(request: stage2, before: destination.inventory) }
        let claims = await withTaskGroup(of: Bool.self, returning: [Bool].self) { tasks in
            for _ in 0..<2 {
                tasks.addTask { (try? permit.claimDispatch(request: expectedStage, before: destination.inventory)) != nil }
            }
            var result: [Bool] = []
            for await value in tasks { result.append(value) }
            return result
        }
        #expect(claims.filter { $0 }.count == 1)
        await #expect(throws: (any Error).self) {
            try await bound.prepareStage(group: 1, before: destination.inventory, runtimeSHA256: runtime, challenge: challenge)
        }
        await #expect(throws: (any Error).self) {
            try await bound.prepareStage(group: 0, before: destination.inventory, runtimeSHA256: runtime, challenge: UUID())
        }
        try await bound.close()
        #expect(throws: (any Error).self) { try permit.require(request: expectedStage, before: destination.inventory) }
        let pendingBound = try #require(try SNESReplacementSaveJournal.pending(root: journals, hwid: target))
        #expect(pendingBound.stage == recorded)
        let restored = try SNESReplacementSaveJournal(operation: next.operation, reviewSHA256: next.reviewSHA256, originals: targetOriginals)
        #expect(try await restored.recordedStage() == recorded)
        let restoredStage = try await restored.prepareStage(group: 0, before: destination.inventory, runtimeSHA256: runtime, challenge: challenge)
        #expect(restoredStage.receipt == expectedStage.receipt && restoredStage.input == expectedStage.input)
        try await restored.markUncertain()
        #expect(try await restored.recordedStage() == recorded)
        // Staging only writes outside the live profiles. Even a correctly
        // matching reviewed save cannot be attributed to this stage operation.
        let unexpectedlyPublished = try await backup(root, originals: originals, menu: menu,
            profileFiles: [base + "cartridge.sram": cartridge, base + "cartridge.sram.hash": cartridgeHash], hwid: target)
        let differentGroupPublished = try await backup(root, originals: originals, menu: menu,
            profileFiles: [base + "save/system-save.json/data": system, base + "save/system-save.json/hash": systemHash], hwid: target)
        _ = try await restored.inspect(observed: destination.inventory)
        await #expect(throws: (any Error).self) { try await restored.inspect(observed: unexpectedlyPublished.inventory) }
        await #expect(throws: (any Error).self) { try await restored.inspect(observed: differentGroupPublished.inventory) }
        _ = try await restored.prepareStageInspection(group: 0, before: destination.inventory, runtimeSHA256: runtime, challenge: UUID())
        await #expect(throws: (any Error).self) {
            try await restored.prepareStageInspection(group: 1, before: destination.inventory, runtimeSHA256: runtime, challenge: UUID())
        }
        try await restored.close()

        let dispatchRoot = root.appendingPathComponent("dispatch-journals")
        try FileManager.default.createDirectory(at: dispatchRoot, withIntermediateDirectories: false)
        let dispatchPrepared = try SNESReplacementSaveJournal.prepare(review: review, root: dispatchRoot)
        let dispatchJournal = try SNESReplacementSaveJournal(operation: dispatchPrepared.operation, reviewSHA256: dispatchPrepared.reviewSHA256, originals: targetOriginals)
        let dispatchRequest = try await dispatchJournal.prepareStage(group: 0, before: destination.inventory, runtimeSHA256: runtime, challenge: challenge)
        let dispatchPermit = try await dispatchJournal.recordStageIntent(group: 0, before: destination.inventory, runtimeSHA256: runtime, challenge: challenge, approved: true)
        var sends = 0
        _ = try await SNESReplacementSaveStageCommands.dispatch(request: dispatchRequest, before: destination.inventory, permit: dispatchPermit) { request in
            sends += 1; return request.receipt
        }
        await #expect(throws: (any Error).self) {
            try await SNESReplacementSaveStageCommands.dispatch(request: dispatchRequest, before: destination.inventory, permit: dispatchPermit) { request in
                sends += 1; return request.receipt
            }
        }
        #expect(sends == 1)
        try await dispatchJournal.markUncertain(); try await dispatchJournal.close()

        let badRoot = root.appendingPathComponent("bad-receipt-journals")
        try FileManager.default.createDirectory(at: badRoot, withIntermediateDirectories: false)
        let badPrepared = try SNESReplacementSaveJournal.prepare(review: review, root: badRoot)
        let badJournal = try SNESReplacementSaveJournal(operation: badPrepared.operation, reviewSHA256: badPrepared.reviewSHA256, originals: targetOriginals)
        let badRequest = try await badJournal.prepareStage(group: 0, before: destination.inventory, runtimeSHA256: runtime, challenge: challenge)
        let badPermit = try await badJournal.recordStageIntent(group: 0, before: destination.inventory, runtimeSHA256: runtime, challenge: challenge, approved: true)
        await #expect(throws: (any Error).self) {
            try await SNESReplacementSaveStageCommands.dispatch(request: badRequest, before: destination.inventory, permit: badPermit) { _ in Data("bad".utf8) }
        }
        await #expect(throws: (any Error).self) {
            try await SNESReplacementSaveStageCommands.dispatch(request: badRequest, before: destination.inventory, permit: badPermit) { request in request.receipt }
        }
        try await badJournal.markUncertain()
        #expect(throws: (any Error).self) { try badPermit.require(request: badRequest, before: destination.inventory) }
        try await badJournal.close()

        let tamperRoot = root.appendingPathComponent("changed-backup-journals")
        try FileManager.default.createDirectory(at: tamperRoot, withIntermediateDirectories: false)
        let tamperPrepared = try SNESReplacementSaveJournal.prepare(review: review, root: tamperRoot)
        let tamperJournal = try SNESReplacementSaveJournal(operation: tamperPrepared.operation, reviewSHA256: tamperPrepared.reviewSHA256, originals: targetOriginals)
        let tamperRequest = try await tamperJournal.prepareStage(group: 0, before: destination.inventory, runtimeSHA256: runtime, challenge: challenge)
        let tamperPermit = try await tamperJournal.recordStageIntent(group: 0, before: destination.inventory, runtimeSHA256: runtime, challenge: challenge, approved: true)
        let blobs = try FileManager.default.contentsOfDirectory(at: source.directory.appendingPathComponent("data-0"), includingPropertiesForKeys: nil)
        let blob = try #require(blobs.first { (try? Data(contentsOf: $0)) == cartridge })
        try Data([9, 9, 9]).write(to: blob)
        #expect(throws: (any Error).self) { try tamperPermit.require(request: tamperRequest, before: destination.inventory) }
        try await tamperJournal.close()
    }

    @Test func interruptedSaveReviewSeparatesCopiedMissingAndConflictingFiles() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryMaterialTests(), (review, originals) = try fixture.fixture(root), menu = try fixture.menu(review, originals)
        let code = "CLV-U-A0001", dataPath = "clover/profiles/0/\(code)/cartridge.sram", hashPath = dataPath + ".hash"
        let data = Data([1,2,3]), hash = Data(repeating: 7, count: 20), target = String(repeating: "2", count: 32), old = originalGamesBinding()
        let source = try await backup(root, originals: originals, menu: menu, profileFiles: [dataPath:data, hashPath:hash])
        var frame = originalGamesFrameFixture()
        let header = Data(("HWID " + old.expectedHWID).utf8), range = try #require(frame.range(of: header))
        frame.replaceSubrange(range, with: Data(("HWID " + target).utf8))
        let binding = SNESRuntimeBinding(sourceSnapshot: old.sourceSnapshot, setupManifestSHA256: old.setupManifestSHA256, expectedHWID: target)
        let targetOriginals = try SNESOriginalGamesFrame(frame, binding: binding, challenge: originalGamesChallenge)
        let replacement = try SNESLibraryRestore.prepareReplacement(backup: source, originals: targetOriginals, destinationHWID: target)
        let before = try await backup(root, originals: originals, menu: menu, hwid: target)
        let initialComparison = try replacement.compareSaves(to: before)
        try initialComparison.requireCurrent(before.inventory)
        #expect(throws: (any Error).self) { try initialComparison.requireCurrent(source.inventory) }
        let available = try replacement.saveOptions(comparison: initialComparison)
        #expect(available.count == 1 && available[0].code == code && available[0].eligible && available[0].title == "Imported 1")
        let plan = try SNESReplacementSavePlan.prepare(replacement: replacement, destination: before, gameCodes: [code])
        try plan.requireCurrent(before.inventory)
        try plan.requireReplacement(replacement)
        let otherSource = try await backup(root, originals: originals, menu: menu, profileFiles: [dataPath:Data([4]), hashPath:hash])
        let otherReplacement = try SNESLibraryRestore.prepareReplacement(backup: otherSource, originals: targetOriginals, destinationHWID: target)
        #expect(throws: (any Error).self) { try plan.requireReplacement(otherReplacement) }
        #expect(try plan.nativeLayout().groups.count == 1)
        #expect(try plan.protectedGroups().count == 1)
        let savedReview = try SNESReplacementSaveEnvelope.prepare(plan: plan)
        let transferID = UUID(uuidString: "08E6B3EB-4CFA-4D1C-962F-009FF746F92E")!
        let transfer = try SNESReplacementSavePayload.prepare(review: savedReview, group: 0, challenge: transferID)
        let records = [dataPath, hashPath].map { path in
            let bytes = path == dataPath ? data : hash
            return "FILE \(Data(path.utf8).map { String(format: "%02x", $0) }.joined()) \(bytes.count) \(BackupManifest.digest(bytes)) 384 0\n"
        }.joined()
        let expectedTable = "SWIFTHAKCHI_SNES_SAVE_GROUP_V1\nCHALLENGE \(transferID.uuidString)\nHWID \(target)\nREVIEW \(savedReview.sha256)\nFILES 2\n" + records + "END\n"
        #expect(transfer.table == Data(expectedTable.utf8))
        #expect(transfer.body == data + hash)
        #expect(transfer.tableSHA256 == BackupManifest.digest(Data(expectedTable.utf8)))
        #expect(transfer.bodySHA256 == BackupManifest.digest(data + hash))
        #expect(throws: (any Error).self) { try SNESReplacementSavePayload.prepare(review: savedReview, group: 1, challenge: transferID) }
        let anotherTarget = try await backup(root, originals: originals, menu: menu,
            profileFiles: ["clover/profiles/0/CLV-U-A0002/cartridge.sram": Data([44])], hwid: target)
        let anotherPlan = try SNESReplacementSavePlan.prepare(replacement: replacement, destination: anotherTarget, gameCodes: [code])
        let mismatchedReview = SNESReplacementSaveEnvelope(data: savedReview.data, sha256: savedReview.sha256, plan: anotherPlan)
        #expect(throws: (any Error).self) { try SNESReplacementSavePayload.prepare(review: mismatchedReview, group: 0, challenge: transferID) }
        #expect(throws: (any Error).self) { try SNESReplacementSavePayload.prepareGame(review: mismatchedReview, gameCode: code, challenge: transferID) }
        #expect(throws: (any Error).self) { try SNESReplacementSaveReviewStore.save(mismatchedReview, root: root) }
        let mismatchedJournals = root.appendingPathComponent("mismatched-journals")
        try FileManager.default.createDirectory(at: mismatchedJournals, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try SNESReplacementSaveJournal.prepare(review: mismatchedReview, root: mismatchedJournals) }
        let reopened = try SNESReplacementSaveEnvelope.load(data: savedReview.data, expectedSHA256: savedReview.sha256, originals: targetOriginals)
        #expect(reopened.plan.files.map(\.path) == plan.files.map(\.path))
        #expect(try reopened.plan.read(path: dataPath) == data)
        let saved = try SNESReplacementSaveReviewStore.save(savedReview, root: root)
        let fromDisk = try SNESReplacementSaveReviewStore.open(saved, originals: targetOriginals)
        #expect(fromDisk.sha256 == savedReview.sha256 && fromDisk.plan.files.map(\.path) == plan.files.map(\.path))
        let fromFolder = try SNESReplacementSaveReviewStore.open(directory: saved.directory, originals: targetOriginals)
        #expect(fromFolder.sha256 == savedReview.sha256 && fromFolder.plan.gameCodes == [code])
        let storedReview = saved.directory.appendingPathComponent("review.json")
        try Data("damaged".utf8).write(to: storedReview)
        #expect(throws: (any Error).self) { try SNESReplacementSaveReviewStore.open(saved, originals: targetOriginals) }
        try savedReview.data.write(to: storedReview)
        let extra = saved.directory.appendingPathComponent("unexpected")
        try Data([1]).write(to: extra)
        #expect(throws: (any Error).self) { try SNESReplacementSaveReviewStore.open(saved, originals: targetOriginals) }
        try FileManager.default.removeItem(at: extra)
        let outside = root.appendingPathComponent("outside-review.json")
        try savedReview.data.write(to: outside); try FileManager.default.removeItem(at: storedReview)
        try FileManager.default.createSymbolicLink(at: storedReview, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try SNESReplacementSaveReviewStore.open(saved, originals: targetOriginals) }
        try FileManager.default.removeItem(at: storedReview); try savedReview.data.write(to: storedReview)
        var changedReview = savedReview.data; changedReview[changedReview.startIndex] ^= 1
        #expect(throws: (any Error).self) { try SNESReplacementSaveEnvelope.load(data: changedReview, expectedSHA256: savedReview.sha256, originals: targetOriginals) }
        #expect(throws: (any Error).self) { try SNESReplacementSaveEnvelope.load(data: savedReview.data, expectedSHA256: savedReview.sha256, originals: originals) }
        let partial = try await backup(root, originals: originals, menu: menu, profileFiles: [dataPath:data], hwid: target)
        #expect(throws: (any Error).self) { try plan.requireCurrent(partial.inventory) }
        #expect(throws: (any Error).self) { try initialComparison.requireCurrent(partial.inventory) }
        let partialOptions = try replacement.saveOptions(comparison: replacement.compareSaves(to: partial))
        #expect(partialOptions.count == 1 && !partialOptions[0].eligible)
        let partialBaseline = try SNESReplacementSavePlan.prepare(replacement: replacement, destination: partial, gameCodes: [code])
        #expect(throws: (any Error).self) { try partialBaseline.protectedGroups() }
        #expect(throws: (any Error).self) { try SNESReplacementSaveEnvelope.prepare(plan: partialBaseline) }
        let assessment = try SNESReplacementSaveRecovery.inspect(plan: plan, observed: partial.inventory)
        #expect(assessment.copiedPaths == [dataPath] && assessment.pendingPaths == [hashPath] && assessment.conflictingPaths.isEmpty)
        #expect(!assessment.canResume)
        let journals = root.appendingPathComponent("save-journals")
        try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: false)
        // A crash before publication must leave no active transfer record,
        // even if the draft itself was only partly written.
        let draftLease = try SNESLibraryJournal.firmwareLease(hwid: target, root: journals)
        let draft = try SNESReplacementSaveJournal.createUnpublished(review: savedReview, storage: draftLease)
        try draftLease.closeLease()
        try FileManager.default.removeItem(at: draft.operation.appendingPathComponent("0000.json"))
        #expect(try SNESReplacementSaveJournal.pending(root: journals, hwid: target) == nil)
        let afterInterruptedDraft = try SNESLibraryJournal.firmwareLease(hwid: target, root: journals)
        try afterInterruptedDraft.closeLease()
        let afterDraftBackup = try SNESLibraryJournal.backupDeletionLease(directory: source.directory, root: journals)
        try afterDraftBackup.closeLease()
        let prepared = try SNESReplacementSaveJournal.prepare(review: savedReview, root: journals)
        let published = try #require(try SNESReplacementSaveJournal.pending(root: journals, hwid: target))
        #expect(published.operation == prepared.operation && published.phase == .prepared)
        #expect(throws: (any Error).self) { try SNESLibraryJournal.firmwareLease(hwid: target, root: journals) }
        #expect(throws: (any Error).self) { try SNESLibraryJournal.backupDeletionLease(directory: source.directory, root: journals) }
        let journal = try SNESReplacementSaveJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, originals: targetOriginals)
        #expect(try await journal.phase() == .prepared)
        let disconnectedIO = DisconnectedSaveInspectionIO()
        let disconnected = SNESLibraryConnectionSession(attachment: SNESLibraryContextTests.device(), io: disconnectedIO)
        await #expect(throws: (any Error).self) { try await disconnected.inspectReplacementSaveStage(journal: journal, group: 0) }
        await #expect(throws: (any Error).self) { try await disconnected.inspectReplacementSavePublication(journal: journal) }
        await #expect(throws: (any Error).self) { try await disconnected.previewReplacementSavePublication(journal: journal, group: 0) }
        await #expect(throws: (any Error).self) { try await disconnected.stageReplacementSave(journal: journal, group: 0, approved: false) }
        await #expect(throws: (any Error).self) { try await disconnected.stageReplacementSave(journal: journal, group: 0, approved: true) }
        #expect(await disconnectedIO.calls == 0)
        #expect(try await journal.phase() == .prepared)
        let preparedPayload = try await journal.preparePayload(group: 0, challenge: transferID)
        #expect(preparedPayload.table == transfer.table && preparedPayload.body == data + hash)
        let stageRequest = try await journal.prepareStage(group: 0, before: before.inventory,
            runtimeSHA256: String(repeating: "b", count: 64), challenge: transferID)
        await #expect(throws: (any Error).self) {
            try await journal.prepareStage(group: 0, before: source.inventory, runtimeSHA256: String(repeating: "b", count: 64), challenge: transferID)
        }
        #expect(try await journal.phase() == .prepared)
        await #expect(throws: (any Error).self) { try await journal.recordWriteIntent(approved: false) }
        try await journal.recordWriteIntent(approved: true)
        await #expect(throws: (any Error).self) { try await journal.prepareGamePayload(gameCode: code, challenge: transferID) }
        let payloadAfterIntent = try await journal.preparePayload(group: 0, challenge: transferID)
        #expect(payloadAfterIntent.body == data + hash)
        await #expect(throws: (any Error).self) { try await journal.recordWriteIntent(approved: true) }
        try await journal.close()
        let pendingJournal = try #require(try SNESReplacementSaveJournal.pending(root: journals, hwid: target))
        #expect(pendingJournal.operation == prepared.operation && pendingJournal.reviewSHA256 == prepared.reviewSHA256 && pendingJournal.phase == .writeIntent)
        #expect(try SNESReplacementSaveJournal.pending(root: journals, hwid: String(repeating: "3", count: 32)) == nil)
        #expect(throws: (any Error).self) { try SNESLibraryJournal.firmwareLease(hwid: target, root: journals) }
        #expect(throws: (any Error).self) { try SNESLibraryJournal.backupDeletionLease(directory: source.directory, root: journals) }
        #expect(throws: (any Error).self) { try SNESLibraryJournal.backupDeletionLease(directory: before.directory, root: journals) }
        let otherLease = try SNESLibraryJournal.firmwareLease(hwid: String(repeating: "3", count: 32), root: journals)
        try otherLease.closeLease()
        let resumed = try SNESReplacementSaveJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, originals: targetOriginals)
        #expect(try await resumed.phase() == .writeIntent)
        let reopenedStage = try await resumed.prepareStage(group: 0, before: before.inventory,
            runtimeSHA256: String(repeating: "b", count: 64), challenge: transferID)
        #expect(reopenedStage.receipt == stageRequest.receipt)
        #expect(reopenedStage.input == stageRequest.input)
        try await resumed.markUncertain()
        await #expect(throws: (any Error).self) { try await resumed.preparePayload(group: 0, challenge: transferID) }
        // Older records without a bound stage cannot prove which attempt
        // produced console files and must not issue an inspection request.
        await #expect(throws: (any Error).self) {
            try await resumed.prepareStageInspection(group: 0, before: before.inventory,
                runtimeSHA256: String(repeating: "b", count: 64), challenge: UUID())
        }
        await #expect(throws: (any Error).self) {
            try await resumed.prepareStageInspection(group: 0, before: source.inventory, runtimeSHA256: String(repeating: "b", count: 64), challenge: UUID())
        }
        await #expect(throws: (any Error).self) {
            try await resumed.prepareStage(group: 0, before: before.inventory, runtimeSHA256: String(repeating: "b", count: 64), challenge: transferID)
        }
        let journalAssessment = try await resumed.inspect(observed: partial.inventory)
        #expect(!journalAssessment.canResume && journalAssessment.copiedPaths == [dataPath])
        await #expect(throws: (any Error).self) { try await resumed.cancelUnsent() }
        try await resumed.close()
        #expect(throws: (any Error).self) { try SNESReplacementSaveJournal.closeUnsentReview(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256) }
        let event = prepared.operation.appendingPathComponent("0002.json"), eventBytes = try Data(contentsOf: event)
        try Data("damaged".utf8).write(to: event)
        #expect(throws: (any Error).self) { try SNESReplacementSaveJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, originals: targetOriginals) }
        #expect(throws: (any Error).self) { try SNESLibraryJournal.firmwareLease(hwid: target, root: journals) }
        try eventBytes.write(to: event)
        let planPath = prepared.operation.appendingPathComponent("plan.json")
        #expect(chmod(planPath.path, 0o644) == 0)
        #expect(throws: (any Error).self) { try SNESReplacementSaveJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, originals: targetOriginals) }
        #expect(chmod(planPath.path, 0o600) == 0)
        let cancelledRoot = root.appendingPathComponent("cancelled-save-journals")
        try FileManager.default.createDirectory(at: cancelledRoot, withIntermediateDirectories: false)
        let unsent = try SNESReplacementSaveJournal.prepare(review: savedReview, root: cancelledRoot)
        let unsentJournal = try SNESReplacementSaveJournal(operation: unsent.operation, reviewSHA256: unsent.reviewSHA256, originals: targetOriginals)
        try await unsentJournal.cancelUnsent(); try await unsentJournal.close()
        #expect(try SNESReplacementSaveJournal.pending(root: cancelledRoot, hwid: target) == nil)
        let allowed = try SNESLibraryJournal.firmwareLease(hwid: target, root: cancelledRoot); try allowed.closeLease()
        let removable = try SNESLibraryJournal.backupDeletionLease(directory: source.directory, root: cancelledRoot); try removable.closeLease()
        let missingRoot = root.appendingPathComponent("missing-backup-journals")
        try FileManager.default.createDirectory(at: missingRoot, withIntermediateDirectories: false)
        let missingReview = try SNESReplacementSaveJournal.prepare(review: savedReview, root: missingRoot)
        let movedBackup = root.appendingPathComponent("temporarily-moved-backup")
        try FileManager.default.moveItem(at: source.directory, to: movedBackup)
        defer { if FileManager.default.fileExists(atPath: movedBackup.path) { try? FileManager.default.moveItem(at: movedBackup, to: source.directory) } }
        #expect(throws: (any Error).self) { try SNESReplacementSaveJournal(operation: missingReview.operation, reviewSHA256: missingReview.reviewSHA256, originals: targetOriginals) }
        try SNESReplacementSaveJournal.closeUnsentReview(operation: missingReview.operation, reviewSHA256: missingReview.reviewSHA256)
        try FileManager.default.moveItem(at: movedBackup, to: source.directory)
        let afterMissing = try SNESLibraryJournal.firmwareLease(hwid: target, root: missingRoot); try afterMissing.closeLease()
        let restoredReview = try SNESReplacementSaveEnvelope.load(data: savedReview.data, expectedSHA256: savedReview.sha256, originals: targetOriginals)
        let syncRoot = root.appendingPathComponent("unfinished-sync")
        try FileManager.default.createDirectory(at: syncRoot, withIntermediateDirectories: false)
        let frozen = try SNESLibraryMaterial.freeze(menu: try #require(replacement.menu).withNativeArtwork(), in: root)
        let installation = SNESLibraryInstallationReference(hwid: target, operationID: UUID(), reviewSHA256: String(repeating: "c", count: 64),
            catalog: root.appendingPathComponent("SNES-Original-Games-" + UUID().uuidString), catalogSHA256: String(repeating: "d", count: 64))
        let sync = try SNESLibrarySyncPlan.prepare(material: frozen, backup: before, before: before.inventory,
            capacity: before.inventory.capacity, installation: installation, originals: targetOriginals)
        _ = try SNESLibraryJournal.prepare(plan: sync, root: syncRoot)
        #expect(throws: (any Error).self) { try SNESReplacementSaveJournal.prepare(review: restoredReview, root: syncRoot) }
        let initialReview = try SNESReplacementSaveRecovery.inspect(plan: restoredReview.plan, observed: before.inventory)
        #expect(initialReview.canResume && initialReview.copiedPaths.isEmpty)
        let complete = try await backup(root, originals: originals, menu: menu, profileFiles: [dataPath:data, hashPath:hash], hwid: target)
        let completeReview = try SNESReplacementSaveRecovery.inspect(plan: restoredReview.plan, observed: complete.inventory)
        #expect(completeReview.copiedPaths == [dataPath, hashPath] && completeReview.pendingPaths.isEmpty && completeReview.canResume)
        let conflict = try await backup(root, originals: originals, menu: menu, profileFiles: [dataPath:Data([8])], hwid: target)
        let conflictReview = try SNESReplacementSaveRecovery.inspect(plan: restoredReview.plan, observed: conflict.inventory)
        #expect(conflictReview.conflictingPaths == [dataPath] && !conflictReview.canResume)
        let unrelated = try await backup(root, originals: originals, menu: menu, profileFiles: [dataPath:data, "clover/profiles/0/CLV-U-A0002/cartridge.sram":data], hwid: target)
        #expect(throws: (any Error).self) { try SNESReplacementSaveRecovery.inspect(plan: restoredReview.plan, observed: unrelated.inventory) }
        #expect(throws: (any Error).self) { try SNESReplacementSaveRecovery.inspect(plan: restoredReview.plan, observed: source.inventory) }
        let blobs = try FileManager.default.contentsOfDirectory(at: source.directory.appendingPathComponent("data-0"), includingPropertiesForKeys: nil)
        let sourceBlob = try #require(blobs.first { (try? Data(contentsOf: $0)) == data })
        try Data([9, 9, 9]).write(to: sourceBlob)
        #expect(throws: (any Error).self) { try SNESReplacementSavePayload.prepare(review: restoredReview, group: 0, challenge: transferID) }
    }
}

private actor DisconnectedSaveInspectionIO: SNESLibraryConnectionIO {
    private(set) var calls = 0
    func open() { calls += 1 }
    func inventory() -> [RecoveryProbeUSBDevice] { calls += 1; return [] }
    func identity(challenge: UUID) throws -> Data { calls += 1; throw SNESLibraryInventory.failure() }
    func report(installation: SNESLibraryInstallation, challenge: UUID) throws -> Data { calls += 1; throw SNESLibraryInventory.failure() }
    func libraryInventory(context: SNESLibraryContext, challenge: UUID) throws -> Data { calls += 1; throw SNESLibraryInventory.failure() }
    func librarySpace(context: SNESLibraryContext, selection: SNESLibraryInventory.Selection, challenge: UUID) throws -> Data { calls += 1; throw SNESLibraryInventory.failure() }
    func libraryChunk(context: SNESLibraryContext, file: SNESLibraryInventory.File, offset: Int, challenge: UUID) throws -> Data { calls += 1; throw SNESLibraryInventory.failure() }
    func disconnect() { calls += 1 }
}
