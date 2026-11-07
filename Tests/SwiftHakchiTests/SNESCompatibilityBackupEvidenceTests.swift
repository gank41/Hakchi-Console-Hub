import Foundation
import CoreGraphics
import ImageIO
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESCompatibilityBackupEvidenceTests {
    @Test func archivedStateRequiresMatchingSessionAndIndependentDigest() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("CLV-U-ABCDE", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: folder.appendingPathComponent("game.sfc"))
        var game = Game(code: "CLV-U-ABCDE", desktopContent: "Name=Game\n", consoleType: .snesUsa, source: .local); game.romPath = folder.path
        let source = try SNESLibraryROMSource.capture(directory: folder, filename: "game.sfc").0
        let request = try SNESCompatibilityLaunchRequest.prepare(game: game, source: source, session: Data(repeating: 7, count: 16), epoch: 4)
        var manager = Data("HCSESS1\0".utf8); manager.append(request.frame); manager.append(contentsOf: [0, 0, 0, 0])
        let token = request.frame[83..<99].map { String(format: "%02x", $0) }.joined()
        let path = "/var/lib/clover/profiles/0/CLV-U-ABCDE/hakchi/\(SNESCompatibilityCorePackage.engineID)/\(source.sha256)/sessions/checkpoint-\(token)/state-archive/state-captured"
        let descriptor = Data("HC-BINDING-1\nCLV-U-ABCDE\n\(source.sha256)\n\(token)\n4\n1\n107 123 456 \(path)\n".utf8)
        let payload = Data("test state".utf8), digest = BackupManifest.digest(payload)
        var response = Data("HC-STATE-ARCHIVE-1\n123 456 \(descriptor.count) 1 \(payload.count)\n".utf8)
        response.append(descriptor); response.append(Data("ENTRY \(token) checkpoint-fffffffffffffffffffffffffffffffe state-captured 2 1\n".utf8)); response.append(payload); response.append(Data("HC-STATE-ARCHIVE-END\n".utf8))
        #expect(try SNESStateArchiveObservation.parse(response, managerRecord: manager, request: request, game: game, expectedSHA256: digest).payload == payload)
        let selectedState = "/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint1/rollback/savestate"
        let selectedFields = ["", "", "", "", selectedState].map { Array($0.utf8) }
        var resumedManager = Data("HCMGR3\0\0".utf8); resumedManager.append(request.frame)
        for field in selectedFields { resumedManager.append(UInt8(field.count & 255)); resumedManager.append(UInt8(field.count >> 8)) }
        for field in selectedFields { resumedManager.append(contentsOf: field) }
        #expect(throws: (any Error).self) { try SNESStateArchiveObservation.parse(response, managerRecord: resumedManager, request: request, game: game, expectedSHA256: digest) }
        #expect(try SNESStateArchiveObservation.parse(response, managerRecord: resumedManager, request: request, game: game, expectedSHA256: digest, expectedManagerLoadPath: selectedState).payload == payload)
        #expect(throws: (any Error).self) { try SNESStateArchiveObservation.parse(response, managerRecord: resumedManager, request: request, game: game, expectedSHA256: digest, expectedManagerLoadPath: selectedState + "-wrong") }
        #expect(throws: (any Error).self) { try SNESStateArchiveObservation.parse(response, managerRecord: manager, request: request, game: game, expectedSHA256: digest, expectedManagerLoadPath: selectedState) }
        #expect(throws: (any Error).self) { try SNESStateArchiveObservation.parse(response.dropLast(), managerRecord: manager, request: request, game: game, expectedSHA256: digest) }
        #expect(throws: (any Error).self) { try SNESStateArchiveObservation.parse(response, managerRecord: manager, request: request, game: game, expectedSHA256: String(repeating: "0", count: 64)) }
        var wrongSession = request.frame; wrongSession[83] ^= 1
        let wrong = SNESCompatibilityLaunchRequest(frame: wrongSession, source: source)
        #expect(throws: (any Error).self) { try SNESStateArchiveObservation.parse(response, managerRecord: manager, request: wrong, game: game, expectedSHA256: digest) }
        var wrongManager = manager; wrongManager[wrongManager.count-1] = 1
        #expect(throws: (any Error).self) { try SNESStateArchiveObservation.parse(response, managerRecord: wrongManager, request: request, game: game, expectedSHA256: digest) }
        var wrongGame = Game(code: "CLV-U-ABCDF", desktopContent: "Name=Game\n", consoleType: .snesUsa, source: .local); wrongGame.romPath = folder.path
        #expect(throws: (any Error).self) { try SNESStateArchiveObservation.parse(response, managerRecord: manager, request: request, game: wrongGame, expectedSHA256: digest) }
        var alteredDescriptor = response
        let descriptorStart = Data("HC-STATE-ARCHIVE-1\n123 456 \(descriptor.count) 1 \(payload.count)\n".utf8).count
        alteredDescriptor[descriptorStart] ^= 1
        #expect(throws: (any Error).self) { try SNESStateArchiveObservation.parse(alteredDescriptor, managerRecord: manager, request: request, game: game, expectedSHA256: digest) }
        let stable = RecoveryReadSequence(frame: response, changed: false)
        #expect(try await SNESStateArchiveObservation.capture(managerRecord: manager, request: request, game: game, expectedSHA256: digest, validate: {}, read: { await stable.read() }).payload == payload)
        #expect(await stable.reads == 2)
        let changed = RecoveryReadSequence(frame: response, changed: true)
        await #expect(throws: (any Error).self) { try await SNESStateArchiveObservation.capture(managerRecord: manager, request: request, game: game, expectedSHA256: digest, validate: {}, read: { await changed.read() }) }
        let disconnected = RecoveryFinalValidation(failOnFourth: true), stableReply = response
        await #expect(throws: (any Error).self) { try await SNESStateArchiveObservation.capture(managerRecord: manager, request: request, game: game, expectedSHA256: digest, validate: { try await disconnected.check() }, read: { stableReply }) }
        let command = try SNESCompatibilityRecoveryCommand.prepareStateArchive(request: request, helperSHA256: String(repeating: "a", count: 64))
        #expect(command.input == request.frame && command.command.hasSuffix("--observe-state-archive"))
        #expect(throws: (any Error).self) { try SNESCompatibilityRecoveryCommand.prepareStateArchive(request: request, helperSHA256: "invalid") }
        if let fixture = ProcessInfo.processInfo.environment["HC_STATE_ARCHIVE_WIRE_FIXTURE"] {
            let directory = URL(fileURLWithPath: fixture, isDirectory: true)
            let actualManager = try Data(contentsOf: directory.appendingPathComponent("manager.meta"))
            let frame = Data(actualManager[8..<115]), code = String(decoding: frame[8..<19], as: UTF8.self)
            let romFolder = directory.appendingPathComponent(code, isDirectory: true)
            var actualGame = Game(code: code, desktopContent: "Name=Fixture\n", consoleType: .snesUsa, source: .local); actualGame.romPath = romFolder.path
            let actualSource = try SNESLibraryROMSource.capture(directory: romFolder, filename: "fixture.sfc").0
            let actualRequest = try SNESCompatibilityLaunchRequest.observeConsoleFrame(frame, game: actualGame, source: actualSource)
            let expected = try Data(contentsOf: directory.appendingPathComponent("expected-state"))
            let reply = try Data(contentsOf: directory.appendingPathComponent("reply"))
            let observed = try SNESStateArchiveObservation.parse(reply, managerRecord: actualManager, request: actualRequest, game: actualGame, expectedSHA256: BackupManifest.digest(expected))
            #expect(observed.payload == expected)
        }
    }
    @Test func retainedTimeRequiresTheSelectedSessionAndIndependentDigest() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("CLV-U-ABCDE", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: folder.appendingPathComponent("game.sfc"))
        var game = Game(code: "CLV-U-ABCDE", desktopContent: "Name=Game\n", consoleType: .snesUsa, source: .local); game.romPath = folder.path
        let source = try SNESLibraryROMSource.capture(directory: folder, filename: "game.sfc").0
        let request = try SNESCompatibilityLaunchRequest.prepare(game: game, source: source, session: Data(repeating: 7, count: 16), epoch: 4)
        let managerPath = "/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/old.time"
        let fields = ["", "", managerPath, managerPath].map { Array($0.utf8) }
        var record = Data("HCMGR2\0\0".utf8); record.append(request.frame)
        for field in fields { record.append(UInt8(field.count & 255)); record.append(UInt8(field.count >> 8)) }
        for field in fields { record.append(contentsOf: field) }
        let token = request.frame[83..<99].map { String(format: "%02x", $0) }.joined()
        let path = "/var/lib/clover/profiles/0/CLV-U-ABCDE/hakchi/\(SNESCompatibilityCorePackage.engineID)/\(source.sha256)/sessions/checkpoint-\(token)/time-original"
        let descriptor = Data("HC-BINDING-1\nCLV-U-ABCDE\n\(source.sha256)\n\(token)\n4\n1\n106 123 456 \(path)\n".utf8)
        let original = Data("0043\n".utf8), digest = BackupManifest.digest(original)
        var response = Data("HC-RETAINED-TIME-1\n123 456 \(descriptor.count) 1 \(original.count)\n".utf8)
        response.append(descriptor); response.append(Data("ENTRY \(token) checkpoint-fffffffffffffffffffffffffffffffe time-original 2 1\n".utf8)); response.append(original); response.append(Data("HC-RETAINED-TIME-END\n".utf8))
        #expect(try SNESRetainedTimeObservation.parse(response, managerRecord: record, request: request, expectedLoadPath: managerPath, expectedSHA256: digest) == original)
        let selectedState = "/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint1/rollback/savestate"
        let resumedFields = ["", "", managerPath, managerPath, selectedState].map { Array($0.utf8) }
        var resumedRecord = Data("HCMGR3\0\0".utf8); resumedRecord.append(request.frame)
        for field in resumedFields { resumedRecord.append(UInt8(field.count & 255)); resumedRecord.append(UInt8(field.count >> 8)) }
        for field in resumedFields { resumedRecord.append(contentsOf: field) }
        #expect(throws: (any Error).self) { try SNESRetainedTimeObservation.parse(response, managerRecord: resumedRecord, request: request, expectedLoadPath: managerPath, expectedSHA256: digest) }
        #expect(try SNESRetainedTimeObservation.parse(response, managerRecord: resumedRecord, request: request, expectedLoadPath: managerPath, expectedSHA256: digest, expectedManagerLoadPath: selectedState) == original)
        #expect(throws: (any Error).self) { try SNESRetainedTimeObservation.parse(response, managerRecord: resumedRecord, request: request, expectedLoadPath: managerPath, expectedSHA256: digest, expectedManagerLoadPath: selectedState + "-wrong") }
        #expect(throws: (any Error).self) { try SNESRetainedTimeObservation.parse(response, managerRecord: record, request: request, expectedLoadPath: managerPath, expectedSHA256: digest, expectedManagerLoadPath: selectedState) }
        #expect(throws: (any Error).self) { try SNESRetainedTimeObservation.parse(response, managerRecord: record, request: request, expectedLoadPath: managerPath, expectedSHA256: String(repeating: "0", count: 64)) }
        #expect(throws: (any Error).self) { try SNESRetainedTimeObservation.parse(response.dropLast(), managerRecord: record, request: request, expectedLoadPath: managerPath, expectedSHA256: digest) }
        #expect(throws: (any Error).self) { try SNESRetainedTimeObservation.parse(response, managerRecord: record, request: request, expectedLoadPath: managerPath + "x", expectedSHA256: digest) }
        let malformed = Data("xx43\n".utf8)
        var badPayload = response
        let payloadStart = badPayload.count - Data("HC-RETAINED-TIME-END\n".utf8).count - original.count
        badPayload.replaceSubrange(payloadStart..<(payloadStart + original.count), with: malformed)
        #expect(throws: (any Error).self) { try SNESRetainedTimeObservation.parse(badPayload, managerRecord: record, request: request, expectedLoadPath: managerPath, expectedSHA256: BackupManifest.digest(malformed)) }
        var badDescriptor = response
        let descriptorStart = Data("HC-RETAINED-TIME-1\n123 456 \(descriptor.count) 1 \(original.count)\n".utf8).count
        badDescriptor[descriptorStart] ^= 1
        #expect(throws: (any Error).self) { try SNESRetainedTimeObservation.parse(badDescriptor, managerRecord: record, request: request, expectedLoadPath: managerPath, expectedSHA256: digest) }
        var wrongSession = request.frame; wrongSession[83] ^= 1
        let wrong = SNESCompatibilityLaunchRequest(frame: wrongSession, source: source)
        #expect(throws: (any Error).self) { try SNESRetainedTimeObservation.parse(response, managerRecord: record, request: wrong, expectedLoadPath: managerPath, expectedSHA256: digest) }
        let slicedRequest = SNESCompatibilityLaunchRequest(frame: (Data([0]) + request.frame).dropFirst(), source: source)
        #expect(try SNESRetainedTimeObservation.parse(response, managerRecord: record, request: slicedRequest, expectedLoadPath: managerPath, expectedSHA256: digest) == original)
        let stable = RecoveryReadSequence(frame: response, changed: false)
        #expect(try await SNESRetainedTimeObservation.capture(managerRecord: record, request: request, expectedLoadPath: managerPath, expectedSHA256: digest, validate: {}, read: { await stable.read() }) == original)
        #expect(await stable.reads == 2)
        let changed = RecoveryReadSequence(frame: response, changed: true)
        await #expect(throws: (any Error).self) { try await SNESRetainedTimeObservation.capture(managerRecord: record, request: request, expectedLoadPath: managerPath, expectedSHA256: digest, validate: {}, read: { await changed.read() }) }
        let disconnected = RecoveryFinalValidation(failOnFourth: true)
        let stableReply = response
        await #expect(throws: (any Error).self) { try await SNESRetainedTimeObservation.capture(managerRecord: record, request: request, expectedLoadPath: managerPath, expectedSHA256: digest, validate: { try await disconnected.check() }, read: { stableReply }) }
        let command = try SNESCompatibilityRecoveryCommand.prepareRetainedTime(request: request, helperSHA256: String(repeating: "a", count: 64))
        #expect(command.input == request.frame && command.command.hasSuffix("--observe-retained-time"))
        #expect(throws: (any Error).self) { try SNESCompatibilityRecoveryCommand.prepareRetainedTime(request: request, helperSHA256: "invalid") }
    }
    @Test func discoversBatteryOnlySessionWithoutScreenshot() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("CLV-U-ABCDE", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: folder.appendingPathComponent("game.sfc"))
        var game = Game(code: "CLV-U-ABCDE", desktopContent: "Name=Game\n", consoleType: .snesUsa, source: .local); game.romPath = folder.path
        let source = try SNESLibraryROMSource.capture(directory: folder, filename: "game.sfc").0
        let request = try SNESCompatibilityLaunchRequest.prepare(game: game, source: source, session: Data(repeating: 7, count: 16), epoch: 4)
        var record = Data("HCSESS1\0".utf8); record.append(request.frame); record.append(contentsOf: [0, 0, 0, 0])
        var inventory = Data("HCMINV2\0".utf8); inventory.append(contentsOf: [1, 0, UInt8(record.count), 0]); inventory.append(record)
        let observed = try SNESCompatibilityManagerInventory.parse(inventory, game: game, source: source)
        #expect(observed.sessions.count == 1 && observed.sessions[0].request.frame == request.frame)
        #expect(observed.sessions[0].paths.savePath == nil && observed.sessions[0].paths.imagePath == nil)
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.observeManagerScreenshotRecord(record, request: request) }
        var malformed = inventory; malformed[malformed.count - 1] = 1
        #expect(throws: (any Error).self) { try SNESCompatibilityManagerInventory.parse(malformed, game: game, source: source) }
        var wrongGame = inventory; wrongGame[12 + 8 + 6] = 90
        #expect(throws: (any Error).self) { try SNESCompatibilityManagerInventory.parse(wrongGame, game: game, source: source) }
        var zeroSession = inventory; zeroSession.replaceSubrange((12 + 8 + 83)..<(12 + 8 + 99), with: Data(repeating: 0, count: 16))
        #expect(throws: (any Error).self) { try SNESCompatibilityManagerInventory.parse(zeroSession, game: game, source: source) }
        var fakeScreenshot = inventory; fakeScreenshot.replaceSubrange(12..<20, with: Data("HCSHOT1\0".utf8))
        #expect(throws: (any Error).self) { try SNESCompatibilityManagerInventory.parse(fakeScreenshot, game: game, source: source) }
    }
    @Test func discoversScreenshotAndPlayTimePathsTogether() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("CLV-U-ABCDE", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: folder.appendingPathComponent("game.sfc"))
        var game = Game(code: "CLV-U-ABCDE", desktopContent: "Name=Game\n", consoleType: .snesUsa, source: .local); game.romPath = folder.path
        let source = try SNESLibraryROMSource.capture(directory: folder, filename: "game.sfc").0
        let request = try SNESCompatibilityLaunchRequest.prepare(game: game, source: source, session: Data(repeating: 7, count: 16), epoch: 4)
        let image = "/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/state.png"
        let load = "/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/old.time"
        let save = "/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/state.time"
        func record(_ image: String, _ load: String, _ save: String) -> Data {
            let fields = ["", image, load, save].map { Array($0.utf8) }
            var data = Data("HCMGR2\0\0".utf8); data.append(request.frame)
            for field in fields { data.append(UInt8(field.count & 255)); data.append(UInt8(field.count >> 8)) }
            for field in fields { data.append(contentsOf: field) }; return data
        }
        func inventory(_ record: Data) -> Data {
            var data = Data("HCMINV2\0".utf8); data.append(contentsOf: [1, 0, UInt8(record.count & 255), UInt8(record.count >> 8)]); data.append(record); return data
        }
        let combined = record(image, load, save)
        if let path = ProcessInfo.processInfo.environment["HC_MANAGER_TIME_RECORD_OUTPUT"] {
            let actual = try Data(contentsOf: URL(fileURLWithPath: path))
            #expect(actual == combined)
            #expect(try SNESCompatibilityManagerInventory.parse(inventory(actual), game: game, source: source).sessions[0].time.savePath == save)
        }
        if let path = ProcessInfo.processInfo.environment["HC_MANAGER_TIME_INVENTORY_INPUT"] {
            let actual = try Data(contentsOf: URL(fileURLWithPath: path))
            let sessions = try SNESCompatibilityManagerInventory.parse(actual, game: game, source: source).sessions
            let matching = sessions.filter { $0.request.frame == request.frame }
            #expect(matching.count == 1 && matching[0].paths.imagePath == image && matching[0].time.loadPath == load && matching[0].time.savePath == save)
        }
        let result = try SNESCompatibilityManagerInventory.parse(inventory(combined), game: game, source: source)
        #expect(result.sessions.count == 1 && result.sessions[0].paths.imagePath == image)
        #expect(result.sessions[0].time.loadPath == load && result.sessions[0].time.savePath == save)
        let timeOnly = try SNESCompatibilityManagerInventory.parse(inventory(record("", load, save)), game: game, source: source)
        #expect(timeOnly.sessions[0].paths.imagePath == nil && timeOnly.sessions[0].time.savePath == save)
        let sharedTime = try SNESCompatibilityManagerInventory.parse(inventory(record(image, load, load)), game: game, source: source)
        #expect(sharedTime.sessions[0].time.loadPath == load && sharedTime.sessions[0].time.savePath == load)
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.observeManagerScreenshotRecord(combined, request: request) }
        #expect(try SNESRecoveryBinding.validateManagerScreenshotRecord(combined,request:request,expectedSavePath:nil,expectedImagePath:image))
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.validateManagerScreenshotRecord(record(image,load,image),request:request,expectedSavePath:nil,expectedImagePath:image) }
        var wrongSession=combined;wrongSession[wrongSession.startIndex+91] ^= 1
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.validateManagerScreenshotRecord(wrongSession,request:request,expectedSavePath:nil,expectedImagePath:image) }
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.validateManagerScreenshotRecord(combined.dropLast(),request:request,expectedSavePath:nil,expectedImagePath:image) }
        #expect(throws: (any Error).self) { try SNESCompatibilityManagerInventory.parse(inventory(record(image, load, image)), game: game, source: source) }
        let battery = "/var/lib/clover/profiles/0/\(game.code)/hakchi/\(SNESCompatibilityCorePackage.engineID)/\(source.sha256)/battery.srm"
        #expect(throws: (any Error).self) { try SNESCompatibilityManagerInventory.parse(inventory(record(image, load, battery)), game: game, source: source) }
        #expect(throws: (any Error).self) { try SNESCompatibilityManagerInventory.parse(inventory(record(image, "", "")), game: game, source: source) }
    }
    @Test func observesManagerSelectedStateAndRejectsAliasedInputs() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("CLV-U-ABCDE", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: folder.appendingPathComponent("game.sfc"))
        var game = Game(code: "CLV-U-ABCDE", desktopContent: "Name=Game\n", consoleType: .snesUsa, source: .local); game.romPath = folder.path
        let source = try SNESLibraryROMSource.capture(directory: folder, filename: "game.sfc").0
        let request = try SNESCompatibilityLaunchRequest.prepare(game: game, source: source, session: Data(repeating: 7, count: 16), epoch: 4)
        let selected = "/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint1/rollback/savestate"
        let image = "/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/state.png"
        let time = "/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/state.time"
        func record(_ input: String) -> Data {
            let fields = ["", image, "", time, input].map { Array($0.utf8) }
            var data = Data("HCMGR3\0\0".utf8); data.append(request.frame)
            for field in fields { data.append(UInt8(field.count & 255)); data.append(UInt8(field.count >> 8)) }
            for field in fields { data.append(contentsOf: field) }; return data
        }
        func inventory(_ record: Data) -> Data {
            var data = Data("HCMINV2\0".utf8); data.append(contentsOf: [1, 0, UInt8(record.count & 255), UInt8(record.count >> 8)]); data.append(record); return data
        }
        let observed = try SNESCompatibilityManagerInventory.parse(inventory(record(selected)), game: game, source: source)
        #expect(observed.sessions.count == 1 && observed.sessions[0].paths.loadPath == selected)
        #expect(observed.sessions[0].paths.imagePath == image && observed.sessions[0].time.savePath == time)
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.validateManagerScreenshotRecord(record(selected), request: request, expectedSavePath: nil, expectedImagePath: image) }
        #expect(try SNESRecoveryBinding.validateManagerScreenshotRecord(record(selected), request: request, expectedSavePath: nil, expectedImagePath: image, expectedLoadPath: selected))
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.validateManagerScreenshotRecord(record(selected), request: request, expectedSavePath: nil, expectedImagePath: image, expectedLoadPath: selected + "-other") }
        #expect(throws: (any Error).self) { try SNESCompatibilityManagerInventory.parse(inventory(record(image)), game: game, source: source) }
        let battery = "/var/lib/clover/profiles/0/\(game.code)/hakchi/\(SNESCompatibilityCorePackage.engineID)/\(source.sha256)/battery.srm"
        #expect(throws: (any Error).self) { try SNESCompatibilityManagerInventory.parse(inventory(record(battery)), game: game, source: source) }
        #expect(throws: (any Error).self) { try SNESCompatibilityManagerInventory.parse(inventory(record(time)), game: game, source: source) }
        #expect(throws: (any Error).self) { try SNESCompatibilityManagerInventory.parse(inventory(record("")), game: game, source: source) }
        if let path = ProcessInfo.processInfo.environment["HC_MANAGER_LOAD_RECORD_INPUT"] {
            let actual = try Data(contentsOf: URL(fileURLWithPath: path))
            #expect(actual == record(selected))
            #expect(try SNESCompatibilityManagerInventory.parse(inventory(actual), game: game, source: source).sessions[0].paths.loadPath == selected)
        }
    }
    @Test func observesActualStockSessionBindingFixture() throws {
        let env = ProcessInfo.processInfo.environment
        guard let bindingPath = env["HC_REAL_STOCK_BINDING"],
              let romPath = env["HC_REAL_STOCK_ROM"],
              let code = env["HC_REAL_STOCK_GAME"] else { return }
        let binding = URL(fileURLWithPath: bindingPath), parent = binding.deletingLastPathComponent()
        let rom = URL(fileURLWithPath: romPath), source = try SNESLibraryROMSource.capture(directory: rom.deletingLastPathComponent(), filename: rom.lastPathComponent).0
        let hex = String(binding.lastPathComponent.dropFirst(5))
        try #require(binding.lastPathComponent.hasPrefix("bind-") && hex.utf8.count == 32)
        var token = Data(); var offset = hex.startIndex
        for _ in 0..<16 {
            let end = hex.index(offset, offsetBy: 2)
            token.append(try #require(UInt8(hex[offset..<end], radix: 16))); offset = end
        }
        var info = stat(); try #require(stat(parent.path, &info) == 0)
        let device = UInt64(info.st_dev), inode = UInt64(info.st_ino)
        let regions = [SNESRecoveryBinding.Region(path: parent.appendingPathComponent("battery.srm").path, type: 0, device: device, inode: inode),
                       SNESRecoveryBinding.Region(path: parent.appendingPathComponent("battery.rtc").path, type: 1, device: device, inode: inode)]
        var game = Game(code: code, desktopContent: "Name=Fixture\n", consoleType: .snesUsa, source: .local); game.romPath = rom.deletingLastPathComponent().path
        let payload = Data("SAVE".utf8)
        let save = try SNESCompatibilitySave.create(payload: payload, kind: .battery, gameCode: code, romSHA256: source.sha256)
        let descriptor = try Data(contentsOf: binding)
        let result = try SNESRecoveryBinding.validate(descriptor: descriptor, save: save.bytes, kind: .battery, game: game, source: source, session: token, epoch: 1, regions: regions)
        #expect(result.payload == payload)
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.validate(descriptor: descriptor, save: save.bytes, kind: .battery, game: game, source: source, session: Data(repeating: 1, count: 16), epoch: 1, regions: regions) }
        if let metaPath = env["HC_REAL_STOCK_META"] {
            let record = try Data(contentsOf: URL(fileURLWithPath: metaPath)); try #require(record.count == 119)
            var inventory = Data("HCMINV2\0".utf8); inventory.append(contentsOf: [1, 0, UInt8(record.count), 0]); inventory.append(record)
            let observed = try SNESCompatibilityManagerInventory.parse(inventory, game: game, source: source)
            #expect(observed.sessions.count == 1 && observed.sessions[0].request.frame[83..<99].elementsEqual(token))
            #expect(observed.sessions[0].paths.savePath == nil && observed.sessions[0].paths.imagePath == nil)
        }
    }
    @Test func observesSaveOnlyManagerRecord() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let folder=root.appendingPathComponent("CLV-U-ABCDE",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try Data("abc".utf8).write(to:folder.appendingPathComponent("game.sfc"))
        var game=Game(code:"CLV-U-ABCDE",desktopContent:"Name=Game\n",consoleType:.snesUsa,source:.local);game.romPath=folder.path
        let source=try SNESLibraryROMSource.capture(directory:folder,filename:"game.sfc").0
        let request=try SNESCompatibilityLaunchRequest.prepare(game:game,source:source,session:Data(repeating:7,count:16),epoch:0x1234)
        let save="/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/state", bytes=Array(save.utf8)
        var record=Data("HCSHOT1\0".utf8);record.append(request.frame)
        record.append(contentsOf:[UInt8(bytes.count & 255),UInt8(bytes.count >> 8),0,0]);record.append(contentsOf:bytes)
        let paths=try SNESRecoveryBinding.observeManagerScreenshotRecord(record,request:request)
        #expect(paths.savePath==save && paths.imagePath == nil)
        var inventory=Data("HCMINV2\0".utf8);inventory.append(contentsOf:[1,0,UInt8(record.count & 255),UInt8(record.count >> 8)]);inventory.append(record)
        let observed=try SNESCompatibilityManagerInventory.parse(inventory,game:game,source:source)
        #expect(observed.sessions.count==1 && observed.sessions[0].paths.savePath==save)
        #expect(throws:(any Error).self){try SNESRecoveryBinding.validateManagerScreenshotRecord(record,request:request,expectedSavePath:save,expectedImagePath:save+".png")}
        let hex=request.frame[83..<99].map{String(format:"%02x",$0)}.joined(),base="/var/lib/clover/profiles/0/CLV-U-ABCDE/hakchi/\(SNESCompatibilityCorePackage.engineID)/\(source.sha256)"
        let ram=SNESRecoveryBinding.Region(path:base+"/battery.srm",type:0,device:5,inode:7),state=SNESRecoveryBinding.Region(path:base+"/state-\(hex).state",type:101,device:5,inode:7)
        let descriptor=Data("HC-BINDING-1\nCLV-U-ABCDE\n\(source.sha256)\n\(hex)\n4660\n2\n0 5 7 \(ram.path)\n101 5 7 \(state.path)\n".utf8),payload=Data("SAVE".utf8)
        let checked=try SNESRecoveryBinding.validateSessionRetainedState(descriptor:descriptor,managerRecord:record,request:request,game:game,regions:[ram,state],expectedManagerSavePath:save,expectedManagerImagePath:nil,state:payload,expectedSHA256:BackupManifest.digest(payload))
        #expect(checked.payload==payload)
        let rtc=SNESRecoveryBinding.Region(path:base+"/battery.rtc",type:1,device:5,inode:7)
        let full=Data("HC-BINDING-1\nCLV-U-ABCDE\n\(source.sha256)\n\(hex)\n4660\n3\n0 5 7 \(ram.path)\n1 5 7 \(rtc.path)\n101 5 7 \(state.path)\n".utf8)
        let workspace="checkpoint-123456789abcdef0123456789abcdef0"
        var reply=Data("HC-RETAINED-STATE-1\n5 7 \(full.count) 1 4\n".utf8);reply.append(full);reply.append(Data("ENTRY \(hex) \(workspace) state-\(hex).state 2 1\n".utf8));reply.append(payload);reply.append(Data("HC-RETAINED-STATE-END\n".utf8))
        let parsed=try SNESRetainedStateObservation.parse(reply,managerRecord:record,request:request,game:game,expectedManagerSavePath:save,expectedManagerImagePath:nil,expectedSHA256:BackupManifest.digest(payload))
        #expect(parsed.payload==payload)
        let stable=RecoveryReadSequence(frame:reply,changed:false)
        let captured=try await SNESRetainedStateObservation.capture(managerRecord:record,request:request,game:game,expectedManagerSavePath:save,expectedManagerImagePath:nil,expectedSHA256:BackupManifest.digest(payload),validate:{},read:{await stable.read()})
        #expect(captured.payload==payload);#expect(await stable.reads==2)
        let unstable=RecoveryReadSequence(frame:reply,changed:true)
        await #expect(throws:(any Error).self){try await SNESRetainedStateObservation.capture(managerRecord:record,request:request,game:game,expectedManagerSavePath:save,expectedManagerImagePath:nil,expectedSHA256:BackupManifest.digest(payload),validate:{},read:{await unstable.read()})}
        #expect(await unstable.reads==2)
        let interrupted=RecoveryReadSequence(frame:reply,changed:false),validation=RetainedValidationSequence()
        await #expect(throws:(any Error).self){try await SNESRetainedStateObservation.capture(managerRecord:record,request:request,game:game,expectedManagerSavePath:save,expectedManagerImagePath:nil,expectedSHA256:BackupManifest.digest(payload),validate:{try await validation.check()},read:{await interrupted.read()})}
        #expect(await interrupted.reads==1)
        let oversized=RecoveryReadSequence(frame:Data(count:16*1024*1024+24577),changed:false)
        await #expect(throws:(any Error).self){try await SNESRetainedStateObservation.capture(managerRecord:record,request:request,game:game,expectedManagerSavePath:save,expectedManagerImagePath:nil,expectedSHA256:BackupManifest.digest(payload),validate:{},read:{await oversized.read()})}
        #expect(await oversized.reads==1)
        #expect(throws:(any Error).self){try SNESRetainedStateObservation.parse(reply.dropLast(),managerRecord:record,request:request,game:game,expectedManagerSavePath:save,expectedManagerImagePath:nil,expectedSHA256:BackupManifest.digest(payload))}
        #expect(throws:(any Error).self){try SNESRetainedStateObservation.parse(reply,managerRecord:record,request:request,game:game,expectedManagerSavePath:save,expectedManagerImagePath:nil,expectedSHA256:String(repeating:"0",count:64))}
        var badEntry=Data("HC-RETAINED-STATE-1\n5 7 \(full.count) 1 4\n".utf8);badEntry.append(full);badEntry.append(Data("ENTRY \(String(repeating:"0",count:32)) \(workspace) state-\(hex).state 2 1\n".utf8));badEntry.append(payload);badEntry.append(Data("HC-RETAINED-STATE-END\n".utf8))
        #expect(throws:(any Error).self){try SNESRetainedStateObservation.parse(badEntry,managerRecord:record,request:request,game:game,expectedManagerSavePath:save,expectedManagerImagePath:nil,expectedSHA256:BackupManifest.digest(payload))}
        #expect(throws:(any Error).self){try SNESRetainedStateObservation.parse(reply+Data([0]),managerRecord:record,request:request,game:game,expectedManagerSavePath:save,expectedManagerImagePath:nil,expectedSHA256:BackupManifest.digest(payload))}
        let imagePath=save+".png", imageBytes=Array(imagePath.utf8),image=SNESRecoveryBinding.Region(path:base+"/shot-\(hex).png",type:100,device:5,inode:7)
        var pairedRecord=Data("HCSHOT1\0".utf8);pairedRecord.append(request.frame);pairedRecord.append(contentsOf:[UInt8(bytes.count & 255),UInt8(bytes.count >> 8),UInt8(imageBytes.count & 255),UInt8(imageBytes.count >> 8)]);pairedRecord.append(contentsOf:bytes);pairedRecord.append(contentsOf:imageBytes)
        let fullPaired=Data("HC-BINDING-1\nCLV-U-ABCDE\n\(source.sha256)\n\(hex)\n4660\n4\n0 5 7 \(ram.path)\n1 5 7 \(rtc.path)\n101 5 7 \(state.path)\n100 5 7 \(image.path)\n".utf8)
        var pairedReply=Data("HC-RETAINED-STATE-1\n5 7 \(fullPaired.count) 1 4\n".utf8);pairedReply.append(fullPaired);pairedReply.append(Data("ENTRY \(hex) \(workspace) state-\(hex).state 2 1\n".utf8));pairedReply.append(payload);pairedReply.append(Data("HC-RETAINED-STATE-END\n".utf8))
        #expect(try SNESRetainedStateObservation.parse(pairedReply,managerRecord:pairedRecord,request:request,game:game,expectedManagerSavePath:save,expectedManagerImagePath:imagePath,expectedSHA256:BackupManifest.digest(payload)).payload==payload)
        #expect(throws:(any Error).self){try SNESRetainedStateObservation.parse(pairedReply,managerRecord:pairedRecord,request:request,game:game,expectedManagerSavePath:save,expectedManagerImagePath:nil,expectedSHA256:BackupManifest.digest(payload))}
        #expect(throws:(any Error).self){try SNESRecoveryBinding.validateSessionRetainedState(descriptor:descriptor,managerRecord:record,request:request,game:game,regions:[ram,state],expectedManagerSavePath:save+"x",expectedManagerImagePath:nil,state:payload,expectedSHA256:BackupManifest.digest(payload))}
        var empty=Data("HCSHOT1\0".utf8);empty.append(request.frame);empty.append(contentsOf:[0,0,0,0])
        #expect(throws:(any Error).self){try SNESRecoveryBinding.observeManagerScreenshotRecord(empty,request:request)}
        #expect(throws:(any Error).self){try SNESRecoveryBinding.observeManagerScreenshotRecord(record.dropLast(),request:request)}
        if let path=ProcessInfo.processInfo.environment["HC_E2E_SAVE_ONLY_CAPTURE"],!path.isEmpty {
            let console=try SNESRecoveryBinding.observeConsoleManagerScreenshotRecord(Data(contentsOf:URL(fileURLWithPath:path)),game:game,source:source)
            #expect(console.paths.savePath==save && console.paths.imagePath == nil)
        }
        let stateConnection=RecoveryFinalValidation(failOnFourth:true)
        await #expect(throws:(any Error).self){try await SNESRetainedStateObservation.capture(managerRecord:record,request:request,game:game,expectedManagerSavePath:save,expectedManagerImagePath:nil,expectedSHA256:BackupManifest.digest(payload),validate:{try await stateConnection.check()},read:{reply})}
        let stateSource=RecoveryFinalSourceMutation(url:source.directory.appendingPathComponent(source.filename))
        await #expect(throws:(any Error).self){try await SNESRetainedStateObservation.capture(managerRecord:record,request:request,game:game,expectedManagerSavePath:save,expectedManagerImagePath:nil,expectedSHA256:BackupManifest.digest(payload),validate:{try await stateSource.check()},read:{reply})}
    }
    @Test func produceSupervisorRequestFixture() throws {
        guard let path=ProcessInfo.processInfo.environment["HC_ENTRY_REQUEST_OUTPUT"],!path.isEmpty else {return}
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let folder=root.appendingPathComponent("CLV-U-ABCDE",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try Data("abc".utf8).write(to:folder.appendingPathComponent("game.sfc"))
        var game=Game(code:"CLV-U-ABCDE",desktopContent:"Name=Game\n",consoleType:.snesUsa,source:.local);game.romPath=folder.path
        let source=try SNESLibraryROMSource.capture(directory:folder,filename:"game.sfc").0
        let request=try SNESCompatibilityLaunchRequest.prepare(game:game,source:source,session:Data(repeating:7,count:16),epoch:0x1234)
        try request.frame.write(to:URL(fileURLWithPath:path),options:.withoutOverwriting)
    }
    @Test func observeConsoleCreatedManagerRecordFixture() throws {
        guard let path=ProcessInfo.processInfo.environment["HC_CONSOLE_CREATED_RECORD"],!path.isEmpty else {return}
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let folder=root.appendingPathComponent("CLV-U-ABCDE",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try Data("abc".utf8).write(to:folder.appendingPathComponent("game.sfc"))
        let source=try SNESLibraryROMSource.capture(directory:folder,filename:"game.sfc").0
        var game=Game(code:"CLV-U-ABCDE",desktopContent:"Name=Game\n",consoleType:.snesUsa,source:.local);game.romPath=folder.path
        let result=try SNESRecoveryBinding.observeConsoleManagerScreenshotRecord(Data(contentsOf:URL(fileURLWithPath:path)),game:game,source:source)
        #expect(result.request.frame.count==107 && result.request.frame[83..<99].contains(where:{$0 != 0}))
        #expect(result.paths.imagePath=="/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/state.png")
        #expect(result.paths.savePath=="/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/rollback/savestate")
    }
    @Test func observeConsoleManagerInventoryFixture() throws {
        guard let path=ProcessInfo.processInfo.environment["HC_CONSOLE_INVENTORY"],!path.isEmpty else {return}
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let folder=root.appendingPathComponent("CLV-U-ABCDE",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try Data("abc".utf8).write(to:folder.appendingPathComponent("game.sfc"))
        let source=try SNESLibraryROMSource.capture(directory:folder,filename:"game.sfc").0
        var game=Game(code:"CLV-U-ABCDE",desktopContent:"Name=Game\n",consoleType:.snesUsa,source:.local);game.romPath=folder.path
        let data=try Data(contentsOf:URL(fileURLWithPath:path))
        let command=try SNESCompatibilityManagerInventory.prepare(game:game,source:source,helperSHA256:String(repeating:"0",count:64))
        #expect(command.contains("--observe-manager-inventory 'CLV-U-ABCDE' '\(source.sha256)'"))
        #expect(throws:(any Error).self){try SNESCompatibilityManagerInventory.prepare(game:game,source:source,helperSHA256:"bad")}
        let observed=try SNESCompatibilityManagerInventory.parse(data,game:game,source:source)
        #expect(observed.sessions.count==1 && observed.sessions[0].paths.imagePath?.hasSuffix("/state.png")==true)
        #expect(observed.incompleteWorkspaces==["checkpoint-ffffffffffffffffffffffffffffffff"])
        #expect(throws:(any Error).self){try SNESCompatibilityManagerInventory.parse(data+Data([0]),game:game,source:source)}
        #expect(throws:(any Error).self){try SNESCompatibilityManagerInventory.parse(data.dropLast(),game:game,source:source)}
        var duplicate=Data(data.prefix(10));duplicate[8]=4;duplicate.append(data.dropFirst(10));duplicate.append(data.dropFirst(10))
        #expect(throws:(any Error).self){try SNESCompatibilityManagerInventory.parse(duplicate,game:game,source:source)}
        let token=observed.sessions[0].request.frame[83..<99].map{String(format:"%02x",$0)}.joined()
        var alias=data;alias[8]=3;alias.append(contentsOf:[43,0]);alias.append(Data(("checkpoint-"+token).utf8))
        #expect(throws:(any Error).self){try SNESCompatibilityManagerInventory.parse(alias,game:game,source:source)}
        var wrongGame=Game(code:"CLV-U-ABCDF",desktopContent:"Name=Game\n",consoleType:.snesUsa,source:.local);wrongGame.romPath=folder.path
        #expect(throws:(any Error).self){try SNESCompatibilityManagerInventory.parse(data,game:wrongGame,source:source)}
    }
    @Test func managerRecordMatchesHostSupervisorFixture() throws {
        guard let path=ProcessInfo.processInfo.environment["HC_ENTRY_RECORD_OUTPUT"],!path.isEmpty else {return}
        let record=try Data(contentsOf:URL(fileURLWithPath:path));try #require(record.count>=119)
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let folder=root.appendingPathComponent("CLV-U-ABCDE",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try Data("abc".utf8).write(to:folder.appendingPathComponent("game.sfc"))
        let source=try SNESLibraryROMSource.capture(directory:folder,filename:"game.sfc").0
        let reviewed=try #require(ProcessInfo.processInfo.environment["HC_ENTRY_REQUEST_INPUT"])
        let frame=try Data(contentsOf:URL(fileURLWithPath:reviewed));#expect(Data(record[8..<115])==frame)
        let request=SNESCompatibilityLaunchRequest(frame:frame,source:source)
        let save="/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/rollback/savestate"
        let image="/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/state.png"
        let observed=try SNESRecoveryBinding.observeManagerScreenshotRecord(record,request:request)
        #expect(observed.savePath==save && observed.imagePath==image)
        var localGame=Game(code:"CLV-U-ABCDE",desktopContent:"Name=Game\n",consoleType:.snesUsa,source:.local)
        localGame.romPath=folder.path
        let offline=try SNESRecoveryBinding.observeConsoleManagerScreenshotRecord(record,game:localGame,source:source)
        #expect(offline.request.frame==frame && offline.paths==observed)
        #expect(try SNESRecoveryBinding.validateManagerScreenshotRecord(record,request:request,expectedSavePath:save,expectedImagePath:image))
        #expect(throws:(any Error).self){try SNESRecoveryBinding.validateManagerScreenshotRecord(record,request:request,expectedSavePath:save,expectedImagePath:image+"x")}
        var modified=request.frame;modified[83]^=1
        let wrong=SNESCompatibilityLaunchRequest(frame:modified,source:source)
        #expect(throws:(any Error).self){try SNESRecoveryBinding.observeManagerScreenshotRecord(record,request:wrong)}
        #expect(throws:(any Error).self){try SNESRecoveryBinding.validateManagerScreenshotRecord(record,request:wrong,expectedSavePath:save,expectedImagePath:image)}
        let base="/var/lib/clover/profiles/0/CLV-U-ABCDE/hakchi/\(SNESCompatibilityCorePackage.engineID)/\(source.sha256)"
        let ram=SNESRecoveryBinding.Region(path:base+"/battery.srm",type:0,device:123,inode:456)
        let retained=SNESRecoveryBinding.Region(path:base+"/retained.png",type:100,device:123,inode:456)
        let token=request.frame[83..<99].map{String(format:"%02x",$0)}.joined()
        let descriptor=Data("HC-BINDING-1\nCLV-U-ABCDE\n\(source.sha256)\n\(token)\n4660\n2\n0 123 456 \(ram.path)\n100 123 456 \(retained.path)\n".utf8)
        let context=try #require(CGContext(data:nil,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        let pixel=try #require(context.makeImage()),output=NSMutableData()
        let destination=try #require(CGImageDestinationCreateWithData(output,"public.png" as CFString,1,nil))
        CGImageDestinationAddImage(destination,pixel,nil);#expect(CGImageDestinationFinalize(destination))
        let png=output as Data
        #expect(try SNESRecoveryBinding.validateRetainedScreenshot(descriptor:descriptor,managerRecord:record,request:request,regions:[ram,retained],expectedRetainedPath:retained.path,expectedManagerSavePath:save,expectedManagerImagePath:image,image:png,expectedSHA256:BackupManifest.digest(png))==png)
    }
    @Test func stagedScreenshotRequiresMatchingGameSessionPathAndImage() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, _, request, _) = try await fixture(root, includeSave: false)
        let base = "/var/lib/clover/profiles/0/CLV-U-ABCDE/hakchi/\(SNESCompatibilityCorePackage.engineID)/\(request.source.sha256)"
        let ram = SNESRecoveryBinding.Region(path: base + "/battery.srm", type: 0, device: 123, inode: 456)
        let image = SNESRecoveryBinding.Region(path: base + "/game.state.png", type: 100, device: 123, inode: 456)
        let token = request.frame[83..<99].map { String(format: "%02x", $0) }.joined()
        let descriptor = Data("HC-BINDING-1\nCLV-U-ABCDE\n\(request.source.sha256)\n\(token)\n2\n2\n0 123 456 \(ram.path)\n100 123 456 \(image.path)\n".utf8)
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let pixel = try #require(context.makeImage()), output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pixel, nil); #expect(CGImageDestinationFinalize(destination))
        let png = output as Data, digest = BackupManifest.digest(png)
        let candidate = try SNESRecoveryBinding.validateStagedScreenshot(descriptor: descriptor, request: request,
            regions: [ram, image], expectedImagePath: image.path, image: png, expectedSHA256: digest)
        #expect(candidate == png)
        let cachePath = "/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/state.png"
        let cachedImage = SNESRecoveryBinding.Region(path: cachePath, type: 100, device: 222, inode: 333)
        let cacheDescriptor = Data("HC-BINDING-1\nCLV-U-ABCDE\n\(request.source.sha256)\n\(token)\n2\n2\n0 123 456 \(ram.path)\n100 222 333 \(cachePath)\n".utf8)
        let pairedImage=SNESRecoveryBinding.Region(path:cachePath,type:103,device:222,inode:333)
        let pairedRetained=SNESRecoveryBinding.Region(path:base+"/retained.png",type:100,device:123,inode:456)
        let pairedDescriptor=Data("HC-BINDING-1\nCLV-U-ABCDE\n\(request.source.sha256)\n\(token)\n2\n3\n0 123 456 \(ram.path)\n103 222 333 \(cachePath)\n100 123 456 \(pairedRetained.path)\n".utf8)
        #expect(try SNESRecoveryBinding.validateStagedScreenshot(descriptor:pairedDescriptor,request:request,regions:[ram,pairedImage,pairedRetained],expectedImagePath:cachePath,image:png,expectedSHA256:digest)==png)
        let savePath = "/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/rollback/savestate"
        let saveBytes = Data(savePath.utf8), imageBytes = Data(cachePath.utf8)
        var managerRecord=Data("HCSHOT1\0".utf8);managerRecord.append(request.frame)
        managerRecord.append(contentsOf:[UInt8(saveBytes.count & 255),UInt8(saveBytes.count >> 8),UInt8(imageBytes.count & 255),UInt8(imageBytes.count >> 8)])
        managerRecord.append(saveBytes);managerRecord.append(imageBytes)
        let observed=try SNESRecoveryBinding.observeManagerScreenshotRecord(managerRecord,request:request)
        #expect(observed.savePath==savePath && observed.imagePath==cachePath)
        let wrongRetained=SNESRecoveryBinding.Region(path:pairedRetained.path,type:103,device:123,inode:456)
        let wrongRetainedDescriptor=Data("HC-BINDING-1\nCLV-U-ABCDE\n\(request.source.sha256)\n\(token)\n2\n2\n0 123 456 \(ram.path)\n103 123 456 \(wrongRetained.path)\n".utf8)
        #expect(throws:(any Error).self){try SNESRecoveryBinding.validateRetainedScreenshot(descriptor:wrongRetainedDescriptor,managerRecord:managerRecord,request:request,regions:[ram,wrongRetained],expectedRetainedPath:wrongRetained.path,expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,image:png,expectedSHA256:digest)}
        var localGame=Game(code:"CLV-U-ABCDE",desktopContent:"Name=Game\n",consoleType:.snesUsa,source:.local)
        localGame.romPath=request.source.directory.path
        let offline=try SNESRecoveryBinding.observeConsoleManagerScreenshotRecord(managerRecord,game:localGame,source:request.source)
        #expect(offline.request.frame==request.frame && offline.paths==observed)
        let slicedRequest=SNESCompatibilityLaunchRequest(frame:(Data([0])+request.frame).dropFirst(),source:request.source)
        #expect(try SNESRecoveryBinding.observeManagerScreenshotRecord(managerRecord,request:slicedRequest)==observed)
        var foreign=managerRecord
        let foreignManagerPath=cachePath.replacingOccurrences(of:"CLV-U-ABCDE",with:"CLV-U-ABCDF")
        foreign.replaceSubrange((119+saveBytes.count)..<foreign.count,with:Data(foreignManagerPath.utf8))
        #expect(throws:(any Error).self){try SNESRecoveryBinding.observeManagerScreenshotRecord(foreign,request:request)}
        #expect(throws:(any Error).self){try SNESRecoveryBinding.observeConsoleManagerScreenshotRecord(foreign,game:localGame,source:request.source)}
        #expect(throws:(any Error).self){try SNESRecoveryBinding.observeManagerScreenshotRecord(managerRecord.dropLast(),request:request)}
        #expect(try SNESRecoveryBinding.validateManagerScreenshotRecord(managerRecord, request: request,
            expectedSavePath: savePath, expectedImagePath: cachePath))
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.validateManagerScreenshotRecord(managerRecord, request: request,
            expectedSavePath: savePath, expectedImagePath: cachePath + "x") }
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.validateManagerScreenshotRecord(managerRecord + Data([0]), request: request,
            expectedSavePath: savePath, expectedImagePath: cachePath) }
        #expect(try SNESRecoveryBinding.validateRetainedScreenshot(descriptor: descriptor, managerRecord: managerRecord, request: request,
            regions: [ram, image], expectedRetainedPath: image.path, expectedManagerSavePath: savePath,
            expectedManagerImagePath: cachePath, image: png, expectedSHA256: digest) == png)
        let sessionPath = base + "/shot-\(token).png"
        let sessionImage = SNESRecoveryBinding.Region(path: sessionPath, type: 100, device: 123, inode: 456)
        let sessionState=SNESRecoveryBinding.Region(path:base+"/state-\(token).state",type:101,device:123,inode:456)
        let rtc=SNESRecoveryBinding.Region(path:base+"/battery.rtc",type:1,device:123,inode:456)
        let imageDescriptor=Data("HC-BINDING-1\nCLV-U-ABCDE\n\(request.source.sha256)\n\(token)\n2\n4\n0 123 456 \(ram.path)\n1 123 456 \(rtc.path)\n101 123 456 \(sessionState.path)\n100 123 456 \(sessionImage.path)\n".utf8)
        let imageWorkspace="checkpoint-123456789abcdef0123456789abcdef0"
        var imageReply=Data("HC-RETAINED-IMAGE-1\n123 456 \(imageDescriptor.count) 1 \(png.count)\n".utf8);imageReply.append(imageDescriptor);imageReply.append(Data("ENTRY \(token) \(imageWorkspace) shot-\(token).png 2 1\n".utf8));imageReply.append(png);imageReply.append(Data("HC-RETAINED-IMAGE-END\n".utf8))
        #expect(try SNESRetainedImageObservation.parse(imageReply,managerRecord:managerRecord,request:request,expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,expectedSHA256:digest)==png)
        var retiredReply=Data("HC-RETIRED-IMAGE-1\n123 456 \(imageDescriptor.count) 0 \(png.count)\n".utf8);retiredReply.append(imageDescriptor);retiredReply.append(png);retiredReply.append(Data("HC-RETIRED-IMAGE-END\n".utf8))
        #expect(throws:(any Error).self){try SNESRetainedImageObservation.parse(retiredReply,managerRecord:managerRecord,request:request,expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,expectedSHA256:digest)}
        #expect(try SNESRetainedImageObservation.parse(retiredReply,managerRecord:managerRecord,request:request,expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,expectedSHA256:digest,retired:true)==png)
        #expect(throws:(any Error).self){try SNESRetainedImageObservation.parse(retiredReply,managerRecord:managerRecord,request:request,expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,expectedSHA256:String(repeating:"0",count:64),retired:true)}
        #expect(throws:(any Error).self){try SNESRetainedImageObservation.parse(imageReply,managerRecord:managerRecord,request:request,expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,expectedSHA256:digest,retired:true)}
        let stableRetired=RecoveryReadSequence(frame:retiredReply,changed:false)
        #expect(try await SNESRetainedImageObservation.capture(managerRecord:managerRecord,request:request,expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,expectedSHA256:digest,retired:true,validate:{},read:{await stableRetired.read()})==png)
        #expect(await stableRetired.reads==2)
        let changedRetired=RecoveryReadSequence(frame:retiredReply,changed:true)
        await #expect(throws:(any Error).self){try await SNESRetainedImageObservation.capture(managerRecord:managerRecord,request:request,expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,expectedSHA256:digest,retired:true,validate:{},read:{await changedRetired.read()})}
        let timeBytes=Data("/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/state.time".utf8)
        var combinedRecord=Data("HCMGR2\0\0".utf8);combinedRecord.append(request.frame)
        for field in [saveBytes,imageBytes,Data(),timeBytes] { combinedRecord.append(UInt8(field.count & 255));combinedRecord.append(UInt8(field.count >> 8)) }
        for field in [saveBytes,imageBytes,Data(),timeBytes] { combinedRecord.append(field) }
        let selectedPath = "/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint1/rollback/savestate"
        let selectedBytes = Data(selectedPath.utf8)
        var resumedRecord=Data("HCMGR3\0\0".utf8);resumedRecord.append(request.frame)
        for field in [saveBytes,imageBytes,Data(),timeBytes,selectedBytes] { resumedRecord.append(UInt8(field.count & 255));resumedRecord.append(UInt8(field.count >> 8)) }
        for field in [saveBytes,imageBytes,Data(),timeBytes,selectedBytes] { resumedRecord.append(field) }
        #expect(throws:(any Error).self){try SNESRetainedImageObservation.parse(retiredReply,managerRecord:resumedRecord,request:request,expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,expectedSHA256:digest,retired:true)}
        #expect(try SNESRetainedImageObservation.parse(retiredReply,managerRecord:resumedRecord,request:request,expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,expectedSHA256:digest,retired:true,expectedManagerLoadPath:selectedPath)==png)
        #expect(throws:(any Error).self){try SNESRetainedImageObservation.parse(retiredReply,managerRecord:resumedRecord,request:request,expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,expectedSHA256:digest,retired:true,expectedManagerLoadPath:selectedPath+"-wrong")}
        #expect(throws:(any Error).self){try SNESRetainedImageObservation.parse(retiredReply,managerRecord:combinedRecord,request:request,expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,expectedSHA256:digest,retired:true,expectedManagerLoadPath:selectedPath)}
        let resumedImage=RecoveryReadSequence(frame:retiredReply,changed:false)
        #expect(try await SNESRetainedImageObservation.capture(managerRecord:resumedRecord,request:request,expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,expectedSHA256:digest,retired:true,expectedManagerLoadPath:selectedPath,validate:{},read:{await resumedImage.read()})==png)
        #expect(await resumedImage.reads==2)
        #expect(try SNESRetainedImageObservation.parse(imageReply,managerRecord:combinedRecord,request:request,expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,expectedSHA256:digest)==png)
        #expect(throws:(any Error).self){try SNESRetainedImageObservation.parse(imageReply,managerRecord:combinedRecord,request:request,expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath+"x",expectedSHA256:digest)}
        #expect(throws:(any Error).self){try SNESRetainedImageObservation.parse(imageReply.dropLast(),managerRecord:managerRecord,request:request,expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,expectedSHA256:digest)}
        #expect(throws:(any Error).self){try SNESRetainedImageObservation.parse(imageReply,managerRecord:managerRecord,request:request,expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,expectedSHA256:String(repeating:"0",count:64))}
        var corruptImage=png;corruptImage[corruptImage.startIndex] ^= 1
        var corruptReply=imageReply;let payloadStart=corruptReply.count-Data("HC-RETAINED-IMAGE-END\n".utf8).count-png.count;corruptReply.replaceSubrange(payloadStart..<(payloadStart+png.count),with:corruptImage)
        #expect(throws:(any Error).self){try SNESRetainedImageObservation.parse(corruptReply,managerRecord:managerRecord,request:request,expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,expectedSHA256:BackupManifest.digest(corruptImage))}
        let stableImage=RecoveryReadSequence(frame:imageReply,changed:false)
        #expect(try await SNESRetainedImageObservation.capture(managerRecord:managerRecord,request:request,expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,expectedSHA256:digest,validate:{},read:{await stableImage.read()})==png)
        #expect(await stableImage.reads==2)
        let stableConnection = RecoveryFinalValidation(failOnFourth: false)
        #expect(try await SNESRetainedImageObservation.capture(managerRecord:managerRecord,request:request,expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,expectedSHA256:digest,validate:{try await stableConnection.check()},read:{imageReply}) == png)
        #expect(await stableConnection.checks == 4)
        let disconnectedAfterParsing = RecoveryFinalValidation(failOnFourth: true)
        await #expect(throws:(any Error).self){try await SNESRetainedImageObservation.capture(managerRecord:managerRecord,request:request,expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,expectedSHA256:digest,validate:{try await disconnectedAfterParsing.check()},read:{imageReply})}
        let changedImage=RecoveryReadSequence(frame:imageReply,changed:true)
        await #expect(throws:(any Error).self){try await SNESRetainedImageObservation.capture(managerRecord:managerRecord,request:request,expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,expectedSHA256:digest,validate:{},read:{await changedImage.read()})}
        #expect(await changedImage.reads==2)
        var onlyRecord=Data("HCSHOT1\0".utf8);onlyRecord.append(request.frame);onlyRecord.append(contentsOf:[0,0,UInt8(imageBytes.count & 255),UInt8(imageBytes.count >> 8)]);onlyRecord.append(imageBytes)
        let onlyDescriptor=Data("HC-BINDING-1\nCLV-U-ABCDE\n\(request.source.sha256)\n\(token)\n2\n3\n0 123 456 \(ram.path)\n1 123 456 \(rtc.path)\n100 123 456 \(sessionImage.path)\n".utf8)
        var onlyReply=Data("HC-RETAINED-IMAGE-1\n123 456 \(onlyDescriptor.count) 1 \(png.count)\n".utf8);onlyReply.append(onlyDescriptor);onlyReply.append(Data("ENTRY \(token) \(imageWorkspace) shot-\(token).png 2 1\n".utf8));onlyReply.append(png);onlyReply.append(Data("HC-RETAINED-IMAGE-END\n".utf8))
        #expect(try SNESRetainedImageObservation.parse(onlyReply,managerRecord:onlyRecord,request:request,expectedManagerSavePath:nil,expectedManagerImagePath:cachePath,expectedSHA256:digest)==png)
        #expect(throws:(any Error).self){try SNESRetainedImageObservation.parse(onlyReply,managerRecord:onlyRecord,request:request,expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,expectedSHA256:digest)}
        let offlineDescriptor=Data("HC-BINDING-1\nCLV-U-ABCDE\n\(request.source.sha256)\n\(token)\n2\n3\n0 123 456 \(ram.path)\n101 123 456 \(sessionState.path)\n100 123 456 \(sessionImage.path)\n".utf8)
        #expect(try SNESRecoveryBinding.validateSessionRetainedScreenshot(descriptor:offlineDescriptor,managerRecord:managerRecord,request:request,regions:[ram,sessionState,sessionImage],expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,image:png,expectedSHA256:digest)==png)
        let retainedState=Data("SAVE".utf8),stateDigest=BackupManifest.digest(retainedState)
        #expect(throws:(any Error).self){try SNESRecoveryBinding.validateSessionRetainedState(descriptor:offlineDescriptor,managerRecord:resumedRecord,request:request,game:localGame,regions:[ram,sessionState,sessionImage],expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,state:retainedState,expectedSHA256:stateDigest)}
        #expect(try SNESRecoveryBinding.validateSessionRetainedState(descriptor:offlineDescriptor,managerRecord:resumedRecord,request:request,game:localGame,regions:[ram,sessionState,sessionImage],expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,state:retainedState,expectedSHA256:stateDigest,expectedManagerLoadPath:selectedPath).payload==retainedState)
        #expect(throws:(any Error).self){try SNESRecoveryBinding.validateSessionRetainedState(descriptor:offlineDescriptor,managerRecord:resumedRecord,request:request,game:localGame,regions:[ram,sessionState,sessionImage],expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,state:retainedState,expectedSHA256:stateDigest,expectedManagerLoadPath:selectedPath+"-wrong")}
        var resumedStateReply=Data("HC-RETAINED-STATE-1\n123 456 \(imageDescriptor.count) 1 \(retainedState.count)\n".utf8);resumedStateReply.append(imageDescriptor);resumedStateReply.append(Data("ENTRY \(token) \(imageWorkspace) state-\(token).state 2 1\n".utf8));resumedStateReply.append(retainedState);resumedStateReply.append(Data("HC-RETAINED-STATE-END\n".utf8))
        let resumedStateRead=RecoveryReadSequence(frame:resumedStateReply,changed:false)
        #expect(try await SNESRetainedStateObservation.capture(managerRecord:resumedRecord,request:request,game:localGame,expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,expectedSHA256:stateDigest,expectedManagerLoadPath:selectedPath,validate:{},read:{await resumedStateRead.read()}).payload==retainedState)
        #expect(await resumedStateRead.reads==2)
        #expect(throws:(any Error).self){try SNESRetainedStateObservation.parse(resumedStateReply,managerRecord:resumedRecord,request:request,game:localGame,expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,expectedSHA256:stateDigest)}
        let checkedState=try SNESRecoveryBinding.validateSessionRetainedState(descriptor:offlineDescriptor,managerRecord:managerRecord,request:request,game:localGame,regions:[ram,sessionState,sessionImage],expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,state:retainedState,expectedSHA256:stateDigest)
        #expect(checkedState.payload==retainedState)
        let combinedState=try SNESRecoveryBinding.validateSessionRetainedState(descriptor:offlineDescriptor,managerRecord:combinedRecord,request:request,game:localGame,regions:[ram,sessionState,sessionImage],expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,state:retainedState,expectedSHA256:stateDigest)
        #expect(combinedState.payload==retainedState)
        #expect(throws:(any Error).self){try SNESRecoveryBinding.validateSessionRetainedState(descriptor:offlineDescriptor,managerRecord:managerRecord,request:request,game:localGame,regions:[ram,sessionState,sessionImage],expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,state:retainedState,expectedSHA256:String(repeating:"0",count:64))}
        let wrongState=SNESRecoveryBinding.Region(path:base+"/state-other.state",type:101,device:123,inode:456)
        let wrongStateDescriptor=Data("HC-BINDING-1\nCLV-U-ABCDE\n\(request.source.sha256)\n\(token)\n2\n3\n0 123 456 \(ram.path)\n101 123 456 \(wrongState.path)\n100 123 456 \(sessionImage.path)\n".utf8)
        #expect(throws:(any Error).self){try SNESRecoveryBinding.validateSessionRetainedState(descriptor:wrongStateDescriptor,managerRecord:managerRecord,request:request,game:localGame,regions:[ram,wrongState,sessionImage],expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,state:retainedState,expectedSHA256:stateDigest)}
        let sessionDescriptor = Data("HC-BINDING-1\nCLV-U-ABCDE\n\(request.source.sha256)\n\(token)\n2\n2\n0 123 456 \(ram.path)\n100 123 456 \(sessionPath)\n".utf8)
        #expect(try SNESRecoveryBinding.validateSessionRetainedScreenshot(descriptor: sessionDescriptor, managerRecord: managerRecord, request: request,
            regions: [ram, sessionImage], expectedManagerSavePath: savePath, expectedManagerImagePath: cachePath, image: png, expectedSHA256: digest) == png)
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.validateSessionRetainedScreenshot(descriptor: descriptor, managerRecord: managerRecord, request: request,
            regions: [ram, image], expectedManagerSavePath: savePath, expectedManagerImagePath: cachePath, image: png, expectedSHA256: digest) }
        let volatileRetained = "/var/cache/clover/volatile/CLV-U-ABCDE/retained.png"
        let volatileRegion = SNESRecoveryBinding.Region(path: volatileRetained, type: 100, device: 222, inode: 333)
        let volatileDescriptor = Data("HC-BINDING-1\nCLV-U-ABCDE\n\(request.source.sha256)\n\(token)\n2\n2\n0 123 456 \(ram.path)\n100 222 333 \(volatileRetained)\n".utf8)
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.validateRetainedScreenshot(descriptor: volatileDescriptor, managerRecord: managerRecord, request: request,
            regions: [ram, volatileRegion], expectedRetainedPath: volatileRetained, expectedManagerSavePath: savePath,
            expectedManagerImagePath: cachePath, image: png, expectedSHA256: digest) }
        let wrongROMPath = "/var/lib/clover/profiles/0/CLV-U-ABCDE/hakchi/\(SNESCompatibilityCorePackage.engineID)/\(String(repeating: "0", count: 64))/retained.png"
        let wrongROMImage = SNESRecoveryBinding.Region(path: wrongROMPath, type: 100, device: 123, inode: 456)
        let wrongROMDescriptor = Data("HC-BINDING-1\nCLV-U-ABCDE\n\(request.source.sha256)\n\(token)\n2\n2\n0 123 456 \(ram.path)\n100 123 456 \(wrongROMPath)\n".utf8)
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.validateRetainedScreenshot(descriptor: wrongROMDescriptor, managerRecord: managerRecord, request: request,
            regions: [ram, wrongROMImage], expectedRetainedPath: wrongROMPath, expectedManagerSavePath: savePath,
            expectedManagerImagePath: cachePath, image: png, expectedSHA256: digest) }
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.validateRetainedScreenshot(descriptor: descriptor, managerRecord: managerRecord, request: request,
            regions: [ram, image], expectedRetainedPath: image.path, expectedManagerSavePath: savePath,
            expectedManagerImagePath: cachePath + "x", image: png, expectedSHA256: digest) }
        #expect(try SNESRecoveryBinding.validateStagedScreenshot(descriptor: cacheDescriptor, request: request,
            regions: [ram, cachedImage], expectedImagePath: cachePath, image: png, expectedSHA256: digest) == png)
        let foreignPath = cachePath.replacingOccurrences(of: "CLV-U-ABCDE", with: "CLV-U-WRONG")
        let foreignImage = SNESRecoveryBinding.Region(path: foreignPath, type: 100, device: 222, inode: 333)
        let foreignDescriptor = Data("HC-BINDING-1\nCLV-U-ABCDE\n\(request.source.sha256)\n\(token)\n2\n2\n0 123 456 \(ram.path)\n100 222 333 \(foreignPath)\n".utf8)
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.validateStagedScreenshot(descriptor: foreignDescriptor, request: request,
            regions: [ram, foreignImage], expectedImagePath: foreignPath, image: png, expectedSHA256: digest) }
        let sliced = (Data([0]) + png).dropFirst()
        #expect(try SNESRecoveryBinding.validateStagedScreenshot(descriptor: descriptor, request: request,
            regions: [ram, image], expectedImagePath: image.path, image: sliced, expectedSHA256: digest) == png)
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.validateStagedScreenshot(descriptor: descriptor, request: request, regions: [ram, image], expectedImagePath: base + "/other.png", image: png, expectedSHA256: digest) }
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.validateStagedScreenshot(descriptor: descriptor, request: request, regions: [ram, image], expectedImagePath: image.path, image: png, expectedSHA256: String(repeating: "0", count: 64)) }
        var changed = request.frame; changed[83] ^= 1
        let wrongSession = SNESCompatibilityLaunchRequest(frame: changed, source: request.source)
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.validateStagedScreenshot(descriptor: descriptor, request: wrongSession, regions: [ram, image], expectedImagePath: image.path, image: png, expectedSHA256: digest) }
        var changedEpoch = request.frame; changedEpoch[99] = 3
        let wrongEpoch = SNESCompatibilityLaunchRequest(frame: changedEpoch, source: request.source)
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.validateStagedScreenshot(descriptor: descriptor, request: wrongEpoch, regions: [ram, image], expectedImagePath: image.path, image: png, expectedSHA256: digest) }
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.validateStagedScreenshot(descriptor: descriptor, request: request, regions: [ram, image, image], expectedImagePath: image.path, image: png, expectedSHA256: digest) }
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.validateStagedScreenshot(descriptor: descriptor, request: request, regions: [ram, image], expectedImagePath: image.path, image: Data([1, 2, 3]), expectedSHA256: BackupManifest.digest(Data([1, 2, 3]))) }
        let truncated = png.dropLast(12)
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.validateStagedScreenshot(descriptor: descriptor, request: request, regions: [ram, image], expectedImagePath: image.path, image: truncated, expectedSHA256: BackupManifest.digest(truncated)) }
        var badCRC = png; badCRC[29] ^= 1
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.validateStagedScreenshot(descriptor: descriptor, request: request, regions: [ram, image], expectedImagePath: image.path, image: badCRC, expectedSHA256: BackupManifest.digest(badCRC)) }
        let idat = try #require(png.range(of: Data("IDAT".utf8)))
        let count = png[(idat.lowerBound-4)..<idat.lowerBound].reduce(0) { ($0 << 8) | Int($1) }
        var badDataCRC = png; badDataCRC[idat.upperBound + count] ^= 1
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.validateStagedScreenshot(descriptor: descriptor, request: request, regions: [ram, image], expectedImagePath: image.path, image: badDataCRC, expectedSHA256: BackupManifest.digest(badDataCRC)) }
        let changedSource = RecoveryFinalSourceMutation(url: request.source.directory.appendingPathComponent(request.source.filename))
        await #expect(throws:(any Error).self){try await SNESRetainedImageObservation.capture(managerRecord:managerRecord,request:request,expectedManagerSavePath:savePath,expectedManagerImagePath:cachePath,expectedSHA256:digest,validate:{try await changedSource.check()},read:{imageReply})}
    }
    func fixture(_ root: URL, includeSave: Bool, includeClock: Bool = false) async throws -> (SNESLibraryBackup, SNESLibraryInventory, SNESCompatibilityLaunchRequest, Data) {
        let library = root.appendingPathComponent("CLV-U-ABCDE", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: library.appendingPathComponent("game.sfc"))
        var game = Game(code: "CLV-U-ABCDE", desktopContent: "Name=Game\n", consoleType: .snesUsa, source: .local)
        game.romPath = library.path
        let source = try SNESLibraryROMSource.capture(directory: library, filename: "game.sfc").0
        let request = try SNESCompatibilityLaunchRequest.prepare(game: game, source: source, session: Data(repeating: 7, count: 16), epoch: 2)
        let f = SNESLibraryInventoryTests(), nonce = UUID(), save = Data([1, 3, 5, 7])
        var raw = String(decoding: try f.frame(challenge: nonce), as: UTF8.self)
        let clock = Data([2, 4, 6])
        if includeSave || includeClock {
            let parts = ["clover", "profiles", "0", game.code, "hakchi", SNESCompatibilityCorePackage.engineID, source.sha256]
            let dirs = (1..<parts.count).map { "DIR \(f.hex(parts.prefix($0 + 1).joined(separator: "/"))) 448\n" }.joined()
            let base = parts.joined(separator: "/")
            var files = ""
            if includeSave { files += "FILE \(f.hex(base + "/battery.srm")) \(save.count) \(BackupManifest.digest(save)) 384 0 1 9998 0\n" }
            if includeClock { files += "FILE \(f.hex(base + "/battery.rtc")) \(clock.count) \(BackupManifest.digest(clock)) 384 0 1 9997 0\n" }
            raw = raw.replacingOccurrences(of: "END\n", with: dirs + files + "END\n")
        }
        let inventory = try f.parse(Data(raw.utf8), challenge: nonce)
        let backup = try await SNESLibraryBackup.capture(inventory: inventory, root: root, read: { file, _ in
            file.path == "clover/settings.json" ? Data("{}".utf8) : file.path.hasSuffix(".rtc") ? clock : save
        }, refresh: { inventory })
        return (backup, inventory, request, save)
    }
    @Test(arguments: [true, false]) func evidenceUsesTheExactCurrentBackupAndGame(_ present: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (backup, inventory, request, save) = try await fixture(root, includeSave: present)
        let evidence = try SNESCompatibilityBackupEvidence.capture(backup: backup, current: inventory, request: request)
        #expect(evidence.gameCode == "CLV-U-ABCDE")
        #expect(evidence.romSHA256 == request.source.sha256)
        #expect(evidence.original == (present ? .present(save) : .absent))
        #expect(evidence.backupManifestSHA256 == backup.manifestSHA256)
    }
    @Test(arguments: [true, false]) func savedEvidenceMatchesOnlyItsOwnRecoveryBinding(_ present: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (backup, inventory, request, payload) = try await fixture(root, includeSave: present)
        let evidence = try SNESCompatibilityBackupEvidence.capture(backup: backup, current: inventory, request: request)
        let path = "/var/lib/clover/profiles/0/CLV-U-ABCDE/hakchi/\(SNESCompatibilityCorePackage.engineID)/\(request.source.sha256)/battery.srm"
        let region = SNESRecoveryBinding.Region(path: path, type: 0, device: 123, inode: 456)
        let token = String(repeating: "07", count: 16)
        let descriptor = Data("HC-BINDING-1\nCLV-U-ABCDE\n\(request.source.sha256)\n\(token)\n2\n1\n0 123 456 \(path)\n".utf8)
        #expect(try SNESRecoveryBinding.validateBackupEvidence(descriptor: descriptor, evidence: evidence, request: request, region: region) == (present ? .present(payload) : .absent))
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.validateBackupEvidence(descriptor: descriptor + Data([10]), evidence: evidence, request: request, region: region) }
        let wrong = SNESRecoveryBinding.Region(path: path, type: 0, device: 123, inode: 457)
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.validateBackupEvidence(descriptor: descriptor, evidence: evidence, request: request, region: wrong) }
        let foreign = SNESRecoveryBinding.Region(path: path.replacingOccurrences(of: "battery.srm", with: "other.srm"), type: 0, device: 123, inode: 456)
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.validateBackupEvidence(descriptor: descriptor, evidence: evidence, request: request, region: foreign) }
        var alteredFrame = request.frame; alteredFrame[83] ^= 1
        let altered = SNESCompatibilityLaunchRequest(frame: alteredFrame, source: request.source)
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.validateBackupEvidence(descriptor: descriptor, evidence: evidence, request: altered, region: region) }
        let payloadFile = backup.directory.appendingPathComponent("data-0/file-0000.bin")
        try Data([9, 9]).write(to: payloadFile)
        #expect(throws: (any Error).self) { try SNESRecoveryBinding.validateBackupEvidence(descriptor: descriptor, evidence: evidence, request: request, region: region) }
    }
    @Test(arguments: [true, false]) func durableReferenceKeepsOnlySessionAndBackupIdentity(_ present: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (backup, inventory, request, payload) = try await fixture(root, includeSave: present)
        let created = try SNESCompatibilityRecoveryReference.create(root: root, backup: backup, current: inventory, request: request)
        #expect(try FileManager.default.contentsOfDirectory(atPath: created.directory.path) == ["record.json"])
        let recordBytes = try Data(contentsOf: created.directory.appendingPathComponent("record.json"))
        #expect(recordBytes.count < 4096)
        let object = try #require(JSONSerialization.jsonObject(with: recordBytes) as? [String: Any])
        #expect(object["backupManifestSHA256"] as? String == backup.manifestSHA256)
        #expect(object["payload"] == nil && object["saveBytes"] == nil && object["romBytes"] == nil)
        let reopened = try SNESCompatibilityRecoveryReference.open(directory: created.directory, backup: backup, current: inventory, request: request)
        #expect(reopened.evidence.original == (present ? .present(payload) : .absent))
        #expect(reopened.recordSHA256 == created.recordSHA256)
        // After interruption the live inventory may have new journal files;
        // reopen only the saved evidence without asserting console state.
        let historical = try SNESCompatibilityRecoveryReference.openHistorical(directory: created.directory, backup: backup, request: request)
        #expect(historical.recordSHA256 == created.recordSHA256)
        #expect(historical.evidence.original == (present ? .present(payload) : .absent))
        let inventoryFixture = SNESLibraryInventoryTests(), challenge = UUID()
        let changedRaw = String(decoding: try inventoryFixture.frame(challenge: challenge), as: UTF8.self)
            .replacingOccurrences(of: BackupManifest.digest(Data("{}".utf8)), with: BackupManifest.digest(Data("[]".utf8)))
        let changedInventory = try inventoryFixture.parse(Data(changedRaw.utf8), challenge: challenge)
        #expect(throws: (any Error).self) { try SNESCompatibilityRecoveryReference.open(directory: created.directory, backup: backup, current: changedInventory, request: request) }
        #expect(try SNESCompatibilityRecoveryReference.openHistorical(directory: created.directory, backup: backup, request: request).recordSHA256 == created.recordSHA256)
        #expect(throws: (any Error).self) { try SNESCompatibilityRecoveryReference.create(root: root, backup: backup, current: inventory, request: request) }
        let record = created.directory.appendingPathComponent("record.json")
        try Data("{}".utf8).write(to: record)
        #expect(throws: (any Error).self) { try SNESCompatibilityRecoveryReference.open(directory: created.directory, backup: backup, current: inventory, request: request) }
        #expect(throws: (any Error).self) { try SNESCompatibilityRecoveryReference.openHistorical(directory: created.directory, backup: backup, request: request) }
        #expect(try Data(contentsOf: record) == Data("{}".utf8))
    }
    @Test(arguments: [true, false]) func historicalReferenceChecksExactConsoleBinding(_ present: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (backup, inventory, request, payload) = try await fixture(root, includeSave: present)
        let saved = try SNESCompatibilityRecoveryReference.create(root: root, backup: backup, current: inventory, request: request)
        let path = "/var/lib/clover/profiles/0/CLV-U-ABCDE/hakchi/\(SNESCompatibilityCorePackage.engineID)/\(request.source.sha256)/battery.srm"
        let region = SNESRecoveryBinding.Region(path: path, type: 0, device: 123, inode: 456)
        let token = String(repeating: "07", count: 16)
        let record = "HC-BINDING-1\nCLV-U-ABCDE\n\(request.source.sha256)\n\(token)\n2\n1\n0 123 456 \(path)\n"
        let descriptor = Data(record.utf8)
        let original = try SNESCompatibilityRecoveryReference.matchHistoricalBinding(directory: saved.directory, backup: backup, request: request, descriptor: descriptor, region: region)
        #expect(original == (present ? .present(payload) : .absent))
        let wrongSession = Data(record.replacingOccurrences(of: token, with: String(repeating: "08", count: 16)).utf8)
        #expect(throws: (any Error).self) { try SNESCompatibilityRecoveryReference.matchHistoricalBinding(directory: saved.directory, backup: backup, request: request, descriptor: wrongSession, region: region) }
        let wrongRegion = SNESRecoveryBinding.Region(path: path, type: 0, device: 123, inode: 457)
        #expect(throws: (any Error).self) { try SNESCompatibilityRecoveryReference.matchHistoricalBinding(directory: saved.directory, backup: backup, request: request, descriptor: descriptor, region: wrongRegion) }
        let recordURL = saved.directory.appendingPathComponent("record.json")
        try Data("{}".utf8).write(to: recordURL)
        #expect(throws: (any Error).self) { try SNESCompatibilityRecoveryReference.matchHistoricalBinding(directory: saved.directory, backup: backup, request: request, descriptor: descriptor, region: region) }
        #expect(try Data(contentsOf: recordURL) == Data("{}".utf8))
    }
    @Test(arguments: [true, false]) func historicalReferenceMatchesFrontendSaveAndClockRegions(_ present: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (backup, inventory, request, payload) = try await fixture(root, includeSave: present)
        let saved = try SNESCompatibilityRecoveryReference.create(root: root, backup: backup, current: inventory, request: request)
        let base = "/var/lib/clover/profiles/0/CLV-U-ABCDE/hakchi/\(SNESCompatibilityCorePackage.engineID)/\(request.source.sha256)"
        let save = SNESRecoveryBinding.Region(path: base + "/battery.srm", type: 0, device: 123, inode: 456)
        let clock = SNESRecoveryBinding.Region(path: base + "/battery.rtc", type: 1, device: 123, inode: 456)
        let token = String(repeating: "07", count: 16)
        let descriptor = Data("HC-BINDING-1\nCLV-U-ABCDE\n\(request.source.sha256)\n\(token)\n2\n2\n0 123 456 \(save.path)\n1 123 456 \(clock.path)\n".utf8)
        let result = try SNESCompatibilityRecoveryReference.matchHistoricalBinding(directory: saved.directory, backup: backup, request: request, descriptor: descriptor, regions: [save, clock])
        #expect(result == (present ? .present(payload) : .absent))
        let wrongClock = SNESRecoveryBinding.Region(path: clock.path, type: 1, device: 123, inode: 457)
        #expect(throws: (any Error).self) { try SNESCompatibilityRecoveryReference.matchHistoricalBinding(directory: saved.directory, backup: backup, request: request, descriptor: descriptor, regions: [save, wrongClock]) }
        #expect(throws: (any Error).self) { try SNESCompatibilityRecoveryReference.matchHistoricalBinding(directory: saved.directory, backup: backup, request: request, descriptor: descriptor, regions: [clock, save]) }
        #expect(throws: (any Error).self) { try SNESCompatibilityRecoveryReference.matchHistoricalBinding(directory: saved.directory, backup: backup, request: request, descriptor: descriptor, regions: [save]) }
    }
    @Test(arguments: [[false, false], [false, true], [true, false], [true, true]])
    func historicalReferenceKeepsBatteryAndClockEvidenceSeparate(_ flags: [Bool]) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (backup, inventory, request, battery) = try await fixture(root, includeSave: flags[0], includeClock: flags[1])
        let saved = try SNESCompatibilityRecoveryReference.create(root: root, backup: backup, current: inventory, request: request)
        let base = "/var/lib/clover/profiles/0/CLV-U-ABCDE/hakchi/\(SNESCompatibilityCorePackage.engineID)/\(request.source.sha256)"
        let save = SNESRecoveryBinding.Region(path: base + "/battery.srm", type: 0, device: 123, inode: 456)
        let clock = SNESRecoveryBinding.Region(path: base + "/battery.rtc", type: 1, device: 123, inode: 456)
        let token = String(repeating: "07", count: 16)
        let descriptor = Data("HC-BINDING-1\nCLV-U-ABCDE\n\(request.source.sha256)\n\(token)\n2\n2\n0 123 456 \(save.path)\n1 123 456 \(clock.path)\n".utf8)
        let pair = try SNESCompatibilityRecoveryReference.matchHistoricalSaves(directory: saved.directory, backup: backup, request: request, descriptor: descriptor, regions: [save, clock])
        #expect(pair.battery == (flags[0] ? .present(battery) : .absent))
        #expect(pair.clock == (flags[1] ? .present(Data([2, 4, 6])) : .absent))
        let wrong = SNESRecoveryBinding.Region(path: clock.path, type: 1, device: 123, inode: 457)
        #expect(throws: (any Error).self) { try SNESCompatibilityRecoveryReference.matchHistoricalSaves(directory: saved.directory, backup: backup, request: request, descriptor: descriptor, regions: [save, wrong]) }
    }
    @Test func interruptedCurrentEvidenceCaptureCanBeRetried() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (backup, inventory, request, _) = try await fixture(root, includeSave: true, includeClock: true)
        let reference = try SNESCompatibilityRecoveryReference.create(root: root, backup: backup, current: inventory, request: request)
        let base = "/var/lib/clover/profiles/0/CLV-U-ABCDE/hakchi/\(SNESCompatibilityCorePackage.engineID)/\(request.source.sha256)"
        let token = String(repeating: "07", count: 16), workspace = "checkpoint-" + String(repeating: "1", count: 32)
        let descriptor = Data("HC-BINDING-1\nCLV-U-ABCDE\n\(request.source.sha256)\n\(token)\n2\n2\n0 123 456 \(base)/battery.srm\n1 123 456 \(base)/battery.rtc\n".utf8)
        let frame = Data("HC-RECOVERY-OBS-1\n123 456 \(descriptor.count) 1\n".utf8) + descriptor + Data("ENTRY \(token) \(workspace) battery.srm 2 1\nHC-RECOVERY-OBS-END\n".utf8)
        let observation = try SNESRecoveryConsoleObservation.parse(frame, directory: reference.directory, backup: backup, request: request)
        #expect(throws: CancellationError.self) {
            try SNESCompatibilityCurrentEvidence.create(root: root, referenceDirectory: reference.directory, backup: backup, request: request, observation: observation, region: .battery, current: .present(Data("NEW!".utf8)), afterPayloadWritten: {
                let names = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".SNES-Current-") }
                #expect(names.count == 1)
                let stage = try #require(names.first)
                #expect(try Data(contentsOf: root.appendingPathComponent(stage).appendingPathComponent("current.bin")) == Data("NEW!".utf8))
                throw CancellationError()
            })
        }
        let result = try SNESCompatibilityCurrentEvidence.create(root: root, referenceDirectory: reference.directory, backup: backup, request: request, observation: observation, region: .battery, current: .present(Data("NEW!".utf8)))
        #expect(result.current == .present(Data("NEW!".utf8)))
        let resumed = try SNESCompatibilityCurrentEvidence.createOrResume(root: root, referenceDirectory: reference.directory, backup: backup, request: request, observation: observation, region: .battery, current: .present(Data("NEW!".utf8)))
        #expect(resumed.directory == result.directory)
        let absent = try SNESCompatibilityCurrentEvidence.createOrResume(root: root, referenceDirectory: reference.directory, backup: backup, request: request, observation: observation, region: .clock, current: .absent)
        let absentRetry = try SNESCompatibilityCurrentEvidence.createOrResume(root: root, referenceDirectory: reference.directory, backup: backup, request: request, observation: observation, region: .clock, current: .absent)
        #expect(absentRetry.directory == absent.directory && absentRetry.current == .absent)
        #expect(throws: (any Error).self) {
            try SNESCompatibilityCurrentEvidence.createOrResume(root: root, referenceDirectory: reference.directory, backup: backup, request: request, observation: observation, region: .battery, current: .present(Data("DIFFERENT".utf8)))
        }
        #expect(throws: (any Error).self) {
            try SNESCompatibilityCurrentEvidence.createOrResume(root: root, referenceDirectory: reference.directory, backup: backup, request: request, observation: observation, region: .battery, current: .absent)
        }
        #expect(try Data(contentsOf: result.directory.appendingPathComponent("current.bin")) == Data("NEW!".utf8))
        let stages = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".SNES-Current-") }
        #expect(stages.count == 1)
        let stage = try #require(stages.first)
        #expect(try Data(contentsOf: root.appendingPathComponent(stage).appendingPathComponent("current.bin")) == Data("NEW!".utf8))
        try Data("BAD!".utf8).write(to: result.directory.appendingPathComponent("current.bin"))
        #expect(throws: (any Error).self) {
            try SNESCompatibilityCurrentEvidence.createOrResume(root: root, referenceDirectory: reference.directory, backup: backup, request: request, observation: observation, region: .battery, current: .present(Data("NEW!".utf8)))
        }
    }
    @Test func consoleObservationMatchesHistoricalBatteryAndClock() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (backup, inventory, request, battery) = try await fixture(root, includeSave: true, includeClock: true)
        let saved = try SNESCompatibilityRecoveryReference.create(root: root, backup: backup, current: inventory, request: request)
        let base = "/var/lib/clover/profiles/0/CLV-U-ABCDE/hakchi/\(SNESCompatibilityCorePackage.engineID)/\(request.source.sha256)"
        let token = String(repeating: "07", count: 16)
        let descriptor = Data("HC-BINDING-1\nCLV-U-ABCDE\n\(request.source.sha256)\n\(token)\n2\n2\n0 123 456 \(base)/battery.srm\n1 123 456 \(base)/battery.rtc\n".utf8)
        let workspace = "checkpoint-" + String(repeating: "1", count: 32)
        let frame = Data("HC-RECOVERY-OBS-1\n123 456 \(descriptor.count) 1\n".utf8) + descriptor + Data("ENTRY \(token) \(workspace) battery.srm 2 0\nHC-RECOVERY-OBS-END\n".utf8)
        let observation = try SNESRecoveryConsoleObservation.parse(frame, directory: saved.directory, backup: backup, request: request)
        #expect(observation.saves.battery == .present(battery))
        #expect(observation.saves.clock == .present(Data([2, 4, 6])))
        #expect(observation.pending.count == 1)
        let imageName="shot-\(token).png",imageWorkspace="checkpoint-"+String(repeating:"2",count:32)
        let combinedDescriptor=Data("HC-BINDING-1\nCLV-U-ABCDE\n\(request.source.sha256)\n\(token)\n2\n3\n0 123 456 \(base)/battery.srm\n1 123 456 \(base)/battery.rtc\n100 123 456 \(base)/\(imageName)\n".utf8)
        let combinedFrame=Data("HC-RECOVERY-OBS-1\n123 456 \(combinedDescriptor.count) 2\n".utf8)+combinedDescriptor+Data("ENTRY \(token) \(workspace) battery.srm 2 1\nENTRY \(token) \(imageWorkspace) \(imageName) 2 1\nHC-RECOVERY-OBS-END\n".utf8)
        let combinedObservation=try SNESRecoveryConsoleObservation.parse(combinedFrame,directory:saved.directory,backup:backup,request:request)
        #expect(combinedObservation.saves.battery == .present(battery) && combinedObservation.pending.count == 2)
        let combinedRoot=root.appendingPathComponent("combined-current",isDirectory:true)
        try FileManager.default.createDirectory(at:combinedRoot,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let combinedCurrent=try SNESCompatibilityCurrentEvidence.create(root:combinedRoot,referenceDirectory:saved.directory,backup:backup,request:request,observation:combinedObservation,region:.battery,current:.present(Data("NEW!".utf8)))
        let combinedPlan=try SNESBatteryRecoveryPlan.prepare(referenceDirectory:saved.directory,currentDirectory:combinedCurrent.directory,backup:backup,request:request,observation:combinedObservation,workspace:workspace)
        #expect(combinedPlan.workspace==workspace)
        #expect(throws:(any Error).self){try SNESBatteryRecoveryPlan.prepare(referenceDirectory:saved.directory,currentDirectory:combinedCurrent.directory,backup:backup,request:request,observation:combinedObservation,workspace:imageWorkspace)}
        let wrongImageFrame=Data(String(decoding:combinedFrame,as:UTF8.self).replacingOccurrences(of:imageName,with:"shot-"+String(repeating:"a",count:32)+".png").utf8)
        #expect(throws:(any Error).self){try SNESRecoveryConsoleObservation.parse(wrongImageFrame,directory:saved.directory,backup:backup,request:request)}
        let periodicImageFrame=Data(String(decoding:combinedFrame,as:UTF8.self).replacingOccurrences(of:"\(imageName) 2 1",with:"\(imageName) 1 1").utf8)
        #expect(throws:(any Error).self){try SNESRecoveryConsoleObservation.parse(periodicImageFrame,directory:saved.directory,backup:backup,request:request)}
        let retained = try SNESCompatibilityCurrentEvidence.create(root: root, referenceDirectory: saved.directory, backup: backup, request: request, observation: observation, region: .clock, current: .present(Data("TIME".utf8)))
        let reopened = try SNESCompatibilityCurrentEvidence.open(directory: retained.directory, referenceDirectory: saved.directory, backup: backup, request: request, observation: observation, region: .clock)
        #expect(reopened.current == .present(Data("TIME".utf8)))
        let absentEvidence = try SNESCompatibilityCurrentEvidence.create(root: root, referenceDirectory: saved.directory, backup: backup, request: request, observation: observation, region: .battery, current: .absent)
        #expect(try SNESCompatibilityCurrentEvidence.open(directory: absentEvidence.directory, referenceDirectory: saved.directory, backup: backup, request: request, observation: observation, region: .battery).current == .absent)
        #expect(!FileManager.default.fileExists(atPath: absentEvidence.directory.appendingPathComponent("current.bin").path))
        #expect(throws: (any Error).self) { try SNESCompatibilityCurrentEvidence.create(root: root, referenceDirectory: saved.directory, backup: backup, request: request, observation: observation, region: .battery, current: .absent) }
        #expect(throws: (any Error).self) { try SNESCompatibilityCurrentEvidence.open(directory: retained.directory, referenceDirectory: saved.directory, backup: backup, request: request, observation: observation, region: .battery) }
        try Data("BAD!".utf8).write(to: retained.directory.appendingPathComponent("current.bin"))
        #expect(throws: (any Error).self) { try SNESCompatibilityCurrentEvidence.open(directory: retained.directory, referenceDirectory: saved.directory, backup: backup, request: request, observation: observation, region: .clock) }
        let target = root.appendingPathComponent("outside-current")
        try Data("unchanged".utf8).write(to: target)
        try FileManager.default.removeItem(at: retained.directory.appendingPathComponent("current.bin"))
        try FileManager.default.createSymbolicLink(at: retained.directory.appendingPathComponent("current.bin"), withDestinationURL: target)
        #expect(throws: (any Error).self) { try SNESCompatibilityCurrentEvidence.open(directory: retained.directory, referenceDirectory: saved.directory, backup: backup, request: request, observation: observation, region: .clock) }
        #expect(try Data(contentsOf: target) == Data("unchanged".utf8))
        let live = Data("HC-RECOVERY-CURRENT-1\n123 456 rtc 1 4\n".utf8) + Data("TIME".utf8) + Data("HC-RECOVERY-CURRENT-END\n".utf8)
        #expect(try SNESRecoveryCurrentSave.parse(live, observation: observation, region: .clock) == .present(Data("TIME".utf8)))
        let currentSource = RecoveryReadSequence(frame: live, changed: false)
        let current = try await SNESCompatibilityRecoveryCapture.readCurrent(observation: observation, request: request, region: .clock, validate: {}, read: { await currentSource.read() })
        #expect(current == .present(Data("TIME".utf8)))
        #expect(await currentSource.reads == 2)
        let changingSource = RecoveryReadSequence(frame: live, changed: true)
        await #expect(throws: (any Error).self) { try await SNESCompatibilityRecoveryCapture.readCurrent(observation: observation, request: request, region: .clock, validate: {}, read: { await changingSource.read() }) }
        let absent = Data("HC-RECOVERY-CURRENT-1\n123 456 rtc 0 0\nHC-RECOVERY-CURRENT-END\n".utf8)
        #expect(try SNESRecoveryCurrentSave.parse(absent, observation: observation, region: .clock) == .absent)
        let wrongParent = Data("HC-RECOVERY-CURRENT-1\n123 457 rtc 1 4\n".utf8) + Data("TIME".utf8) + Data("HC-RECOVERY-CURRENT-END\n".utf8)
        #expect(throws: (any Error).self) { try SNESRecoveryCurrentSave.parse(wrongParent, observation: observation, region: .clock) }
        #expect(throws: (any Error).self) { try SNESRecoveryCurrentSave.parse(live, observation: observation, region: .battery) }
        #expect(throws: (any Error).self) { try SNESRecoveryCurrentSave.parse(live + Data([0]), observation: observation, region: .clock) }
        #expect(throws: (any Error).self) { try SNESRecoveryConsoleObservation.parse(frame + Data([0]), directory: saved.directory, backup: backup, request: request) }
        let wrong = Data("HC-RECOVERY-OBS-1\n123 457 \(descriptor.count) 1\n".utf8) + descriptor + Data("ENTRY \(token) \(workspace) battery.srm 2 0\nHC-RECOVERY-OBS-END\n".utf8)
        #expect(throws: (any Error).self) { try SNESRecoveryConsoleObservation.parse(wrong, directory: saved.directory, backup: backup, request: request) }
        let invalidRegion = Data("HC-RECOVERY-OBS-1\n123 456 \(descriptor.count) 1\n".utf8) + descriptor + Data("ENTRY \(token) \(workspace) other.srm 2 0\nHC-RECOVERY-OBS-END\n".utf8)
        #expect(throws: (any Error).self) { try SNESRecoveryConsoleObservation.parse(invalidRegion, directory: saved.directory, backup: backup, request: request) }
        let duplicate = Data("HC-RECOVERY-OBS-1\n123 456 \(descriptor.count) 2\n".utf8) + descriptor + Data("ENTRY \(token) \(workspace) battery.srm 2 0\nENTRY \(token) \(workspace) battery.rtc 1 1\nHC-RECOVERY-OBS-END\n".utf8)
        #expect(throws: (any Error).self) { try SNESRecoveryConsoleObservation.parse(duplicate, directory: saved.directory, backup: backup, request: request) }
    }
    @Test func recoveryTransportCommandIsFixedAndUsesReviewedRequest() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, _, request, _) = try await fixture(root, includeSave: false)
        let hash = String(repeating: "a", count: 64)
        let prepared = try SNESCompatibilityRecoveryCommand.prepare(request: request, helperSHA256: hash)
        #expect(prepared.input == request.frame)
        #expect(prepared.command.contains("--observe-recovery"))
        let current = try SNESCompatibilityRecoveryCommand.prepareCurrent(request: request, helperSHA256: hash, region: .clock)
        #expect(current.input == request.frame && current.command.contains("--observe-recovery-save rtc"))
        let retained = try SNESCompatibilityRecoveryCommand.prepareRetainedState(request: request, helperSHA256: hash, paired: false)
        let paired = try SNESCompatibilityRecoveryCommand.prepareRetainedState(request: request, helperSHA256: hash, paired: true)
        #expect(retained.input == request.frame && retained.command.hasSuffix("--observe-retained-state save"))
        #expect(paired.input == request.frame && paired.command.hasSuffix("--observe-retained-state paired"))
        let retainedImage = try SNESCompatibilityRecoveryCommand.prepareRetainedImage(request: request, helperSHA256: hash, paired: false)
        let pairedImage = try SNESCompatibilityRecoveryCommand.prepareRetainedImage(request: request, helperSHA256: hash, paired: true)
        #expect(retainedImage.input == request.frame && retainedImage.command.hasSuffix("--observe-retained-image image"))
        #expect(pairedImage.input == request.frame && pairedImage.command.hasSuffix("--observe-retained-image paired"))
        let retiredImage = try SNESCompatibilityRecoveryCommand.prepareRetainedImage(request: request, helperSHA256: hash, paired: true, retired: true)
        #expect(retiredImage.input == request.frame && retiredImage.command.hasSuffix("--observe-retired-image paired"))
        #expect(prepared.command.contains(hash))
        #expect(!prepared.command.contains(request.source.directory.path))
        #expect(throws: (any Error).self) { try SNESCompatibilityRecoveryCommand.prepare(request: request, helperSHA256: "a'; touch /tmp/bad") }
        if let output = ProcessInfo.processInfo.environment["HC_RECOVERY_TRANSPORT_FIXTURE"] {
            let root = URL(fileURLWithPath: output, isDirectory: true)
            let actualHash = try #require(ProcessInfo.processInfo.environment["HC_RECOVERY_TRANSPORT_HELPER_SHA"])
            let actual = try SNESCompatibilityRecoveryCommand.prepare(request: request, helperSHA256: actualHash)
            try Data(actual.command.utf8).write(to: root.appendingPathComponent("command"))
            let actualCurrent = try SNESCompatibilityRecoveryCommand.prepareCurrent(request: request, helperSHA256: actualHash, region: .clock)
            try Data(actualCurrent.command.utf8).write(to: root.appendingPathComponent("current-command"))
            let actualRetained = try SNESCompatibilityRecoveryCommand.prepareRetainedState(request: request, helperSHA256: actualHash, paired: false)
            try Data(actualRetained.command.utf8).write(to: root.appendingPathComponent("retained-command"))
            let actualImage = try SNESCompatibilityRecoveryCommand.prepareRetainedImage(request: request, helperSHA256: actualHash, paired: false)
            try Data(actualImage.command.utf8).write(to: root.appendingPathComponent("retained-image-command"))
            let actualRetiredImage = try SNESCompatibilityRecoveryCommand.prepareRetainedImage(request: request, helperSHA256: actualHash, paired: false, retired: true)
            try Data(actualRetiredImage.command.utf8).write(to: root.appendingPathComponent("retired-image-command"))
            try actual.input.write(to: root.appendingPathComponent("request"))
        }
    }
    @Test func disconnectedSessionCannotReadRecoveryObservation() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (backup, inventory, request, _) = try await fixture(root, includeSave: false)
        let reference = try SNESCompatibilityRecoveryReference.create(root: root, backup: backup, current: inventory, request: request)
        let session = SNESLibraryConnectionSession(attachment: SNESLibraryContextTests.device(), io: RecoveryDisconnectedIO())
        var localGame=Game(code:"CLV-U-ABCDE",desktopContent:"Name=Game\n",consoleType:.snesUsa,source:.local);localGame.romPath=request.source.directory.path
        await #expect(throws: (any Error).self) {
            try await session.captureCompatibilityManagerInventory(game:localGame,source:request.source,helperSHA256:String(repeating:"a",count:64))
        }
        await #expect(throws: (any Error).self) {
            try await session.captureCompatibilityRecovery(request: request, helperSHA256: String(repeating: "a", count: 64), directory: reference.directory, backup: backup)
        }
        await #expect(throws: (any Error).self) {
            try await session.captureCompatibilityCurrent(request: request, helperSHA256: String(repeating: "a", count: 64), directory: reference.directory, backup: backup, region: .clock)
        }
        await #expect(throws: (any Error).self) {
            try await session.captureCompatibilityRetainedState(request: request, game: localGame, helperSHA256: String(repeating: "a", count: 64), managerRecord: Data(), expectedManagerSavePath: "/invalid", expectedManagerImagePath: nil, expectedSHA256: String(repeating: "0", count: 64))
        }
        await #expect(throws: (any Error).self) {
            try await session.captureCompatibilityRetainedImage(request: request, helperSHA256: String(repeating: "a", count: 64), managerRecord: Data(), expectedManagerSavePath: nil, expectedManagerImagePath: "/invalid", expectedSHA256: String(repeating: "0", count: 64))
        }
        await #expect(throws: (any Error).self) {
            try await session.captureCompatibilityRetainedTime(request: request, helperSHA256: String(repeating: "a", count: 64), managerRecord: Data(), expectedLoadPath: "/invalid", expectedSHA256: String(repeating: "0", count: 64))
        }
        await #expect(throws: (any Error).self) {
            try await session.captureCompatibilityStateArchive(request: request, game: localGame, helperSHA256: String(repeating: "a", count: 64), managerRecord: Data(), expectedSHA256: String(repeating: "0", count: 64))
        }
        await #expect(throws: (any Error).self) {
            try await session.retainCompatibilityCurrent(request: request, helperSHA256: String(repeating: "a", count: 64), directory: reference.directory, backup: backup, region: .clock, root: root)
        }
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains(where: { $0.hasPrefix("SNES-Current-") }))
    }
    @Test(arguments: [false, true]) func recoveryCaptureRejectsChangedSecondRead(_ changed: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (backup, inventory, request, _) = try await fixture(root, includeSave: false)
        let reference = try SNESCompatibilityRecoveryReference.create(root: root, backup: backup, current: inventory, request: request)
        let base = "/var/lib/clover/profiles/0/CLV-U-ABCDE/hakchi/\(SNESCompatibilityCorePackage.engineID)/\(request.source.sha256)"
        let token = String(repeating: "07", count: 16)
        let descriptor = Data("HC-BINDING-1\nCLV-U-ABCDE\n\(request.source.sha256)\n\(token)\n2\n2\n0 123 456 \(base)/battery.srm\n1 123 456 \(base)/battery.rtc\n".utf8)
        let frame = Data("HC-RECOVERY-OBS-1\n123 456 \(descriptor.count) 0\n".utf8) + descriptor + Data("HC-RECOVERY-OBS-END\n".utf8)
        let source = RecoveryReadSequence(frame: frame, changed: changed)
        do {
            let observation = try await SNESCompatibilityRecoveryCapture.read(directory: reference.directory, backup: backup, request: request, validate: {}, read: { await source.read() })
            #expect(!changed && observation.saves.battery == .absent && observation.saves.clock == .absent)
        } catch { #expect(changed) }
        #expect(await source.reads == 2)
    }
    @Test(arguments: [false, true]) func batteryRecoveryPlanUsesMatchingSaveEvidence(_ originallyPresent: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (backup, inventory, request, original) = try await fixture(root, includeSave: originallyPresent)
        let reference = try SNESCompatibilityRecoveryReference.create(root: root, backup: backup, current: inventory, request: request)
        let base = "/var/lib/clover/profiles/0/CLV-U-ABCDE/hakchi/\(SNESCompatibilityCorePackage.engineID)/\(request.source.sha256)"
        let token = String(repeating: "07", count: 16), workspace = "checkpoint-" + String(repeating: "1", count: 32)
        let descriptor = Data("HC-BINDING-1\nCLV-U-ABCDE\n\(request.source.sha256)\n\(token)\n2\n2\n0 123 456 \(base)/battery.srm\n1 123 456 \(base)/battery.rtc\n".utf8)
        let frame = Data("HC-RECOVERY-OBS-1\n123 456 \(descriptor.count) 1\n".utf8) + descriptor + Data("ENTRY \(token) \(workspace) battery.srm 2 1\nHC-RECOVERY-OBS-END\n".utf8)
        let observation = try SNESRecoveryConsoleObservation.parse(frame, directory: reference.directory, backup: backup, request: request)
        let retained = try SNESCompatibilityCurrentEvidence.create(root: root, referenceDirectory: reference.directory, backup: backup, request: request, observation: observation, region: .battery, current: .present(Data("NEW!".utf8)))
        let plan = try SNESBatteryRecoveryPlan.prepare(referenceDirectory: reference.directory, currentDirectory: retained.directory, backup: backup, request: request, observation: observation, workspace: workspace)
        #expect(plan.workspace == workspace && plan.originalPresent == originallyPresent)
        #expect(plan.evidence == (originallyPresent ? original : Data("NEW!".utf8)))
        let wire = try plan.encodedRequest()
        #expect(wire.last == 2)
        #expect(Array(wire.dropLast().suffix(16)) == [123, 0, 0, 0, 0, 0, 0, 0, 200, 1, 0, 0, 0, 0, 0, 0])
        #expect(wire.count == 185 + plan.evidence.count + 4 && wire.starts(with: Data("HCRST30\0".utf8)))
        let inspection = try SNESBatteryRecoveryInspection.prepare(plan: plan, helperSHA256: String(repeating: "a", count: 64))
        let receipt = Data("HC-BATTERY-INSPECT-1\n\(workspace) \(originallyPresent ? 1 : 2)\nEND\n".utf8)
        #expect(inspection.input == wire && inspection.command.contains("--inspect-battery-recovery"))
        #expect(try inspection.validateReceipt(receipt))
        #expect(throws: (any Error).self) { try inspection.validateReceipt(receipt + Data([0])) }
        #expect(throws: (any Error).self) { try SNESBatteryRecoveryInspection.prepare(plan: plan, helperSHA256: "bad'; exit") }
        let same = RecoveryReadSequence(frame: receipt, changed: false)
        #expect(try await SNESBatteryRecoveryInspection.capture(plan: plan, helperSHA256: String(repeating: "a", count: 64), validate: {}, read: { await same.read() }) == receipt)
        let changed = RecoveryReadSequence(frame: receipt, changed: true)
        await #expect(throws: (any Error).self) { try await SNESBatteryRecoveryInspection.capture(plan: plan, helperSHA256: String(repeating: "a", count: 64), validate: {}, read: { await changed.read() }) }
        let disconnectedCheck = RecoveryFinalValidation(failOnFourth: true)
        await #expect(throws: (any Error).self) { try await SNESBatteryRecoveryInspection.capture(plan: plan, helperSHA256: String(repeating: "a", count: 64), validate: { try await disconnectedCheck.check() }, read: { receipt }) }
        let disconnected = SNESLibraryConnectionSession(attachment: SNESLibraryContextTests.device(), io: RecoveryDisconnectedIO())
        await #expect(throws: (any Error).self) { try await disconnected.inspectCompatibilityBatteryRecovery(plan: plan, helperSHA256: String(repeating: "a", count: 64)) }
        #expect(throws: (any Error).self) { try SNESBatteryRecoveryPlan.prepare(referenceDirectory: reference.directory, currentDirectory: retained.directory, backup: backup, request: request, observation: observation, workspace: "checkpoint-" + String(repeating: "2", count: 32)) }
        let clockFrame = Data("HC-RECOVERY-OBS-1\n123 456 \(descriptor.count) 1\n".utf8) + descriptor + Data("ENTRY \(token) \(workspace) battery.rtc 2 1\nHC-RECOVERY-OBS-END\n".utf8)
        let clockObservation = try SNESRecoveryConsoleObservation.parse(clockFrame, directory: reference.directory, backup: backup, request: request)
        #expect(throws: (any Error).self) { try SNESBatteryRecoveryPlan.prepare(referenceDirectory: reference.directory, currentDirectory: retained.directory, backup: backup, request: request, observation: clockObservation, workspace: workspace) }
        let otherRoot = root.appendingPathComponent("absent-current", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let absent = try SNESCompatibilityCurrentEvidence.create(root: otherRoot, referenceDirectory: reference.directory, backup: backup, request: request, observation: observation, region: .battery, current: .absent)
        if originallyPresent {
            #expect(try SNESBatteryRecoveryPlan.prepare(referenceDirectory: reference.directory, currentDirectory: absent.directory, backup: backup, request: request, observation: observation, workspace: workspace).evidence == original)
        } else {
            #expect(throws: (any Error).self) { try SNESBatteryRecoveryPlan.prepare(referenceDirectory: reference.directory, currentDirectory: absent.directory, backup: backup, request: request, observation: observation, workspace: workspace) }
        }
        if let output = ProcessInfo.processInfo.environment["HC_BATTERY_RECOVERY_WIRE_DIR"] {
            let name = originallyPresent ? "present" : "absent"
            try wire.write(to: URL(fileURLWithPath: output, isDirectory: true).appendingPathComponent(name))
            if let helperHash = ProcessInfo.processInfo.environment["HC_BATTERY_INSPECTION_HELPER_SHA"] {
                let command = try SNESBatteryRecoveryInspection.prepare(plan: plan, helperSHA256: helperHash)
                try Data(command.command.utf8).write(to: URL(fileURLWithPath: output, isDirectory: true).appendingPathComponent(name + "-command"))
            }
        }
        try Data("BAD!".utf8).write(to: retained.directory.appendingPathComponent("current.bin"))
        #expect(throws: (any Error).self) { try SNESBatteryRecoveryPlan.prepare(referenceDirectory: reference.directory, currentDirectory: retained.directory, backup: backup, request: request, observation: observation, workspace: workspace) }
        #expect(throws: (any Error).self) { try plan.encodedRequest() }
        try Data("NEW!".utf8).write(to: retained.directory.appendingPathComponent("current.bin"))
        #expect(try plan.encodedRequest() == wire)
        let sourceFile = request.source.directory.appendingPathComponent(request.source.filename), sourceBytes = try Data(contentsOf: sourceFile)
        let changedSource = RecoveryFinalSourceMutation(url: sourceFile)
        await #expect(throws: (any Error).self) { try await SNESBatteryRecoveryInspection.capture(plan: plan, helperSHA256: String(repeating: "a", count: 64), validate: { try await changedSource.check() }, read: { receipt }) }
        try sourceBytes.write(to: sourceFile)
        #expect(try plan.encodedRequest() == wire)
        let backupFile = backup.directory.appendingPathComponent("data-0/file-0000.bin")
        try Data("BAD!".utf8).write(to: backupFile)
        #expect(throws: (any Error).self) { try plan.encodedRequest() }
    }
    @Test(arguments: [false, true]) func clockRestorePlanUsesTheRightRetainedBytes(_ originallyPresent: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (backup, inventory, request, _) = try await fixture(root, includeSave: true, includeClock: originallyPresent)
        let reference = try SNESCompatibilityRecoveryReference.create(root: root, backup: backup, current: inventory, request: request)
        let base = "/var/lib/clover/profiles/0/CLV-U-ABCDE/hakchi/\(SNESCompatibilityCorePackage.engineID)/\(request.source.sha256)"
        let token = String(repeating: "07", count: 16), workspace = "checkpoint-" + String(repeating: "1", count: 32)
        let descriptor = Data("HC-BINDING-1\nCLV-U-ABCDE\n\(request.source.sha256)\n\(token)\n2\n2\n0 123 456 \(base)/battery.srm\n1 123 456 \(base)/battery.rtc\n".utf8)
        let frame = Data("HC-RECOVERY-OBS-1\n123 456 \(descriptor.count) 1\n".utf8) + descriptor + Data("ENTRY \(token) \(workspace) battery.rtc 2 1\nHC-RECOVERY-OBS-END\n".utf8)
        let observation = try SNESRecoveryConsoleObservation.parse(frame, directory: reference.directory, backup: backup, request: request)
        let retained = try SNESCompatibilityCurrentEvidence.create(root: root, referenceDirectory: reference.directory, backup: backup, request: request, observation: observation, region: .clock, current: .present(Data("TIME".utf8)))
        let plan = try SNESClockRecoveryPlan.prepare(referenceDirectory: reference.directory, currentDirectory: retained.directory, backup: backup, request: request, observation: observation, workspace: workspace)
        #expect(plan.workspace == workspace && plan.regionIndex == 1)
        #expect(plan.originalPresent == originallyPresent)
        #expect(plan.evidence == (originallyPresent ? Data([2, 4, 6]) : Data("TIME".utf8)))
        let wire = try plan.encodedRequest()
        #expect(wire.last == 2)
        #expect(Array(wire.dropLast().suffix(16)) == [123, 0, 0, 0, 0, 0, 0, 0, 200, 1, 0, 0, 0, 0, 0, 0])
        #expect(wire.count == 185 + plan.evidence.count + 4 && wire.starts(with: Data("HCRST31\0".utf8)))
        let inspection = try SNESClockRecoveryInspection.prepare(plan: plan, helperSHA256: String(repeating: "a", count: 64))
        #expect(inspection.input == wire && inspection.command.contains("--inspect-clock-recovery"))
        let receipt = Data("HC-CLOCK-INSPECT-1\n\(workspace) \(originallyPresent ? 1 : 2)\nEND\n".utf8)
        #expect(try inspection.validateReceipt(receipt))
        let same = RecoveryReadSequence(frame: receipt, changed: false)
        let captured = try await SNESClockRecoveryInspection.capture(plan: plan, helperSHA256: String(repeating: "a", count: 64), validate: {}, read: { await same.read() })
        #expect(captured == receipt)
        #expect(await same.reads == 2)
        let stableClock = RecoveryFinalValidation(failOnFourth: false)
        #expect(try await SNESClockRecoveryInspection.capture(plan: plan, helperSHA256: String(repeating: "a", count: 64), validate: {try await stableClock.check()}, read: {receipt}) == receipt)
        #expect(await stableClock.checks == 4)
        let disconnectedClock = RecoveryFinalValidation(failOnFourth: true)
        await #expect(throws: (any Error).self) { try await SNESClockRecoveryInspection.capture(plan: plan, helperSHA256: String(repeating: "a", count: 64), validate: {try await disconnectedClock.check()}, read: {receipt}) }
        let changed = RecoveryReadSequence(frame: receipt, changed: true)
        await #expect(throws: (any Error).self) { try await SNESClockRecoveryInspection.capture(plan: plan, helperSHA256: String(repeating: "a", count: 64), validate: {}, read: { await changed.read() }) }
        let disconnected = SNESLibraryConnectionSession(attachment: SNESLibraryContextTests.device(), io: RecoveryDisconnectedIO())
        await #expect(throws: (any Error).self) { try await disconnected.inspectCompatibilityClockRecovery(plan: plan, helperSHA256: String(repeating: "a", count: 64)) }
        #expect(throws: (any Error).self) { try inspection.validateReceipt(receipt + Data([0])) }
        #expect(throws: (any Error).self) { try SNESClockRecoveryInspection.prepare(plan: plan, helperSHA256: "bad'; exit") }
        if let output = ProcessInfo.processInfo.environment["HC_CLOCK_RECOVERY_WIRE_DIR"] {
            let name = originallyPresent ? "present" : "absent"
            try wire.write(to: URL(fileURLWithPath: output, isDirectory: true).appendingPathComponent(name))
            if let helperHash = ProcessInfo.processInfo.environment["HC_CLOCK_INSPECTION_HELPER_SHA"] {
                let command = try SNESClockRecoveryInspection.prepare(plan: plan, helperSHA256: helperHash)
                try Data(command.command.utf8).write(to: URL(fileURLWithPath: output, isDirectory: true).appendingPathComponent(name + "-command"))
            }
        }
        let otherRoot = root.appendingPathComponent("other-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let absent = try SNESCompatibilityCurrentEvidence.create(root: otherRoot, referenceDirectory: reference.directory, backup: backup, request: request, observation: observation, region: .clock, current: .absent)
        if originallyPresent {
            let missingCurrent = try SNESClockRecoveryPlan.prepare(referenceDirectory: reference.directory, currentDirectory: absent.directory, backup: backup, request: request, observation: observation, workspace: workspace)
            #expect(missingCurrent.originalPresent && missingCurrent.evidence == Data([2, 4, 6]))
        } else {
            #expect(throws: (any Error).self) { try SNESClockRecoveryPlan.prepare(referenceDirectory: reference.directory, currentDirectory: absent.directory, backup: backup, request: request, observation: observation, workspace: workspace) }
        }
        #expect(throws: (any Error).self) { try SNESClockRecoveryPlan.prepare(referenceDirectory: reference.directory, currentDirectory: retained.directory, backup: backup, request: request, observation: observation, workspace: "checkpoint-" + String(repeating: "2", count: 32)) }
        try Data("BAD!".utf8).write(to: retained.directory.appendingPathComponent("current.bin"))
        #expect(throws: (any Error).self) { try SNESClockRecoveryPlan.prepare(referenceDirectory: reference.directory, currentDirectory: retained.directory, backup: backup, request: request, observation: observation, workspace: workspace) }
        #expect(throws: (any Error).self) { try plan.encodedRequest() }
        try Data("TIME".utf8).write(to: retained.directory.appendingPathComponent("current.bin"))
        #expect(try plan.encodedRequest() == wire)
        let sourceFile = request.source.directory.appendingPathComponent(request.source.filename), sourceBytes = try Data(contentsOf: sourceFile)
        let changedSource = RecoveryFinalSourceMutation(url: sourceFile)
        await #expect(throws: (any Error).self) { try await SNESClockRecoveryInspection.capture(plan: plan, helperSHA256: String(repeating: "a", count: 64), validate: {try await changedSource.check()}, read: {receipt}) }
        try sourceBytes.write(to: sourceFile)
        #expect(try plan.encodedRequest() == wire)
        let backupFile = backup.directory.appendingPathComponent("data-0/file-0000.bin")
        try Data("BAD!".utf8).write(to: backupFile)
        #expect(throws: (any Error).self) { try plan.encodedRequest() }
    }
    @Test(arguments: ["symlink", "hardlink", "extra", "permissions", "session", "backup"])
    func durableReferenceRejectsUnsafeOrChangedInputs(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (backup, inventory, request, _) = try await fixture(root, includeSave: true)
        let created = try SNESCompatibilityRecoveryReference.create(root: root, backup: backup, current: inventory, request: request)
        let record = created.directory.appendingPathComponent("record.json"), outside = root.appendingPathComponent("outside")
        try Data("do not change".utf8).write(to: outside)
        var candidate = request
        switch fault {
        case "symlink":
            try FileManager.default.removeItem(at: record)
            try FileManager.default.createSymbolicLink(at: record, withDestinationURL: outside)
        case "hardlink":
            try FileManager.default.removeItem(at: record)
            try FileManager.default.linkItem(at: outside, to: record)
        case "extra": try Data([1]).write(to: created.directory.appendingPathComponent("foreign"))
        case "permissions": try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: created.directory.path)
        case "session":
            var frame = request.frame; frame[83] ^= 1
            candidate = SNESCompatibilityLaunchRequest(frame: frame, source: request.source)
        default: try Data([9]).write(to: backup.directory.appendingPathComponent("data-0/file-0000.bin"))
        }
        #expect(throws: (any Error).self) { try SNESCompatibilityRecoveryReference.open(directory: created.directory, backup: backup, current: inventory, request: candidate) }
        #expect(throws: (any Error).self) { try SNESCompatibilityRecoveryReference.openHistorical(directory: created.directory, backup: backup, request: candidate) }
        #expect(try Data(contentsOf: outside) == Data("do not change".utf8))
    }
    @Test func directoryOccupyingSavePathIsNotTreatedAsAnAbsentSave() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, _, request, _) = try await fixture(root, includeSave: false)
        let f = SNESLibraryInventoryTests(), nonce = UUID()
        let parts = ["clover", "profiles", "0", "CLV-U-ABCDE", "hakchi", SNESCompatibilityCorePackage.engineID, request.source.sha256, "battery.srm"]
        let dirs = (1..<parts.count).map { "DIR \(f.hex(parts.prefix($0 + 1).joined(separator: "/"))) 448\n" }.joined()
        let raw = String(decoding: try f.frame(challenge: nonce), as: UTF8.self).replacingOccurrences(of: "END\n", with: dirs + "END\n")
        let inventory = try f.parse(Data(raw.utf8), challenge: nonce)
        let backup = try await SNESLibraryBackup.capture(inventory: inventory, root: root, read: { _, _ in Data("{}".utf8) }, refresh: { inventory })
        #expect(throws: (any Error).self) { try SNESCompatibilityBackupEvidence.capture(backup: backup, current: inventory, request: request) }
    }
    @Test(arguments: ["digest", "token", "epoch", "game"])
    func mismatchedOrIncompleteSessionNeverProducesEvidence(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (backup, inventory, request, _) = try await fixture(root, includeSave: false)
        var frame = request.frame
        switch fault {
        case "digest": frame[19] = frame[19] == 97 ? 98 : 97
        case "token": frame.replaceSubrange(83..<99, with: Data(repeating: 0, count: 16))
        case "epoch": frame.replaceSubrange(99..<107, with: Data(repeating: 0, count: 8))
        default: frame[18] = 70
        }
        let malformed = SNESCompatibilityLaunchRequest(frame: frame, source: request.source)
        #expect(throws: (any Error).self) { try SNESCompatibilityBackupEvidence.capture(backup: backup, current: inventory, request: malformed) }
    }
    @Test func staleOrModifiedBackupAndChangedRequestAreRefused() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (backup, inventory, request, _) = try await fixture(root, includeSave: true)
        let f = SNESLibraryInventoryTests(), nonce = UUID(), other = try f.parse(f.frame(challenge: nonce), challenge: nonce)
        #expect(throws: (any Error).self) { try SNESCompatibilityBackupEvidence.capture(backup: backup, current: other, request: request) }
        var frame = request.frame; frame[8] = 0
        let malformed = SNESCompatibilityLaunchRequest(frame: frame, source: request.source)
        #expect(throws: (any Error).self) { try SNESCompatibilityBackupEvidence.capture(backup: backup, current: inventory, request: malformed) }
        let payload = backup.directory.appendingPathComponent("data-0/file-0000.bin")
        try Data([9, 9]).write(to: payload)
        #expect(throws: (any Error).self) { try SNESCompatibilityBackupEvidence.capture(backup: backup, current: inventory, request: request) }
    }
}

private actor RecoveryDisconnectedIO: SNESLibraryConnectionIO {
    func open() throws { throw SNESLibraryInventory.failure() }
    func inventory() -> [RecoveryProbeUSBDevice] { [] }
    func identity(challenge: UUID) -> Data { Data() }
    func report(installation: SNESLibraryInstallation, challenge: UUID) -> Data { Data() }
    func libraryInventory(context: SNESLibraryContext, challenge: UUID) -> Data { Data() }
    func librarySpace(context: SNESLibraryContext, selection: SNESLibraryInventory.Selection, challenge: UUID) -> Data { Data() }
    func libraryChunk(context: SNESLibraryContext, file: SNESLibraryInventory.File, offset: Int, challenge: UUID) -> Data { Data() }
    func disconnect() {}
}

private actor RecoveryReadSequence {
    let frame: Data, changed: Bool
    private(set) var reads = 0
    init(frame: Data, changed: Bool) { self.frame = frame; self.changed = changed }
    func read() -> Data { reads += 1; return changed && reads == 2 ? frame + Data([0]) : frame }
}
private actor RetainedValidationSequence {
    private var checks=0
    func check() throws { checks += 1; if checks == 2 { throw SNESLibraryMenu.failure() } }
}
private actor RecoveryFinalValidation {
    private(set) var checks=0
    private let failOnFourth: Bool
    init(failOnFourth: Bool) { self.failOnFourth = failOnFourth }
    func check() throws { checks += 1; if failOnFourth && checks == 4 { throw SNESLibraryMenu.failure() } }
}
private actor RecoveryFinalSourceMutation {
    private var checks=0
    private let url: URL
    init(url: URL) { self.url = url }
    func check() throws { checks += 1; if checks == 4 { try Data([9]).write(to:url) } }
}
