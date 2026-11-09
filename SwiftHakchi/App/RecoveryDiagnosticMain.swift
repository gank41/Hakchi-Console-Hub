import Foundation
import SwiftHakchiCore
import Darwin

enum RecoveryDiagnosticOptions: Equatable, Sendable {
    case inspect, boot
    case snapshot(String), installEvidence(String), snesSetup(String), dataLayout, persistent
    static func parse(_ arguments: [String]) throws -> Self {
        if arguments.isEmpty || arguments == ["--inspect"] { return .inspect }
        if arguments == ["--boot-recovery"] { return .boot }
        if arguments == ["--inspect-data-layout"] { return .dataLayout }
        if arguments == ["--inspect-persistent"] { return .persistent }
        if arguments.count == 2, arguments[0] == "--snapshot-boot2", arguments[1].hasPrefix("/"), !arguments[1].contains("\0") {
            return .snapshot(arguments[1])
        }
        if arguments.count == 2, arguments[0] == "--snapshot-install-evidence", arguments[1].hasPrefix("/"), !arguments[1].contains("\0") {
            return .installEvidence(arguments[1])
        }
        if arguments.count == 2, arguments[0] == "--snapshot-snes-setup", arguments[1].hasPrefix("/"), !arguments[1].contains("\0") {
            return .snesSetup(arguments[1])
        }
        throw RecoveryProbeError.refused("Usage: SwiftHakchiRecoveryProbe [--inspect | --boot-recovery | --snapshot-boot2 /existing/Backups | --snapshot-install-evidence /existing/Backups | --snapshot-snes-setup /existing/Backups | --inspect-data-layout | --inspect-persistent]. Default inspect is offline. Stock restore modes require a separate reviewed journal; no generic reset option exists.")
    }
}
enum RecoveryDiagnosticRunner {
    static func run(mode: RecoveryDiagnosticOptions, inputs: RecoveryBootInputs,
                    makeIO: @Sendable () -> any RecoveryProbeIO,
                    checkHost: @escaping @Sendable () async throws -> Void = { try await RecoveryProbeUSBRegistry.requireOrdinaryAppClosed() },
                    progress: @escaping RecoveryProgressSink = { _ in }) async throws -> String {
        let prepared = try inputs.prepare()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if mode == .inspect {
            let values: [String: String] = ["mode": "inspect", "rawBootSHA256": BackupManifest.digest(inputs.bootImage),
                "rawUBootSHA256": BackupManifest.digest(inputs.uboot), "rawFes1SHA256": BackupManifest.digest(inputs.fes1),
                "preparedBootSHA256": BackupManifest.digest(prepared.bootImage), "preparedUBootSHA256": BackupManifest.digest(prepared.uboot)]
            var json: [String: Any] = values
            json["firmwareRestoreEligible"] = false
            json["USBOpened"] = false
            return String(decoding: try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted,.sortedKeys]), as: UTF8.self)
        }
        let store: RecoveryBootSnapshotStore?
        switch mode {
        case .snapshot(let path), .installEvidence(let path), .snesSetup(let path):
            store = try RecoveryBootSnapshotStore(root: URL(fileURLWithPath:path))
        case .inspect, .boot, .dataLayout, .persistent: store = nil
        }
        try await checkHost()
        if case .snesSetup = mode, let store {
            do {
                let report = try await SNESSetupReadinessService().capture(inputs: inputs, io: makeIO(), progress: progress)
                let path = try await store.saveSNESSetup(report)
                return String(decoding: try JSONSerialization.data(withJSONObject:
                    ["snapshotDirectory": path.path, "firmwareRestoreEligible": false], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
            } catch let failure as SNESSetupDiagnosticFailure {
                let path = try await store.saveSNESSetupDiagnostic(failure)
                throw SNESSetupDiagnosticSavedError(directory: path)
            }
        }
        let report = try await RecoveryRAMProbe().run(inputs: inputs, io: makeIO(),
            captureBoot2: store != nil, captureInstallEvidence: { if case .installEvidence = mode { true } else { false } }(),
            captureDataLayout: mode == .dataLayout, capturePersistentInventory: mode == .persistent,
            progress: progress)
        if let store {
            let path = try await store.save(report)
            return String(decoding: try JSONSerialization.data(withJSONObject: ["snapshotDirectory":path.path,"firmwareRestoreEligible":false], options:[.prettyPrinted,.sortedKeys]), as:UTF8.self)
        }
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }
}

#if RECOVERY_DIAGNOSTIC
/// A separate build variant; the GUI app and AppState are never instantiated here.
@main
struct RecoveryDiagnosticMain {
    static func main() async {
        setbuf(stdout, nil) // Recovery progress must remain visible when evidence is redirected.
        let arguments = Array(CommandLine.arguments.dropFirst())
        let writeRequested = arguments.first == "--write-stock-boot2" || arguments.first == "--write-legacy-boot2"
        do {
            if arguments == ["--check-packaged-resources"] {
                let bundle = Bundle.appBundle
                for (name, ext) in [("hakchi", "hmod"), ("basehmods", "tar"),
                                    ("SNESCompatibilityController", "cfg")] {
                    guard bundle.url(forResource: name, withExtension: ext) != nil else {
                        throw RecoveryProbeError.refused("A required packaged resource is missing.")
                    }
                }
                print("Packaged resources are available.")
                return
            }
            try await SNESOfflineBuildDiagnostic.dispatch(arguments, progress: {
                FileHandle.standardError.write(Data(($0 + "\n").utf8))
            }) {
            if let result = try await SNESLibraryInspectionDiagnostic.runIfPresent(arguments) { print(result); return }
            if let result = try await SNESCompatibilityInputDiagnostic.runIfPresent(arguments) { print(result); return }
            if let result = try await SNESPowerInputDiagnostic.runIfPresent(arguments) { print(result); return }
            if let result = try await SNESFrontendSupportDiagnostic.runIfPresent(arguments) { print(result); return }
            if let result = try await SNESCompatibilitySupportDiagnostic.runIfPresent(arguments) { print(result); return }
            if let result = try await SNESLibraryStartupDiagnostic.runIfPresent(arguments, progress: {
                FileHandle.standardError.write(Data(($0.title + "\n").utf8))
            }) { print(result); return }
            if let result = try await SNESMenuStartupDiagnostic.runIfPresent(arguments, progress: {
                FileHandle.standardError.write(Data(($0.title + "\n").utf8))
            }) { print(result); return }
            if let result = try await SNESOriginalGamesDiagnostic.runIfPresent(arguments) { print(result); return }
            if let result = try await SNESOneGameDiagnostic.runIfPresent(arguments) { print(result); return }
            if let result = try await SNESOneGameMenuTrialDiagnostic.runIfPresent(arguments) { print(result); return }
            if let result = try await SNESMenuFirmwareDiagnostic.runIfPresent(arguments) { print(result); return }
            if let result = try await SNESMenuSelectionDiagnostic.runIfPresent(arguments) { print(result); return }
            if let result = try await SNESFirmwareDiagnostic.runIfPresent(arguments, progress: {
                FileHandle.standardError.write(Data(($0.title + "\n").utf8))
            }) { print(result); return }
            if let result = try await SNESActiveBoot2Diagnostic.runIfPresent(arguments, progress: {
                FileHandle.standardError.write(Data(($0.title + "\n").utf8))
            }) { print(result); return }
            if let result = try await SNESStartupTrialDiagnostic.runIfPresent(arguments, makeIO: {
                NativeSNESStartupTrialIO(trial: $0)
            }, progress: {
                FileHandle.standardError.write(Data(($0.title + "\n").utf8))
            }) { print(result); return }
            if let result = try await SNESStartupPreflightDiagnostic.runIfPresent(arguments, makeIO: {
                try NativeSNESStartupPreflightIO(candidate: $0)
            }, progress: {
                FileHandle.standardError.write(Data(($0.title + "\n").utf8))
            }) { print(result); return }
            if let result = try await SNESDataSnapshotDiagnostic.runIfPresent(arguments, progress: {
                FileHandle.standardError.write(Data(($0.title + "\n").utf8))
            }, detail: {
                FileHandle.standardError.write(Data(($0 + "\n").utf8))
            }) { print(result); return }
            if let result = try await SNESRAMMenuDiagnostic.runIfPresent(arguments) { print(result); return }
            if let result = try await SNESAlienTrialDiagnostic.runIfPresent(arguments) { print(result); return }
            if let result = try await SNESOriginalMenuDiagnostic.runIfPresent(arguments, progress: {
                FileHandle.standardError.write(Data(($0.title + "\n").utf8))
            }) { print(result); return }
            if let result = try await SNESOriginalComponentDiagnostic.runIfPresent(arguments, progress: {
                FileHandle.standardError.write(Data(($0.title + "\n").utf8))
            }) { print(result); return }
            if let result = try await SNESTemporaryMenuDiagnostic.runIfPresent(arguments, progress: {
                FileHandle.standardError.write(Data(($0.title + "\n").utf8))
            }) { print(result); return }
            if let result = try await SNESMenuSupportDiagnostic.runIfPresent(arguments, progress: {
                FileHandle.standardError.write(Data(($0.title + "\n").utf8))
            }) { print(result); return }
            if let result = try await SNESPreparationDiagnostic.runIfPresent(arguments, progress: {
                FileHandle.standardError.write(Data(($0.title + "\n").utf8))
            }) { print(result); return }
            if let result = try await SNESRAMProbeDiagnostic.runIfPresent(arguments, progress: {
                FileHandle.standardError.write(Data(($0.title + "\n").utf8))
            }) { print(result); return }
            if arguments.count == 3, arguments[0] == "--prepare-structure-trial" {
                print(try LegacyStructureTrialDiagnostic.prepare(code: arguments[1],
                    backup: URL(fileURLWithPath: arguments[2])))
                return
            }
            if arguments.count == 2, let id = UUID(uuidString: arguments[1]) {
                switch arguments[0] {
                case "--stage-structure-trial":
                    print(try await LegacyStructureTrialDiagnostic.stage(operationID: id)); return
                case "--activate-structure-trial":
                    print(try await LegacyStructureTrialDiagnostic.activate(operationID: id)); return
                case "--rollback-structure-trial":
                    print(try await LegacyStructureTrialDiagnostic.rollback(operationID: id)); return
                default: break
                }
            }
            if arguments.count == 2, arguments[0] == "--inspect-legacy-transaction",
               let operationID = UUID(uuidString: arguments[1]) {
                print(try await LegacySyncInspectionDiagnostic.run(operationID: operationID))
                return
            }
            if arguments.count == 2, arguments[0] == "--inspect-legacy-stage",
               let operationID = UUID(uuidString: arguments[1]) {
                print(try await LegacyStageInventoryDiagnostic.run(operationID: operationID))
                return
            }
            if arguments.count == 2, arguments[0] == "--reconcile-legacy-stage",
               let operationID = UUID(uuidString: arguments[1]) {
                print(try await LegacyStageInventoryDiagnostic.run(operationID: operationID,
                    reconcile: true))
                return
            }
            if arguments.count == 3, arguments[0] == "--stage-legacy-trial" {
                print(try await LegacyTrialStageDiagnostic.run(code: arguments[1], backup: URL(fileURLWithPath: arguments[2])))
                return
            }
            if let nonce = try SNESRAMMenuLogRequest.parse(arguments) {
                try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed()
                let devices = try RecoveryProbeUSBRegistry.inventory()
                guard devices.count == 1, let device = devices.first else {
                    throw RecoveryProbeError.refused("Connect exactly one temporary SNES menu test. No console command was sent.")
                }
                _ = try SNESOriginalMenuUSBPolicy.nativeIdentity(device)
                let client = LegacyInspectionClient(transport: SNESOriginalMenuUSBTransport(expected: device), maximumOutputBytes: 65536)
                try await client.connect(timeoutMilliseconds: 5000)
                do {
                    let result = try await client.execute(.snesOriginalMenuDiagnostics, timeoutMilliseconds: 10000)
                    guard result.succeeded else { throw RecoveryProbeError.refused("The temporary menu log capture failed.") }
                    _ = try SNESOriginalMenuDiagnostics(result.stdoutData, nonce: nonce.uuidString)
                    await client.disconnect()
                    FileHandle.standardOutput.write(result.stdoutData)
                } catch { await client.disconnect(); throw error }
                return
            }
            if arguments == ["--read-snes-ram-menu-lifecycle"] {
                try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed()
                let devices = try RecoveryProbeUSBRegistry.inventory()
                guard devices.count == 1, let device = devices.first else {
                    throw RecoveryProbeError.refused("Connect exactly one temporary SNES menu test. No console command was sent.")
                }
                _ = try SNESOriginalMenuUSBPolicy.nativeIdentity(device)
                let client = LegacyInspectionClient(transport: SNESOriginalMenuUSBTransport(expected: device), maximumOutputBytes: 4096)
                try await client.connect(timeoutMilliseconds: 5000)
                do {
                    let result = try await client.readSNESRAMLifecycle()
                    guard result.succeeded else { throw RecoveryProbeError.refused("The temporary owner lifecycle capture failed.") }
                    _ = try SNESRAMLifecycleObservation.parse(result.stdoutData)
                    await client.disconnect()
                    print(String(decoding: result.stdoutData, as: UTF8.self), terminator: "")
                } catch { await client.disconnect(); throw error }
                return
            }
            if arguments == ["--read-snes-ram-menu-processes"] {
                try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed()
                let devices = try RecoveryProbeUSBRegistry.inventory()
                guard devices.count == 1, let device = devices.first else {
                    throw RecoveryProbeError.refused("Connect exactly one temporary SNES menu test. No console command was sent.")
                }
                _ = try SNESOriginalMenuUSBPolicy.nativeIdentity(device)
                let client = LegacyInspectionClient(transport: SNESOriginalMenuUSBTransport(expected: device), maximumOutputBytes: 65536)
                try await client.connect(timeoutMilliseconds: 5000)
                do {
                    let launch = try await client.readSNESRAMLaunchObservation()
                    guard launch.succeeded else { throw RecoveryProbeError.refused("The temporary launch observation is unavailable.") }
                    _ = try SNESRAMLaunchObservation.parse(launch.stdoutData)
                    let result = try await client.readSNESRAMTrialProcesses()
                    guard result.succeeded else { throw RecoveryProbeError.refused("The read-only temporary process snapshot failed.") }
                    _ = try SNESNativeProcessSnapshot.parse(result.stdoutData, allowTemporaryTrial: true)
                    await client.disconnect()
                    print(String(decoding: launch.stdoutData, as: UTF8.self), terminator: "")
                    print(String(decoding: result.stdoutData, as: UTF8.self), terminator: "")
                } catch { await client.disconnect(); throw error }
                return
            }
            if arguments == ["--read-snes-native-time-inventory"] {
                try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed()
                let devices = try RecoveryProbeUSBRegistry.inventory()
                guard devices.count == 1, let device = devices.first, ConsoleAttachmentPolicy.kind(of: device) == .nativeSNES else {
                    throw RecoveryProbeError.refused("Connect exactly one normally booted SNES Classic. No console command was sent.")
                }
                let client = LegacyInspectionClient()
                try await client.connect(timeoutMilliseconds: 5000)
                do {
                    let result = try await client.readSNESNativeTimeInventory()
                    guard result.succeeded else { throw RecoveryProbeError.refused("The read-only play-time inventory failed.") }
                    _ = try SNESNativeTimeInventory.parse(result.stdoutData)
                    await client.disconnect()
                    print(String(decoding: result.stdoutData, as: UTF8.self), terminator: "")
                } catch { await client.disconnect(); throw error }
                return
            }
            if arguments == ["--read-snes-native-processes"] || arguments == ["--read-snes-native-launch-options"] {
                let additionalOptions = arguments == ["--read-snes-native-launch-options"]
                try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed()
                let devices = try RecoveryProbeUSBRegistry.inventory()
                guard devices.count == 1, let device = devices.first, ConsoleAttachmentPolicy.kind(of: device) == .nativeSNES else {
                    throw RecoveryProbeError.refused("Connect exactly one normally booted SNES Classic. No console command was sent.")
                }
                let client = LegacyInspectionClient()
                try await client.connect(timeoutMilliseconds: 5000)
                do {
                    let result = try await (additionalOptions ? client.readSNESNativeLaunchOptionNames() : client.readSNESNativeProcessSnapshot())
                    guard result.succeeded else { throw RecoveryProbeError.refused("The read-only process snapshot failed.") }
                    _ = try SNESNativeProcessSnapshot.parse(result.stdoutData, allowAdditionalOptions: additionalOptions)
                    await client.disconnect()
                    print(String(decoding: result.stdoutData, as: UTF8.self), terminator: "")
                } catch { await client.disconnect(); throw error }
                return
            }
            if arguments == ["--read-legacy-identity"] {
                try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed()
                let client = LegacyInspectionClient()
                try await client.connect(timeoutMilliseconds: 3000)
                do {
                    let output = try await LegacyDeviceIdentityDiagnostic.run(client: client)
                    await client.disconnect()
                    print(output)
                } catch {
                    await client.disconnect()
                    throw error
                }
                return
            }
            if arguments.count == 2, arguments[0] == "--backup-legacy-console" {
                let destination = RecoveryFirmwareJournalPolicy.root.deletingLastPathComponent()
                guard URL(fileURLWithPath: arguments[1]).standardizedFileURL == destination else {
                    throw RecoveryProbeError.refused("Legacy console backups require the fixed private NES Backups folder. No USB command was sent.")
                }
                try RecoveryFirmwareJournalPolicy.requireOwner()
                try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed()
                let client = LegacyInspectionClient()
                try await client.connect(timeoutMilliseconds: 3000)
                do {
                    let output = try await LegacyBackupDiagnostic.run(client: client, destination: destination)
                    await client.disconnect()
                    print(output)
                } catch {
                    await client.disconnect()
                    throw error
                }
                return
            }
            if let legacyMode = try LegacyBoot2ActivationDiagnosticOptions.parseIfPresent(arguments) {
                print(try await LegacyBoot2ActivationDiagnostic.run(mode: legacyMode,
                    loadInputs: { try await PayloadService.shared.pinnedRecoveryInputs() },
                    makeIO: { NativeLegacyBoot2ActivationIO() }))
                return
            }
            if let stockMode = try StockRestoreDiagnosticOptions.parseIfPresent(arguments) {
                print(try await StockRestoreDiagnostic.run(mode:stockMode,
                    loadInputs:{ try await PayloadService.shared.pinnedRecoveryInputs() }, makeIO:{ NativeStockRestoreIO() }))
                return
            }
            let mode = try RecoveryDiagnosticOptions.parse(arguments)
            let inputs = try await PayloadService.shared.pinnedRecoveryInputs()
            if mode != .inspect {
                print(try await RecoveryDiagnosticRunner.run(mode: .inspect, inputs: inputs, makeIO: { NativeRecoveryProbeIO() }))
            }
            let observation: String
            if case .snesSetup = mode { observation = SNESBackupPolicy.command }
            else { observation = RecoveryProbeCommand.observation }
            print(try await RecoveryDiagnosticRunner.run(mode: mode, inputs: inputs,
                makeIO: { NativeRecoveryProbeIO(observationCommand: observation) },
                progress: { print($0.title) }))
            }
        } catch {
            let message:String
            if SNESMenuSelectionDiagnostic.handles(arguments.first) {message=SNESMenuSelectionDiagnostic.failureMessage(arguments:arguments,error:error)}
            else if SNESFirmwareDiagnostic.handles(arguments.first) {message=SNESFirmwareDiagnostic.failureMessage(arguments:arguments,error:error)}
            else if arguments.first?.contains("legacy") == true {message=LegacyBoot2ActivationDiagnostic.failureMessage(writeRequested:writeRequested,error:error)}
            else {message=StockRestoreDiagnostic.failureMessage(writeRequested:writeRequested,error:error)}
            FileHandle.standardError.write(Data(message.utf8))
            exit(2)
        }
    }
}
#endif
