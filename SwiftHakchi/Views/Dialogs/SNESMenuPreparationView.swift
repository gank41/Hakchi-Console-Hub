import SwiftUI
import AppKit

/// Guides the menu check, temporary test and separately approved update.
struct SNESMenuPreparationView: View {
    @StateObject private var flow: SNESMenuPreparationFlow
    @Binding private var busy: Bool
    @State private var ready = false
    @State private var showUpgradeApproval = false
    private let onNormalBootProblem: () -> Void
    private let app: AppState
    private let record: SNESReviewedInstallationRecord
    private let stage: SNESMenuSetupStageContext

    init?(app: AppState, record: SNESReviewedInstallationRecord, busy: Binding<Bool>, onNormalBootProblem: @escaping () -> Void,
          stage suppliedStage: SNESMenuSetupStageContext? = nil, resuming: SNESReviewedUpgradeRecord? = nil) {
        guard let stage = suppliedStage ?? (try? SNESMenuSetupStageContext(stage: .menu, parent: nil)) else { return nil }
        guard let flow = try? SNESMenuPreparationFlow(record: record, prepare: { check in
            if let parent = stage.parent { return try await app.prepareSNESLibraryStartup(after: check, menu: parent, confirmed: true) }
            return try await app.prepareSNESMenuStartup(after: check)
        }, check: { check, candidate in
            try await app.checkSNESMenuStartup(after: check, menu: stage.parent, candidate: candidate, ready: true) { _ in }
        }, trial: { check, candidate, preflight, started in
            try await app.runSNESMenuStartupTrial(after: check, menu: stage.parent, candidate: candidate, preflight: preflight, started: started, ready: true) { _ in }
        }, upgrade: SNESMenuUpgradeOperations(prepare: { check, candidate, preflight, started, played in
            try await app.prepareSNESMenuUpgrade(after: check, menu: stage.parent, candidate: candidate, preflight: preflight, started: started, played: played, confirmed: true)
        }, preflight: { check, upgrade in
            try await app.runSNESMenuUpgrade(upgrade, after: check, menu: stage.parent, mode: .preflight, ready: true) { _ in }
        }, install: { check, upgrade in
            try await app.runSNESMenuUpgrade(upgrade, after: check, menu: stage.parent, mode: .write, ready: true, approved: true) { _ in }
        }, checkMenu: { check, upgrade in
            try await app.checkSNESMenuUpgrade(upgrade, after: check, menu: stage.parent, ready: true)
        }, accept: { check, upgrade in
            try await app.acceptSNESMenuUpgrade(upgrade, after: check, menu: stage.parent, confirmed: true)
        }), freshBackup: SNESMenuFreshBackupOperations(backup: { check in
            try await app.backupSNESReviewedCurrentData(after: check, ready: true) { _ in }
        }, rebuild: { check, backup in
            if let parent = stage.parent { return try await app.prepareSNESLibraryStartup(after: check, menu: parent, currentData: backup, confirmed: true) }
            return try await app.prepareSNESMenuStartup(after: check, currentData: backup)
        }), resuming: resuming) else { return nil }
        _flow = StateObject(wrappedValue: flow); _busy = busy; self.onNormalBootProblem = onNormalBootProblem
        self.app = app; self.record = record; self.stage = stage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(stage.stage == .menu ? "Prepare the game menu" : "Prepare game folders").font(.headline)
            switch flow.phase {
            case .ready:
                Text("Prepare the next setup files on this Mac. This does not connect to or change the SNES.")
                Button("Prepare Menu Files") {
                    guard !busy else { return }
                    busy = true
                    Task { defer { busy = false }; await flow.prepare() }
                }.disabled(busy)
            case .preparing:
                HStack { ProgressView().controlSize(.small); Text("Preparing menu files on this Mac…") }
            case .prepared:
                Label("Menu files prepared", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                if let candidate = flow.candidate {
                    Button("Show Menu Files in Finder") { NSWorkspace.shared.activateFileViewerSelecting([candidate.directory]) }
                }
                Text("The next check compares the SNES with its backup and checks the menu files. It does not install an update.")
                    .foregroundStyle(.secondary)
                Text("Close other Hakchi apps. Turn the SNES OFF and unplug USB for 10 seconds. Slide power ON while unplugged, hold RESET while reconnecting USB, wait five seconds, then release RESET.")
                Toggle("The power light is off and the TV is blank", isOn: $ready).disabled(busy)
                Button("Check SNES and Backup") {
                    guard !busy, ready else { return }
                    busy = true
                    Task { await flow.runCheck(ready: true) }
                }.disabled(busy || !ready)
            case .checking:
                HStack { ProgressView().controlSize(.small); Text("Checking the SNES and backup…") }
                Text("Keep power and USB connected. This may take several minutes.").foregroundStyle(.secondary)
            case .returnToNormal:
                Text("Return the SNES to its normal menu").font(.headline)
                Text("Turn it OFF, unplug USB for 10 seconds, reconnect with RESET released, then turn it ON normally. Wait for the game-selection menu.")
                HStack {
                    Button("Menu Doesn't Work") { flow.confirmNormalMenu(visible: false); busy = false; onNormalBootProblem() }
                    Button("Menu Is Visible") { flow.confirmNormalMenu(visible: true); ready = false; busy = false }
                }
            case .checked:
                Label("SNES and backup checked", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("The next test starts the menu temporarily. It installs no update; normal game progress may be saved during play.").foregroundStyle(.secondary)
                Text("Turn the SNES OFF, unplug USB for 10 seconds, then slide power ON while unplugged. Hold RESET while reconnecting USB, wait five seconds, then release RESET.")
                Toggle("The power light is off and the TV is blank", isOn: $ready).disabled(busy)
                Button("Start Temporary Menu") {
                    guard !busy, ready else { return }
                    busy = true
                    Task { await flow.startTrial(ready: true) }
                }.disabled(busy || !ready)
            case .trialStarting:
                HStack { ProgressView().controlSize(.small); Text("Starting the temporary menu…") }
                Text("Keep power and USB connected.").foregroundStyle(.secondary)
            case .trialPlaying:
                Text("Check the temporary menu and play an included game. Check picture, sound and controls, then press RESET and return to the game menu. Leave power and USB connected.")
                HStack {
                    Button("Something Doesn't Work") { Task { await flow.confirmTrialGame(works: false) } }
                    Button("Menu and Game Work") { Task { await flow.confirmTrialGame(works: true) } }
                }
            case .trialChecking:
                HStack { ProgressView().controlSize(.small); Text("Checking the temporary test…") }
            case .trialReturnToNormal:
                Text("Return the SNES to its normal menu").font(.headline)
                Text("Turn it OFF, unplug USB for 10 seconds, reconnect with RESET released, then turn it ON normally. Wait for the game-selection menu.")
                HStack {
                    Button("Menu Doesn't Work") { flow.confirmTrialNormalMenu(visible: false); busy = false; onNormalBootProblem() }
                    Button("Menu Is Visible") { flow.confirmTrialNormalMenu(visible: true); ready = false; busy = false }
                }
            case .trialComplete:
                Label("Temporary menu test checked", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Prepare a review of the menu update on this Mac. This does not change the SNES.").foregroundStyle(.secondary)
                Button("Prepare Menu Update Review") {
                    guard !busy else { return }; busy = true
                    Task { defer { busy = false }; await flow.prepareUpgrade() }
                }.disabled(busy)
            case .trialFailed:
                Label("Temporary test stopped", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("No update was installed. Keep the backup and check the details before trying again.")
                if let error = flow.error { DisclosureGroup("Details") { Text(error).textSelection(.enabled) } }
            case .needsBackup:
                Label("A current backup is needed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("The games or saved data changed since this backup. Make a new backup before continuing. No update was installed.")
                Button("Review New Backup") { flow.reviewFreshBackup(); ready = false }.disabled(busy)
            case .backupInstructions:
                Text("Make a new backup of the SNES on this Mac. Existing backups stay in place. This does not install an update.")
                Text("Turn the SNES OFF, unplug USB for 10 seconds, slide power ON while unplugged, then hold RESET while reconnecting USB. Wait five seconds and release RESET.")
                Toggle("The power light is off and the TV is blank", isOn: $ready).disabled(busy)
                Button("Make New Backup") {
                    guard !busy, ready else { return }; busy = true
                    Task { await flow.startFreshBackup(ready: true) }
                }.disabled(busy || !ready)
            case .backingUp:
                HStack { ProgressView().controlSize(.small); Text("Saving and checking the SNES backup…") }
                Text("Keep power and USB connected. This may take several minutes.").foregroundStyle(.secondary)
            case .backupReturnToNormal:
                Text("Return the SNES to its normal menu").font(.headline)
                Text("Turn it OFF, unplug USB for 10 seconds, reconnect with RESET released, then turn it ON normally. Wait for the game-selection menu.")
                HStack {
                    Button("Menu Doesn't Work") { flow.confirmBackupNormalMenu(visible: false); busy = false; onNormalBootProblem() }
                    Button("Menu Is Visible") { flow.confirmBackupNormalMenu(visible: true); ready = false; busy = false }
                }
            case .backupReady:
                Label("New backup saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                if let backup = flow.freshBackup {
                    Button("Show Backup in Finder") { NSWorkspace.shared.activateFileViewerSelecting([backup.directory]) }
                }
                Text("Prepare the menu files using this backup, then check the SNES again.")
                Button("Prepare Menu Files") {
                    guard !busy else { return }; busy = true
                    Task { defer { busy = false }; await flow.rebuildWithFreshBackup() }
                }.disabled(busy)
            case .backupPreparing:
                HStack { ProgressView().controlSize(.small); Text("Preparing menu files using the new backup…") }
            case .backupFailed:
                Label("Backup or preparation stopped", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Keep the existing backups. No update was installed.")
                if let error = flow.error { DisclosureGroup("Details") { Text(error).textSelection(.enabled) } }
            case .checkFailed:
                Label("Console check stopped", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("No update was installed. Keep the backup and check the details before trying again.")
                if let error = flow.error { DisclosureGroup("Details") { Text(error).textSelection(.enabled) } }
            case .needsAttention:
                Label("Normal startup needs attention", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Keep the backup and do not continue setup until the SNES starts normally.")
            case .upgradePreparing:
                HStack { ProgressView().controlSize(.small); Text("Preparing the update review…") }
            case .upgradePrepared:
                Label("Menu update review prepared", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                if let upgrade = flow.upgrade {
                    Button("Show Update Review in Finder") { NSWorkspace.shared.activateFileViewerSelecting([upgrade.operation]) }
                }
                Text("Check the update without installing it. Turn the SNES OFF, unplug USB for 10 seconds, slide power ON while unplugged, then hold RESET while reconnecting USB. Wait five seconds and release RESET.")
                Toggle("The power light is off and the TV is blank", isOn: $ready).disabled(busy)
                Button("Check Update") {
                    guard !busy, ready else { return }; busy = true
                    Task { await flow.runUpgradePreflight(ready: true) }
                }.disabled(busy || !ready)
            case .upgradePreflighting:
                HStack { ProgressView().controlSize(.small); Text("Checking the update without installing…") }
                Text("Keep power and USB connected.").foregroundStyle(.secondary)
            case .upgradePreflightReturn:
                Text("Return the SNES to its normal menu").font(.headline)
                Text("Turn it OFF, unplug USB for 10 seconds, reconnect with RESET released, then turn it ON normally. Wait for the game-selection menu.")
                HStack {
                    Button("Menu Doesn't Work") { flow.confirmUpgradePreflightNormalMenu(visible: false); busy = false; onNormalBootProblem() }
                    Button("Menu Is Visible") { flow.confirmUpgradePreflightNormalMenu(visible: true); ready = false; busy = false }
                }
            case .upgradeReady:
                Label("Menu update checked", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("This update writes startup software. Turn the SNES OFF, unplug USB for 10 seconds, slide power ON while unplugged, then hold RESET while reconnecting USB. Wait five seconds and release RESET.")
                Toggle("The power light is off and the TV is blank", isOn: $ready).disabled(busy)
                Button("Review Menu Update…") { showUpgradeApproval = true }.disabled(busy || !ready)
            case .upgrading:
                HStack { ProgressView().controlSize(.small); Text("Installing the menu update…") }
                Text("Keep power and USB connected until the update finishes.").foregroundStyle(.secondary)
            case .upgradeRestart:
                Label("Menu update checked after writing", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Turn the SNES OFF, unplug USB for 10 seconds, reconnect with RESET released, then turn it ON normally. Wait for the game-selection menu.")
                HStack {
                    Button("Menu Doesn't Work") { flow.reportInstalledMenuProblem(); busy = false; onNormalBootProblem() }
                    Button("Menu Is Visible") {
                        guard flow.phase == .upgradeRestart else { return }; busy = true
                        Task { await flow.checkInstalledMenu(visible: true); if flow.phase == .needsAttention { busy = false } }
                    }
                }
            case .upgradeVerifying:
                HStack { ProgressView().controlSize(.small); Text("Checking the normal startup…") }
            case .upgradeGameTest:
                Text("Play one included game. Check picture, sound and controls, then press RESET to return to the game menu.")
                HStack {
                    Button("Game Doesn't Work") { Task { await flow.confirmInstalledGame(works: false); busy = false } }
                    Button("Game Works") { Task { await flow.confirmInstalledGame(works: true); busy = false } }
                }
            case .upgradeAccepting:
                HStack { ProgressView().controlSize(.small); Text("Saving your confirmation…") }
            case .upgradeComplete:
                Label(stage.stage == .menu ? "Menu update complete" : "Game-folder update complete", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                if let upgrade = flow.upgrade, let nextStage = stage.next(after: upgrade),
                   let next = SNESMenuPreparationView(app: app, record: record, busy: $busy, onNormalBootProblem: onNormalBootProblem, stage: nextStage) {
                    AnyView(next)
                } else if stage.stage == .gameFolders, let upgrade = flow.upgrade,
                          let finish = SNESLibrarySetupCompletionView(app: app, record: record, stage: stage, upgrade: upgrade, busy: $busy) {
                    finish
                }
            case .upgradeStopped:
                Label("Menu update stopped", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Keep the backup and saved update review. Check the details before continuing.")
                if let error = flow.error { DisclosureGroup("Details") { Text(error).textSelection(.enabled) } }
                Button("Review New Backup") { flow.reviewFreshBackup(); ready = false }.disabled(busy)
            case .upgradeUncertain:
                Label("Menu update needs attention", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Keep power and USB connected. Do not restart or retry the update; keep the backup and review for help.")
                if let error = flow.error { DisclosureGroup("Details") { Text(error).textSelection(.enabled) } }
            case .upgradeWriteReturnToNormal:
                Label("Update stopped before writing", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Turn the SNES OFF, unplug USB for 10 seconds, reconnect with RESET released, then turn it ON normally. Wait for the game-selection menu.")
                HStack {
                    Button("Menu Doesn't Work") { flow.confirmStoppedWriteNormalMenu(visible: false); busy = false; onNormalBootProblem() }
                    Button("Menu Is Visible") { flow.confirmStoppedWriteNormalMenu(visible: true); ready = false; busy = false }
                }
            case .failed:
                Label("Menu preparation stopped", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("The first update and its backup are unchanged. Check the details before preparing the files again.")
                if let error = flow.error { DisclosureGroup("Details") { Text(error).textSelection(.enabled) } }
            }
        }
        .alert("Install the menu update?", isPresented: $showUpgradeApproval) {
            Button("Cancel", role: .cancel) { }
            Button("Install Menu Update") {
                guard !busy, ready else { return }; busy = true
                Task {
                    await flow.installUpgrade(ready: true, approved: true)
                    if flow.phase == .upgradeUncertain { busy = false }
                }
            }
        } message: {
            Text("This writes startup software to the SNES. This new app workflow has not yet been tested on a new SNES. Keep power and USB connected until the app finishes.")
        }
    }
}
