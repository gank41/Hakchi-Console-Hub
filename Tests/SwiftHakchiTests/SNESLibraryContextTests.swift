import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESLibraryContextTests {
    static func device(version: UInt16 = 0x6a07, product: String = "Swift Hakchi SNES Startup", id: UInt64 = 44) -> RecoveryProbeUSBDevice {
        .init(vendorID: 0x1f3a, productID: 0xefe8, deviceVersion: version, deviceClass: 0, locationID: 123, product: product, registryEntryID: id)
    }
    @Test func nativeStartupRecognitionNeverMakesRecoveryOrOtherProductsWritable() throws {
        for version: UInt16 in [0x6a04, 0x6a05, 0x6a06, 0x6a07, 0x6a08, 0x6a09, 0x6a0a, 0x6a0b] {
            #expect(ConsoleAttachmentPolicy.kind(of: Self.device(version: version)) == .nativeSNES)
        }
        #expect(ConsoleAttachmentPolicy.kind(of: Self.device(version: 0x6a0c)) == .unsupported)
        #expect(ConsoleAttachmentPolicy.kind(of: Self.device(product: "classic")) == .unsupported)
        #expect(ConsoleAttachmentPolicy.kind(of: probeFEL()) == .recovery)
        #expect(ConsoleAttachmentPolicy.single([Self.device(), ConsoleAttachmentTests.legacy()]) == nil)
    }
    @Test func identityNeedsItsFreshChallengeAndSupportedModel() throws {
        let challenge = UUID(), chip = String(repeating: "1", count: 32)
        let text = "SWIFTHAKCHI_SNES_IDENTITY_V1\nCHALLENGE=\(challenge.uuidString)\nBOARD=dp-shvc\nREGION=USA\nKERNEL=3.4.113\nHWID=\(chip)\nEND\n"
        #expect(try SNESLibraryIdentity(Data(text.utf8), challenge: challenge).hwid == chip)
        for changed in [text + "extra\n", text.replacingOccurrences(of: "REGION=USA", with: "REGION=EUR"), text.replacingOccurrences(of: chip, with: String(repeating: "0", count: 32))] {
            #expect(throws: (any Error).self) { try SNESLibraryIdentity(Data(changed.utf8), challenge: challenge) }
        }
        #expect(throws: (any Error).self) { try SNESLibraryIdentity(Data(text.utf8), challenge: UUID()) }
    }
    @Test func fixedDiscoveryScriptReturnsOnlyTheChallengedSupportedIdentity() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let busybox = root.appendingPathComponent("busybox"), board = root.appendingPathComponent("boardtype"), region = root.appendingPathComponent("REGION")
        let shim = """
        #!/bin/sh
        case "$1" in
          stat) printf '1:0\\n';;
          sha256sum) exec /usr/bin/shasum -a 256 "$2";;
          uname) printf '3.4.113\\n';;
          cat) exec /bin/cat "$2";;
          devmem) case "$2" in 0x01c23800|0x01c23804|0x01c23808|0x01c2380c) printf '0x11111111\\n';; *) exit 97;; esac;;
          *) exit 98;;
        esac
        """
        try Data(shim.utf8).write(to: busybox); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: busybox.path)
        try Data("dp-shvc\n".utf8).write(to: board)
        for value in ["USA", "EUR"] {
            try Data((value + "\n").utf8).write(to: region)
            let challenge = UUID(), script = SNESLibraryIdentity.command(challenge: challenge)
                .replacingOccurrences(of: "/mnt/swifthakchi/busybox", with: busybox.path)
                .replacingOccurrences(of: "/etc/clover", with: root.path)
                .replacingOccurrences(of: "440b72b46c50939356768f35ea02b682176ca49ef07b3702ee75912af74aabd6", with: BackupManifest.digest(Data(shim.utf8)))
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", script]; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run(); let raw = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            if value == "USA" {
                #expect(process.terminationStatus == 0)
                #expect(try SNESLibraryIdentity(raw, challenge: challenge).hwid == String(repeating: "1", count: 32))
            } else { #expect(process.terminationStatus != 0) }
        }
    }
    @Test func indexRoundTripIsInertBoundedAndRefusesLinksOrUnknownFields() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let chip = String(repeating: "1", count: 32)
        let reference = SNESLibraryInstallationReference(hwid: chip, operationID: UUID(), reviewSHA256: String(repeating: "a", count: 64),
            catalog: root.appendingPathComponent("SNES-Original-Games-" + UUID().uuidString), catalogSHA256: String(repeating: "b", count: 64))
        let url = try SNESLibraryInstallationIndex.save(reference, root: root)
        #expect(try SNESLibraryInstallationIndex.load(hwid: chip, root: root)?.reference == reference)
        #expect(try SNESLibraryInstallationIndex.load(hwid: String(repeating: "2", count: 32), root: root) == nil)
        let loaded = try #require(try SNESLibraryInstallationIndex.load(hwid: chip, root: root))
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["ignoreUnresolvedOperation"] = true
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(throws: (any Error).self) { try SNESLibraryInstallationIndex.load(hwid: chip, root: root) }
        #expect(throws: (any Error).self) { try loaded.validate() }
        try FileManager.default.removeItem(at: url)
        let other = root.appendingPathComponent("other"); try Data([0]).write(to: other)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: other)
        #expect(throws: (any Error).self) { try SNESLibraryInstallationIndex.load(hwid: chip, root: root) }
    }
    @MainActor private func assertNativeReviewRouting(context: SNESLibraryContext, session: SNESLibraryConnectionSession,
                                                     attachment: RecoveryProbeUSBDevice) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig(); config.workspacePath = root.path
        let manager = DeviceManager(connectRuntime: { _ in
            var info = ConnectedConsoleInfo(consoleType: .snesUsa)
            info.nativeSNES = session; info.nativeSNESContext = context; return info
        })
        let app = AppState(startDeviceMonitoring: false, deviceManager: manager, gameManager: GameManagerService(config: config), config: config, saveConfiguration: {})
        await manager.inspectAttachments([attachment])
        #expect(app.canReviewLibrarySync && !manager.canSync && !manager.canInteract)
        await app.onConsoleConnected()
        #expect(app.statusMessage == (context.supportsLibrarySync
            ? "SNES connected. Choose Sync Library to review your games."
            : "SNES connected. Complete Console Setup before syncing games."))
        app.reviewLibrarySync()
        #expect(app.showSNESLibrarySync && !app.showLegacyFullSync && app.isPreparingSync)
        app.isPreparingSync = false
    }
    @Test @MainActor func nativeFingerprintCannotGrantLegacyActionsOrPretendItIsFEL() async {
        let manager = DeviceManager(connectRuntime: { _ in
            var info = ConnectedConsoleInfo(consoleType: .snesUsa)
            info.canSync = true; info.canInteract = true
            return info
        })
        await manager.inspectAttachments([Self.device()])
        #expect(manager.isConnected && manager.consoleType == .snesUsa)
        #expect(!manager.felDevicePresent && !manager.canInteract && !manager.canSync)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_LIBRARY_PARENT"] != nil))
    func currentInstallFindsOriginalCatalogThroughAcceptedAncestors() async throws {
        let env = ProcessInfo.processInfo.environment
        let operation = URL(fileURLWithPath: try #require(env["SWIFTHAKCHI_SNES_LIBRARY_PARENT"]))
        let review = try #require(env["SWIFTHAKCHI_SNES_LIBRARY_PARENT_REVIEW"])
        let catalog = URL(fileURLWithPath: try #require(env["SWIFTHAKCHI_SNES_LIBRARY_CATALOG"]))
        let pins = try PinnedFELInputs.load(), recovery = RecoveryBootInputs(fes1: pins.fes1, uboot: pins.uboot, bootImage: pins.bootImage)
        let m = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: operation.appendingPathComponent("plan.json"))) as? [String: Any])
        let binding = try #require(m["binding"] as? [String: Any]), chip = try #require(binding["expectedHWID"] as? String)
        let reference = SNESLibraryInstallationReference(hwid: chip, operationID: try #require(UUID(uuidString: operation.lastPathComponent.replacingOccurrences(of: "SNESFirmware-", with: ""))),
            reviewSHA256: review, catalog: catalog, catalogSHA256: BackupManifest.digest(try Data(contentsOf: catalog.appendingPathComponent("manifest.json"))))
        let installation = try await SNESLibraryInstallation.resolve(reference: reference, journals: operation.deletingLastPathComponent(), recovery: recovery)
        #expect(installation.originals.frame.entries.count == 21)
        #expect(installation.accepted.material.id == reference.operationID)
        let version = installation.expected.deviceVersion
        #expect([UInt16(0x6a05), UInt16(0x6a06), UInt16(0x6a07), UInt16(0x6a0b)].contains(version))
        #expect(installation.supportsLibrarySync == (version == 0x6a07 || version == 0x6a0b))
        #expect(installation.originals.directoryURL == catalog)
        try installation.validate()
        let indexRoot = try testDirectory(); defer { try? FileManager.default.removeItem(at: indexRoot) }
        let discovered: SNESLibraryInstallationReference
        if env["HC_CONTEXT_RACE_ONLY"] != nil { discovered = reference }
        else { discovered = try #require(try SNESLibraryInstallationIndex.discover(hwid: chip, deviceVersion: version,
            journals: operation.deletingLastPathComponent(), backups: [catalog.deletingLastPathComponent()])) }
        #expect(discovered.operationID == reference.operationID)
        _ = try SNESLibraryInstallationIndex.save(discovered, root: indexRoot)
        let index = try #require(try SNESLibraryInstallationIndex.load(hwid: chip, root: indexRoot))
        let liveInstallation = try await SNESLibraryInstallation.resolve(reference: discovered, journals: operation.deletingLastPathComponent(), recovery: recovery)
        let ids = [UUID(), UUID()], epoch = UUID(), attachment = Self.device(version: version)
        let reports = ids.map { challenge in
            Data(String(decoding: startupTrialReportFixture(challenge: challenge, hwid: liveInstallation.expected.hwid,
                runtime: liveInstallation.expected.runtimeSHA256, wrapper: liveInstallation.expected.wrapperSHA256), as: UTF8.self)
                .replacingOccurrences(of: "MOUNTS_END", with: "tmpfs /etc/init.d/S81clover-mcp tmpfs rw 0 0\n" + (liveInstallation.supportsLibrarySync ? "tmpfs /usr/share/applications/clover-mcp.desktop tmpfs rw 0 0\n" : "") + "MOUNTS_END").utf8)
        }
        let context = try SNESLibraryContext.verify(installation: liveInstallation, index: index, attachment: attachment,
            sessionID: epoch, challenges: ids, reports: reports)
        try context.requireCurrent(attachment: attachment, sessionID: epoch)
        #expect(context.supportsLibrarySync == (version == 0x6a07 || version == 0x6a0b) && context.sha256.count == 64)
        #expect(throws: (any Error).self) { try context.requireCurrent(attachment: Self.device(version: version, id: 45), sessionID: epoch) }
        #expect(throws: (any Error).self) { try context.requireCurrent(attachment: attachment, sessionID: UUID()) }
        #expect(throws: (any Error).self) { try SNESLibraryContext.verify(installation: liveInstallation, index: index,
            attachment: Self.device(version: version == 0x6a06 ? 0x6a05 : 0x6a06), sessionID: epoch, challenges: ids, reports: reports) }
        #expect(throws: (any Error).self) { try SNESLibraryContext.verify(installation: liveInstallation, index: index,
            attachment: attachment, sessionID: epoch, challenges: [ids[0], ids[0]], reports: reports) }
        let liveIO = SNESContextLiveFake(installation: liveInstallation, attachment: attachment)
        let session = SNESLibraryConnectionSession(attachment: attachment, io: liveIO)
        let connected = try await session.connect(sessionID: epoch, loadOwner: { _, _ in .init(installation: liveInstallation, index: index) })
        try await session.requireCurrent(connected)
        if env["HC_RETAIN_RACE_ONLY"] == nil {
        let inventoryGate = SNESContextGate(), reportGate = SNESContextGate()
        await liveIO.holdNextInventory(inventoryGate)
        await liveIO.holdNextReport(reportGate)
        let firstCheck = Task { try await session.requireCurrent(connected) }
        await inventoryGate.waitUntilEntered()
        let concurrentObservation = Task { try await session.observe(connected) }
        await reportGate.waitUntilEntered()
        await inventoryGate.release()
        await #expect(throws: (any Error).self) { try await firstCheck.value }
        await reportGate.release()
        _ = try await concurrentObservation.value
        let completedGate = SNESContextGate()
        await liveIO.holdNextInventory(completedGate)
        let earlierCheck = Task { try await session.requireCurrent(connected) }
        await completedGate.waitUntilEntered()
        _ = try await session.observe(connected)
        await completedGate.release()
        await #expect(throws: (any Error).self) { try await earlierCheck.value }
        }
        if env["HC_RETAIN_RACE_ONLY"] != nil {
            let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let (backup, inventory, request, _) = try await SNESCompatibilityBackupEvidenceTests().fixture(root, includeSave: false)
            let reference = try SNESCompatibilityRecoveryReference.create(root: root, backup: backup, current: inventory, request: request)
            let base = "/var/lib/clover/profiles/0/CLV-U-ABCDE/hakchi/\(SNESCompatibilityCorePackage.engineID)/\(request.source.sha256)"
            let token = String(repeating: "07", count: 16)
            let descriptor = Data("HC-BINDING-1\nCLV-U-ABCDE\n\(request.source.sha256)\n\(token)\n2\n2\n0 123 456 \(base)/battery.srm\n1 123 456 \(base)/battery.rtc\n".utf8)
            let frame = Data("HC-RECOVERY-OBS-1\n123 456 \(descriptor.count) 0\n".utf8) + descriptor + Data("HC-RECOVERY-OBS-END\n".utf8)
            await liveIO.setRecoveryFrame(frame)
            let gate = SNESContextGate(); await liveIO.holdRetentionCheck(gate)
            let retention = Task {
                do { return try await session.retainCompatibilityCurrent(request: request, helperSHA256: String(repeating: "a", count: 64), directory: reference.directory, backup: backup, region: .clock, root: root) }
                catch { await gate.cancel(); throw error }
            }
            await gate.waitUntilEntered()
            await #expect(throws: (any Error).self) { try await session.observe(connected) }
            await gate.release()
            let retained = try await retention.value
            #expect(retained.current == .present(Data("TIME".utf8)))
            let resumed = try await session.retainCompatibilityCurrent(request: request, helperSHA256: String(repeating: "a", count: 64), directory: reference.directory, backup: backup, region: .clock, root: root)
            #expect(resumed.directory == retained.directory && resumed.current == retained.current)
            await session.disconnect(); return
        }
        if env["HC_CONTEXT_RACE_ONLY"] != nil { await session.disconnect(); return }
        #expect(await liveIO.closes == 0)
        let observation = try await session.observe(connected)
        #expect(observation.context.sha256 == connected.sha256)
        #expect(observation.inventory.capacity.freeBytes == 64000 * 4096)
        #expect(observation.capacity.freeBytes == 63000 * 4096)
        #expect(observation.inventory.catalogSHA256 == (try SNESLibraryCatalogIdentity.digest(liveInstallation.originals.frame)))
        try await session.requireCurrent(observation)
        #expect(try SNESLibrarySpace(observation.rawSpace, challenge: observation.spaceChallenge, contextSHA256: connected.sha256,
            hwid: connected.installation.expected.hwid).freeBytes == observation.capacity.freeBytes)
        #expect(observation.reports.count == 2 && Set(observation.reportChallenges).count == 2)
        let backupRoot = try testDirectory(); defer { try? FileManager.default.removeItem(at: backupRoot) }
        let backup = try await session.captureBackup(observation, root: backupRoot)
        #expect(try backup.read(path: "clover/settings.json") == Data("{}".utf8))
        let reuse = try await session.captureBackup(observation, root: backupRoot)
        #expect(reuse.directory == backup.directory)
        let romDirectory = backupRoot.appendingPathComponent("CLV-U-ABCDE", isDirectory: true)
        try FileManager.default.createDirectory(at: romDirectory, withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: romDirectory.appendingPathComponent("game.sfc"))
        var recoveryGame = Game(code: "CLV-U-ABCDE", desktopContent: "Name=Game\n", consoleType: .snesUsa, source: .local)
        recoveryGame.romPath = romDirectory.path
        let source = try SNESLibraryROMSource.capture(directory: romDirectory, filename: "game.sfc").0
        let managerInventory = try await session.captureCompatibilityManagerInventory(game: recoveryGame, source: source, helperSHA256: String(repeating: "a", count: 64))
        #expect(managerInventory.sessions.isEmpty && managerInventory.incompleteWorkspaces.isEmpty)
        #expect(await liveIO.managerInventoryReads == 1)
        let request = try SNESCompatibilityLaunchRequest.prepare(game: recoveryGame, source: source, session: Data(repeating: 7, count: 16), epoch: 2)
        let recoveryReference = try SNESCompatibilityRecoveryReference.create(root: backupRoot, backup: backup, current: observation.inventory, request: request)
        let base = "/var/lib/clover/profiles/0/CLV-U-ABCDE/hakchi/\(SNESCompatibilityCorePackage.engineID)/\(source.sha256)"
        let token = String(repeating: "07", count: 16)
        let descriptor = Data("HC-BINDING-1\nCLV-U-ABCDE\n\(source.sha256)\n\(token)\n2\n2\n0 123 456 \(base)/battery.srm\n1 123 456 \(base)/battery.rtc\n".utf8)
        let frame = Data("HC-RECOVERY-OBS-1\n123 456 \(descriptor.count) 0\n".utf8) + descriptor + Data("HC-RECOVERY-OBS-END\n".utf8)
        await liveIO.setRecoveryFrame(frame)
        let recovered = try await session.captureCompatibilityRecovery(request: request, helperSHA256: String(repeating: "a", count: 64), directory: recoveryReference.directory, backup: backup)
        #expect(recovered.saves.battery == .absent && recovered.saves.clock == .absent && recovered.pending.isEmpty)
        #expect(await liveIO.recoveryReads == 2)
        let routingIO = SNESContextLiveFake(installation: liveInstallation, attachment: attachment)
        let routingSession = SNESLibraryConnectionSession(attachment: attachment, io: routingIO)
        try await assertNativeReviewRouting(context: connected, session: routingSession, attachment: attachment)
        #expect(await routingIO.closes == 0)
        await liveIO.replaceAttachment()
        await #expect(throws: (any Error).self) { try await session.requireCurrent(connected) }
        await session.disconnect()
        await #expect(throws: (any Error).self) { try await session.requireCurrent(observation) }
        #expect(await liveIO.closes == 1)
        let badIO = SNESContextLiveFake(installation: liveInstallation, attachment: attachment)
        let badSession = SNESLibraryConnectionSession(attachment: attachment, io: badIO)
        let badContext = try await badSession.connect(sessionID: UUID(), loadOwner: { _, _ in .init(installation: liveInstallation, index: index) })
        await badIO.invalidateSpace()
        await #expect(throws: (any Error).self) { try await badSession.observe(badContext) }
        #expect(await badIO.closes == 1)

        var changed = discovered
        changed = SNESLibraryInstallationReference(hwid: changed.hwid, operationID: UUID(), reviewSHA256: changed.reviewSHA256,
            catalog: changed.catalog, catalogSHA256: changed.catalogSHA256)
        _ = try SNESLibraryInstallationIndex.save(changed, root: indexRoot)
        #expect(throws: (any Error).self) { try context.requireCurrent(attachment: attachment, sessionID: epoch) }
        let wrong = SNESLibraryInstallationReference(hwid: String(repeating: "2", count: 32), operationID: reference.operationID,
            reviewSHA256: reference.reviewSHA256, catalog: catalog, catalogSHA256: reference.catalogSHA256)
        await #expect(throws: (any Error).self) { try await SNESLibraryInstallation.resolve(reference: wrong, journals: operation.deletingLastPathComponent(), recovery: recovery) }
    }
}

private actor SNESContextLiveFake: SNESLibraryConnectionIO {
    let installation: SNESLibraryInstallation
    var attachment: RecoveryProbeUSBDevice
    private(set) var closes = 0
    private var badSpace = false
    private var recoveryFrame = Data()
    private var inventoryGate: SNESContextGate?, reportGate: SNESContextGate?
    private var retentionGate: SNESContextGate?, retentionInventoryReads = 0
    func holdRetentionCheck(_ gate: SNESContextGate) { retentionGate = gate; retentionInventoryReads = 0 }
    func holdNextInventory(_ gate: SNESContextGate) { inventoryGate = gate }
    func holdNextReport(_ gate: SNESContextGate) { reportGate = gate }
    private(set) var managerInventoryReads = 0
    func compatibilityManagerInventory(context: SNESLibraryContext, game: Game, source: SNESLibraryROMSource, helperSHA256: String) throws -> SNESCompatibilityManagerInventory.Observation {
        managerInventoryReads += 1
        return try SNESCompatibilityManagerInventory.parse(Data("HCMINV2\0\0\0".utf8),game:game,source:source)
    }
    private(set) var recoveryReads = 0
    func setRecoveryFrame(_ frame: Data) { recoveryFrame = frame }
    func compatibilityRecovery(context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest, helperSHA256: String) -> Data { recoveryReads += 1; return recoveryFrame }
    func compatibilityRecoveryCurrent(context: SNESLibraryContext, request: SNESCompatibilityLaunchRequest, helperSHA256: String, region: SNESRecoveryRegion) -> Data {
        Data("HC-RECOVERY-CURRENT-1\n123 456 rtc 1 4\nTIMEHC-RECOVERY-CURRENT-END\n".utf8)
    }
    init(installation: SNESLibraryInstallation, attachment: RecoveryProbeUSBDevice) { self.installation = installation; self.attachment = attachment }
    func open() {}
    func inventory() async -> [RecoveryProbeUSBDevice] {
        if let gate = inventoryGate { inventoryGate = nil; await gate.pause() }
        if recoveryReads >= 4, let gate = retentionGate {
            retentionInventoryReads += 1
            if retentionInventoryReads == 3 { retentionGate = nil; await gate.pause() }
        }
        return [attachment]
    }
    func identity(challenge: UUID) -> Data {
        Data("SWIFTHAKCHI_SNES_IDENTITY_V1\nCHALLENGE=\(challenge.uuidString)\nBOARD=dp-shvc\nREGION=USA\nKERNEL=3.4.113\nHWID=\(installation.expected.hwid)\nEND\n".utf8)
    }
    func report(installation: SNESLibraryInstallation, challenge: UUID) async -> Data {
        if let gate = reportGate { reportGate = nil; await gate.pause() }
        let base = startupTrialReportFixture(challenge: challenge, hwid: installation.expected.hwid,
            runtime: installation.expected.runtimeSHA256, wrapper: installation.expected.wrapperSHA256)
        return Data(String(decoding: base, as: UTF8.self).replacingOccurrences(of: "MOUNTS_END", with: "tmpfs /etc/init.d/S81clover-mcp tmpfs rw 0 0\n" + (installation.supportsLibrarySync ? "tmpfs /usr/share/applications/clover-mcp.desktop tmpfs rw 0 0\n" : "") + "MOUNTS_END").utf8)
    }
    func libraryInventory(context: SNESLibraryContext, challenge: UUID) throws -> Data {
        let catalog = try SNESLibraryCatalogIdentity.digest(installation.originals.frame)
        let profile = BackupManifest.digest(Data("{}".utf8)), path = Data("clover/settings.json".utf8).map { String(format: "%02x", $0) }.joined()
        return Data("SWIFTHAKCHI_SNES_LIBRARY_INVENTORY_V1 \(challenge.uuidString)\nCONTEXT \(context.sha256)\nHWID \(installation.expected.hwid)\nCATALOG \(catalog)\nSPACE 4096 76800 64000\nNAMESPACE absent absent\nSELECTOR builtin - - \(BackupManifest.digest(Data()))\nDIR 636c6f766572 448\nFILE \(path) 2 \(profile) 384 0 1 9999 0\nEND\n".utf8)
    }
    func librarySpace(context: SNESLibraryContext, selection: SNESLibraryInventory.Selection, challenge: UUID) -> Data {
        let nonce = badSpace ? UUID() : challenge
        return Data("SWIFTHAKCHI_SNES_SPACE_V1 \(nonce.uuidString)\nCONTEXT=\(context.sha256)\nHWID=\(installation.expected.hwid)\nSPACE=4096 76800 63000\nEND\n".utf8)
    }
    func libraryChunk(context: SNESLibraryContext, file: SNESLibraryInventory.File, offset: Int, challenge: UUID) throws -> Data {
        let bytes = Data("{}".utf8), hash = BackupManifest.digest(bytes), path = Data(file.path.utf8).map { String(format: "%02x", $0) }.joined()
        var result = Data("SWIFTHAKCHI_SNES_LIBRARY_CHUNK_V1 \(challenge.uuidString) \(context.sha256) \(path) \(offset) 2 \(hash)\n".utf8)
        result.append(bytes); result.append(Data("\nSWIFTHAKCHI_SNES_LIBRARY_CHUNK_END_V1 \(challenge.uuidString) \(hash)\n".utf8)); return result
    }
    func invalidateSpace() { badSpace = true }
    func replaceAttachment() { attachment = SNESLibraryContextTests.device(version: attachment.deviceVersion, id: 99) }
    func disconnect() { closes += 1 }
}

private actor SNESContextGate {
    private var entered = false, released = false
    private var entryWaiter: CheckedContinuation<Void, Never>?, releaseWaiter: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; entryWaiter?.resume(); entryWaiter = nil
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiter = $0 } }
    }
    func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
    func cancel() { entered = true; entryWaiter?.resume(); entryWaiter = nil; release() }
}

