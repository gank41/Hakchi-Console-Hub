import SwiftUI
import AppKit

struct SNESBackupView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var guide: SNESBackupGuide
    @State private var ready = false
    @State private var startupReady = false
    @State private var menuSupportReady = false
    @State private var componentsReady = false
    @State private var dataReady = false
    @State private var runtimeReady = false
    @State private var preflightReady = false
    @State private var trialReady = false
    @State private var trialBackupUnderstood = false
    @State private var activeReady = false
    @State private var freshDataReady = false
    @State private var showingResume = false
    @State private var showingSavedReview = false
    @State private var initialSavedReview: SNESFirstInstallReviewReceipt?
    @State private var firstStageInstalled = false
    @State private var showingRestorePreparation = false
    init(execute: @escaping @Sendable (@escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt,
         prepareRecovery: @escaping @Sendable (SNESSetupRecordReceipt) async throws -> URL,
         prepareHelpers: @escaping @Sendable () async throws -> URL,
         prepareStartup: @escaping @Sendable (SNESSetupRecordReceipt, URL, URL, @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt,
         captureMenuSupport: @escaping @Sendable (SNESSetupRecordReceipt, URL, URL, SNESSetupRecordReceipt, @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt,
         captureComponents: @escaping @Sendable (SNESSetupRecordReceipt, URL, URL, SNESSetupRecordReceipt, SNESSetupRecordReceipt, @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt,
         captureData: @escaping @Sendable (SNESSetupRecordReceipt, URL, URL, SNESSetupRecordChain, @escaping RecoveryProgressSink, @escaping @Sendable (String) async -> Void) async throws -> SNESDataSnapshotReceipt,
         captureRuntime: @escaping @Sendable (SNESSetupRecordReceipt, URL, URL, SNESSetupRecordChain, SNESDataSnapshotReceipt, @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt,
         prepareCandidate: @escaping @Sendable (SNESSetupRecordReceipt, URL, URL, SNESSetupRecordChain, SNESDataSnapshotReceipt, SNESSetupRecordReceipt, @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt,
         preflight: @escaping @Sendable (SNESSetupRecordReceipt, @escaping RecoveryProgressSink) async throws -> SNESStartupPreflightReceipt,
         startTrial: @escaping @Sendable (SNESSetupRecordReceipt, SNESStartupPreflightReceipt, @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt,
         checkTrial: @escaping @Sendable (SNESSetupRecordReceipt, SNESStartupPreflightReceipt, SNESSetupRecordReceipt, @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt,
         captureActive: @escaping @Sendable (SNESSetupRecordReceipt, URL, SNESSetupRecordReceipt, SNESStartupPreflightReceipt, SNESSetupRecordReceipt, SNESSetupRecordReceipt, @escaping RecoveryProgressSink) async throws -> SNESSetupRecordReceipt,
         prepareFirmwarePlan: @escaping @Sendable (SNESSetupRecordReceipt, URL, SNESSetupRecordReceipt, SNESStartupPreflightReceipt, SNESSetupRecordReceipt, SNESSetupRecordReceipt, SNESSetupRecordReceipt, SNESDataSnapshotReceipt) async throws -> SNESFirmwarePreparationReceipt) {
        _guide = StateObject(wrappedValue: SNESBackupGuide(execute: execute, prepareRecovery: prepareRecovery,
                                                         prepareHelpers: prepareHelpers, prepareStartup: prepareStartup,
                                                         captureMenuSupport: captureMenuSupport, captureComponents: captureComponents, captureData: captureData, captureRuntime: captureRuntime,
                                                         prepareCandidate: prepareCandidate, preflight: preflight,
                                                         startTrial: startTrial, checkTrial: checkTrial, captureActive: captureActive, prepareFirmwarePlan: prepareFirmwarePlan))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Set Up SNES — Backup", systemImage: "externaldrive.badge.checkmark").font(.title2.bold())
            switch guide.phase {
            case .instructions:
                Label("Your turn", systemImage: "hand.raised.fill").font(.headline).foregroundStyle(.orange)
                Text("Start by saving the SNES startup software and checking its storage. The app will check whether the saved startup is the expected original version. This step does not install software or change games or saves.")
                Text("This preview guides startup and game-folder updates. The complete setup flow has not yet been tested on a new SNES.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("This first version supports the US SNES Classic. Keep only that console connected. The steps below put it into a temporary setup mode so the Mac can check it. The power light and TV screen staying dark is expected in this mode; the app will explain when to start it normally again.").foregroundStyle(.secondary)
                GroupBox("Get your SNES ready") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Turn the SNES OFF. Unplug USB from the console and wait 10 seconds.")
                        Text("2. Slide the power switch ON while USB is still unplugged.")
                        Text("3. Hold the RESET button and reconnect USB.")
                        Text("4. Keep holding RESET for 5 seconds, then release it.")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Once you have released RESET and confirmed the light and screen are dark, select the checkbox below, then choose Start Check. Keep the USB cable connected. The app cannot tell when you release RESET.").font(.callout).foregroundStyle(.secondary)
                Toggle("I released RESET and the light and screen are dark", isOn: $ready)
                HStack {
                    Button("Resume Previous Setup…") { ready = false; showingResume = true }
                    Button("Check Saved Review…") { ready = false; initialSavedReview = nil; showingSavedReview = true }
                    Spacer()
                }
                Button("Restore Original SNES Startup…") { ready = false; showingRestorePreparation = true }
                Text("Uses a saved installation record. The app checks the console and asks before restoring startup software.").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { finish() }
                    Spacer()
                    Button("Start Check") { Task { await guide.start(ready: ready) } }
                        .disabled(!ready).keyboardShortcut(.defaultAction)
                }
            case .resumeWorking:
                HStack { ProgressView().controlSize(.small); Text("Checking saved setup files on this Mac…") }
                Text("No console changes are being made.").foregroundStyle(.secondary)
            case .resumeConfirmNormal:
                Label("Saved setup found", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                if guide.resumeUnverifiedCount > 0 {
                    Text("Some saved records could not be verified. Setup will continue from the last verified step; the files have been kept.").foregroundStyle(.orange)
                }
                Text("Before continuing, check that the SNES is on its usual game-selection menu and that a built-in game works. Connect it normally with RESET released.")
                HStack {
                    Button("Menu or Game Doesn't Work") { guide.reportNormalBootProblem() }
                    Spacer()
                    Button("Normal Menu and Game Work") { guide.confirmResumedNormalBoot() }.keyboardShortcut(.defaultAction)
                }
            case .working:
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Working…").font(.headline)
                        Text(guide.preparingRecovery ? "Preparing recovery files on this Mac" : guide.stage == .readingBootloader ? "Saving startup files" : guide.stage.title)
                    }
                }
                Text(guide.preparingRecovery ? "The console connection is closed. The app is checking the saved files on this Mac." : "Leave power and USB connected. A blank TV screen is expected. This can take several minutes.")
                    .foregroundStyle(.secondary)
            case .returnToNormal:
                if guide.errorMessage == nil {
                    Label("Backup saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("The startup backup and storage checks were saved and verified on your Mac. The recovery connection is closed.")
                } else {
                    Label("Needs attention", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("The setup check did not complete. The recovery connection is closed.")
                    Text(guide.errorMessage ?? "").foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("1. Turn the SNES off and unplug USB from the console.\n2. Wait ten seconds.\n3. Reconnect USB with RESET released, then turn it on.\n4. Check that the normal menu appears and a built-in game plays.")
                if let directory = guide.diagnosticDirectory {
                    Button("Show Diagnostic in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                HStack {
                    Button("Menu or Game Doesn't Work") { guide.reportNormalBootProblem() }
                    Spacer()
                    Button("Normal Menu and Game Work") { guide.confirmNormalBoot() }.keyboardShortcut(.defaultAction)
                }
            case .complete, .failed:
                Label(guide.phase == .complete ? "Complete" : "Needs attention", systemImage: guide.phase == .complete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(guide.phase == .complete ? Color.green : Color.orange)
                Text(guide.phase == .complete ? "SNES backup and checks complete. Your console is back in normal use." : "The console is back in normal use. No completed setup backup was saved.")
                if guide.phase == .complete { Text("Continue with the saved review to check and install the startup update.").foregroundStyle(.secondary) }
                if guide.phase == .complete, guide.recoveryDirectory != nil {
                    Text("A separate recovery package was also prepared and checked on this Mac. Restoring startup software from it is still being added to the app.")
                        .foregroundStyle(.secondary)
                }
                if guide.phase == .complete, let error = guide.recoveryError {
                    Text("Your current startup backup was saved, but the additional recovery package could not be prepared. Keep this backup and check the details below.")
                        .foregroundStyle(.orange)
                    DisclosureGroup("Recovery package details") { Text(error).textSelection(.enabled) }
                }
                if guide.phase == .complete, let error = guide.helpersError {
                    Text("Your backup was saved, but the setup helper files could not be prepared. Keep your backup; no firmware was changed.")
                        .foregroundStyle(.orange)
                    DisclosureGroup("Setup helper details") { Text(error).textSelection(.enabled) }
                }
                if let directory = guide.backupDirectory {
                    Button("Show Backup in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                if let directory = guide.recoveryDirectory {
                    Button("Show Recovery Package in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                if let directory = guide.helpersDirectory {
                    Button("Show Setup Helpers in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                if let directory = guide.diagnosticDirectory {
                    Button("Show Diagnostic in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                HStack {
                    Button("Done") { finish() }
                    Spacer()
                    if guide.canReviewStartupCheck {
                        Button("Next: Check Startup") { startupReady = false; guide.reviewStartupCheck() }.keyboardShortcut(.defaultAction)
                    }
                }
            case .startupInstructions:
                Label("Next: Check Startup", systemImage: "checkmark.shield").font(.headline)
                Text("The app will check the saved startup files against this SNES and examine its startup in temporary memory. This does not install software or change games or saves.")
                Text("First-time setup is a preview. Startup restore has limited preview support.").font(.callout).foregroundStyle(.secondary)
                GroupBox("Get your SNES ready again") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Turn the SNES OFF. Unplug USB from the console and wait 10 seconds.")
                        Text("2. Slide the power switch ON while USB is still unplugged.")
                        Text("3. Hold the RESET button and reconnect USB.")
                        Text("4. Keep holding RESET for 5 seconds, then release it.")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("The power light and TV screen should stay dark. Keep only this SNES connected.").font(.callout).foregroundStyle(.secondary)
                Toggle("I released RESET and the light and screen are dark", isOn: $startupReady)
                HStack {
                    Button("Back") { startupReady = false; guide.cancelStartupCheck() }
                    Spacer()
                    Button("Start Check") { Task { await guide.startStartupCheck(ready: startupReady) } }
                        .disabled(!startupReady).keyboardShortcut(.defaultAction)
                }
            case .startupWorking:
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Working…").font(.headline)
                        Text(guide.stage.title)
                    }
                }
                Text("Leave power and USB connected. A blank TV screen is expected. This can take several minutes.").foregroundStyle(.secondary)
            case .startupReturnToNormal:
                Label(guide.startupError == nil ? "Startup check saved" : "Needs attention",
                      systemImage: guide.startupError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(guide.startupError == nil ? Color.green : Color.orange)
                if let error = guide.startupError { Text(error).foregroundStyle(.secondary).textSelection(.enabled) }
                else { Text("The startup check was saved on your Mac. No firmware was installed.") }
                Text("1. Turn the SNES off and unplug USB from the console.\n2. Wait ten seconds.\n3. Reconnect USB with RESET released, then turn it on.\n4. Check that the normal menu appears and a built-in game plays.")
                if let directory = guide.startupDiagnosticDirectory {
                    Button("Show Diagnostic in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                HStack {
                    Button("Menu or Game Doesn't Work") { guide.reportNormalBootProblem() }
                    Spacer()
                    Button("Normal Menu and Game Work") { guide.confirmStartupNormalBoot() }.keyboardShortcut(.defaultAction)
                }
            case .startupComplete, .startupFailed:
                Label(guide.phase == .startupComplete ? "Startup check complete" : "Startup check needs attention",
                      systemImage: guide.phase == .startupComplete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(guide.phase == .startupComplete ? Color.green : Color.orange)
                Text("Your console is back in normal use. First-time setup is a preview.")
                if guide.phase == .startupFailed, let error = guide.startupError {
                    DisclosureGroup("Startup check details") { Text(error).textSelection(.enabled) }
                }
                if let directory = guide.startupDirectory {
                    Button("Show Startup Check in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                if let directory = guide.startupDiagnosticDirectory {
                    Button("Show Diagnostic in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                recoveryFileButtons
                HStack {
                    Button("Done") { finish() }
                    Spacer()
                    if guide.canReviewMenuSupport {
                        Button("Next: Save Menu Files") { menuSupportReady = false; guide.reviewMenuSupport() }.keyboardShortcut(.defaultAction)
                    }
                }
            case .menuSupportInstructions:
                Label("Next: Save Menu Files", systemImage: "square.stack.3d.up").font(.headline)
                Text("The app will check and save additional startup files from this SNES. This does not install software or change games or saves.")
                Text("First-time setup is a preview. Startup restore has limited preview support.").font(.callout).foregroundStyle(.secondary)
                GroupBox("Get your SNES ready again") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Turn the SNES OFF. Unplug USB from the console and wait 10 seconds.")
                        Text("2. Slide the power switch ON while USB is still unplugged.")
                        Text("3. Hold the RESET button and reconnect USB.")
                        Text("4. Keep holding RESET for 5 seconds, then release it.")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("The power light and TV screen should stay dark. Keep only this SNES connected.").font(.callout).foregroundStyle(.secondary)
                Toggle("I released RESET and the light and screen are dark", isOn: $menuSupportReady)
                HStack {
                    Button("Back") { menuSupportReady = false; guide.cancelMenuSupport() }
                    Spacer()
                    Button("Start Check") { Task { await guide.startMenuSupport(ready: menuSupportReady) } }
                        .disabled(!menuSupportReady).keyboardShortcut(.defaultAction)
                }
            case .menuSupportWorking:
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) { Text("Working…").font(.headline); Text(guide.stage.title) }
                }
                Text("Leave power and USB connected. A blank TV screen is expected. This can take several minutes.").foregroundStyle(.secondary)
            case .menuSupportReturnToNormal:
                Label(guide.menuSupportError == nil ? "Menu files saved" : "Needs attention",
                      systemImage: guide.menuSupportError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(guide.menuSupportError == nil ? Color.green : Color.orange)
                if let error = guide.menuSupportError { Text(error).foregroundStyle(.secondary).textSelection(.enabled) }
                else { Text("The menu files were saved on your Mac. No firmware was installed.") }
                Text("1. Turn the SNES off and unplug USB from the console.\n2. Wait ten seconds.\n3. Reconnect USB with RESET released, then turn it on.\n4. Check that the normal menu appears and a built-in game plays.")
                if let directory = guide.menuSupportDiagnosticDirectory {
                    Button("Show Diagnostic in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                HStack {
                    Button("Menu or Game Doesn't Work") { guide.reportNormalBootProblem() }
                    Spacer()
                    Button("Normal Menu and Game Work") { guide.confirmMenuSupportNormalBoot() }.keyboardShortcut(.defaultAction)
                }
            case .menuSupportComplete, .menuSupportFailed:
                Label(guide.phase == .menuSupportComplete ? "Menu files saved" : "Menu check needs attention",
                      systemImage: guide.phase == .menuSupportComplete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(guide.phase == .menuSupportComplete ? Color.green : Color.orange)
                Text("Your console is back in normal use. First-time setup is a preview.")
                if guide.phase == .menuSupportFailed, let error = guide.menuSupportError {
                    DisclosureGroup("Menu check details") { Text(error).textSelection(.enabled) }
                }
                if let directory = guide.menuSupportDirectory {
                    Button("Show Menu Files in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                if let directory = guide.menuSupportDiagnosticDirectory {
                    Button("Show Diagnostic in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                if let directory = guide.startupDirectory {
                    Button("Show Startup Check in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                recoveryFileButtons
                HStack {
                    Button("Done") { finish() }
                    Spacer()
                    if guide.canReviewComponents {
                        Button("Next: Save System Files") { componentsReady = false; guide.reviewComponents() }.keyboardShortcut(.defaultAction)
                    }
                }
            case .componentsInstructions:
                Label("Next: Save System Files", systemImage: "externaldrive.badge.checkmark").font(.headline)
                Text("The app will check and save additional original system files from this SNES. This does not install software or change games or saves.")
                Text("First-time setup is a preview. Startup restore has limited preview support.").font(.callout).foregroundStyle(.secondary)
                GroupBox("Get your SNES ready again") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Turn the SNES OFF. Unplug USB from the console and wait 10 seconds.")
                        Text("2. Slide the power switch ON while USB is still unplugged.")
                        Text("3. Hold the RESET button and reconnect USB.")
                        Text("4. Keep holding RESET for 5 seconds, then release it.")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("The power light and TV screen should stay dark. Keep only this SNES connected.").font(.callout).foregroundStyle(.secondary)
                Toggle("I released RESET and the light and screen are dark", isOn: $componentsReady)
                HStack {
                    Button("Back") { componentsReady = false; guide.cancelComponents() }
                    Spacer()
                    Button("Start Check") { Task { await guide.startComponents(ready: componentsReady) } }
                        .disabled(!componentsReady).keyboardShortcut(.defaultAction)
                }
            case .componentsWorking:
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) { Text("Working…").font(.headline); Text(guide.stage.title) }
                }
                Text("Leave power and USB connected. A blank TV screen is expected. This can take several minutes.").foregroundStyle(.secondary)
            case .componentsReturnToNormal:
                Label(guide.componentsError == nil ? "System files saved" : "Needs attention",
                      systemImage: guide.componentsError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(guide.componentsError == nil ? Color.green : Color.orange)
                if let error = guide.componentsError { Text(error).foregroundStyle(.secondary).textSelection(.enabled) }
                else { Text("The system files were saved on your Mac. No firmware was installed.") }
                Text("1. Turn the SNES off and unplug USB from the console.\n2. Wait ten seconds.\n3. Reconnect USB with RESET released, then turn it on.\n4. Check that the normal menu appears and a built-in game plays.")
                if let directory = guide.componentsDiagnosticDirectory {
                    Button("Show Diagnostic in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                HStack {
                    Button("Menu or Game Doesn't Work") { guide.reportNormalBootProblem() }
                    Spacer()
                    Button("Normal Menu and Game Work") { guide.confirmComponentsNormalBoot() }.keyboardShortcut(.defaultAction)
                }
            case .componentsComplete, .componentsFailed:
                Label(guide.phase == .componentsComplete ? "System files saved" : "System check needs attention",
                      systemImage: guide.phase == .componentsComplete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(guide.phase == .componentsComplete ? Color.green : Color.orange)
                Text("Your console is back in normal use. First-time setup is a preview.")
                if guide.phase == .componentsFailed, let error = guide.componentsError {
                    DisclosureGroup("System check details") { Text(error).textSelection(.enabled) }
                }
                if let directory = guide.componentsDirectory {
                    Button("Show System Files in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                if let directory = guide.componentsDiagnosticDirectory {
                    Button("Show Diagnostic in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                if let directory = guide.startupDirectory {
                    Button("Show Startup Check in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                if let directory = guide.menuSupportDirectory {
                    Button("Show Menu Files in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                recoveryFileButtons
                HStack {
                    Button("Done") { finish() }; Spacer()
                    if guide.canReviewDataBackup {
                        Button("Next: Back Up Console Data") { dataReady = false; guide.reviewDataBackup() }.keyboardShortcut(.defaultAction)
                    }
                }
            case .dataInstructions:
                Label("Back Up Console Data", systemImage: "externaldrive.badge.checkmark").font(.headline)
                Text("The app will make a verified copy of the SNES data storage on this Mac. This includes saves and other data stored there. Built-in game files are stored separately.")
                Text("Restoring this data backup is not yet available in the app. This step does not install software or change the console.").foregroundStyle(.secondary)
                Text("If you close setup and resume later, this step must be repeated. Earlier backups stay on your Mac.").font(.callout).foregroundStyle(.secondary)
                Text("This can take a while and needs free space on your Mac. Keep power and USB connected until the app finishes.").foregroundStyle(.secondary)
                GroupBox("Get your SNES ready again") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Turn the SNES OFF. Unplug USB from the console and wait 10 seconds.")
                        Text("2. Slide the power switch ON while USB is still unplugged.")
                        Text("3. Hold RESET and reconnect USB. Hold it for 5 seconds, then release it.")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("The power light and TV screen should stay dark. Keep only this SNES connected.").foregroundStyle(.secondary)
                Toggle("I released RESET and the light and screen are dark", isOn: $dataReady)
                HStack {
                    Button("Back") { dataReady = false; guide.cancelDataBackup() }; Spacer()
                    Button("Start Backup") { Task { await guide.startDataBackup(ready: dataReady) } }
                        .disabled(!dataReady).keyboardShortcut(.defaultAction)
                }
            case .dataWorking:
                HStack { ProgressView().controlSize(.small); Text("Backing up your SNES…").font(.headline) }
                Text(guide.dataDetail)
                Text("Leave power and USB connected. A blank TV screen is expected.").foregroundStyle(.secondary)
            case .dataReturnToNormal:
                Label(guide.dataError == nil ? "Backup saved" : "Backup needs attention", systemImage: guide.dataError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(guide.dataError == nil ? Color.green : Color.orange)
                if let error = guide.dataError { Text(error).textSelection(.enabled) }
                else { Text("The console data storage was copied and checked on this Mac. No console data was changed. Restore is not yet available in the app.") }
                if let directory = guide.dataDiagnosticDirectory { Button("Show Saved Backup in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) } }
                Text("1. Turn the SNES off and unplug USB.\n2. Wait ten seconds, reconnect USB with RESET released, and turn it on.\n3. Check the normal menu and a built-in game.")
                HStack {
                    Button("Menu or Game Doesn't Work") { guide.reportNormalBootProblem() }; Spacer()
                    Button("Normal Menu and Game Work") { guide.confirmDataNormalBoot() }.keyboardShortcut(.defaultAction)
                }
            case .dataComplete, .dataFailed:
                Label(guide.phase == .dataComplete ? "Console data backed up" : "Backup needs attention", systemImage: guide.phase == .dataComplete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(guide.phase == .dataComplete ? Color.green : Color.orange)
                Text("Your SNES is back in normal use. First-time setup is a preview.")
                if let error = guide.dataError { DisclosureGroup("Backup details") { Text(error).textSelection(.enabled) } }
                if let directory = guide.dataDirectory { Button("Show Data Backup in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) } }
                if let directory = guide.dataDiagnosticDirectory { Button("Show Saved Backup in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) } }
                recoveryFileButtons
                HStack {
                    Button("Done") { finish() }; Spacer()
                    if guide.phase == .dataFailed {
                        Button("Try Backup Again") { dataReady = false; guide.reviewDataBackup() }.keyboardShortcut(.defaultAction)
                    }
                    if guide.canReviewRuntime {
                        Button("Next: Save System Libraries") { runtimeReady = false; guide.reviewRuntime() }.keyboardShortcut(.defaultAction)
                    }
                }
            case .runtimeInstructions:
                Label("Save System Libraries", systemImage: "externaldrive.badge.checkmark").font(.headline)
                Text("The app will check the saved data backup and save the original SNES system libraries on this Mac. This does not install software or change games or saves.")
                Text("First-time setup is a preview. Startup restore has limited preview support.").foregroundStyle(.secondary)
                GroupBox("Get your SNES ready again") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Turn the SNES OFF. Unplug USB from the console and wait 10 seconds.")
                        Text("2. Slide the power switch ON while USB is still unplugged.")
                        Text("3. Hold RESET and reconnect USB. Hold it for 5 seconds, then release it.")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("The power light and TV screen should stay dark. Keep only this SNES connected.").foregroundStyle(.secondary)
                Toggle("I released RESET and the light and screen are dark", isOn: $runtimeReady)
                HStack {
                    Button("Back") { runtimeReady = false; guide.cancelRuntime() }; Spacer()
                    Button("Start Check") { Task { await guide.startRuntime(ready: runtimeReady) } }
                        .disabled(!runtimeReady).keyboardShortcut(.defaultAction)
                }
            case .runtimeWorking:
                HStack { ProgressView().controlSize(.small); Text("Checking system libraries…").font(.headline) }
                Text("The app is checking your saved backup and console. Leave power and USB connected; a blank screen is expected.").foregroundStyle(.secondary)
            case .runtimeReturnToNormal:
                Label(guide.runtimeError == nil ? "System libraries saved" : "System check needs attention", systemImage: guide.runtimeError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(guide.runtimeError == nil ? Color.green : Color.orange)
                if let error = guide.runtimeError { Text(error).textSelection(.enabled) }
                else { Text("The system libraries were copied and checked on this Mac. No software was installed.") }
                Text("1. Turn the SNES off and unplug USB.\n2. Wait ten seconds, reconnect USB with RESET released, and turn it on.\n3. Check the normal menu and a built-in game.")
                HStack {
                    Button("Menu or Game Doesn't Work") { guide.reportNormalBootProblem() }; Spacer()
                    Button("Normal Menu and Game Work") { guide.confirmRuntimeNormalBoot() }.keyboardShortcut(.defaultAction)
                }
            case .runtimeComplete, .runtimeFailed:
                Label(guide.phase == .runtimeComplete ? "System libraries saved" : "System check needs attention", systemImage: guide.phase == .runtimeComplete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(guide.phase == .runtimeComplete ? Color.green : Color.orange)
                Text("Your SNES is back in normal use. First-time setup is a preview.")
                if guide.canPrepareCandidate {
                    Text("Next, prepare startup files on this Mac. This downloads two verified tools from the original Hakchi project; nothing is sent to your console.").foregroundStyle(.secondary)
                }
                if let error = guide.runtimeError { DisclosureGroup("System check details") { Text(error).textSelection(.enabled) } }
                if let directory = guide.runtimeDirectory { Button("Show System Libraries in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) } }
                if let directory = guide.dataDirectory { Button("Show Data Backup in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) } }
                recoveryFileButtons
                HStack {
                    Button("Done") { finish() }; Spacer()
                    if guide.canPrepareCandidate {
                        Button("Prepare Startup Files") { Task { await guide.startCandidate() } }.keyboardShortcut(.defaultAction)
                    }
                }
            case .candidateWorking:
                HStack { ProgressView().controlSize(.small); Text("Preparing startup files…").font(.headline) }
                Text("The files are being prepared on this Mac. Nothing is being installed on the console.").foregroundStyle(.secondary)
            case .candidateComplete, .candidateFailed:
                Label(guide.phase == .candidateComplete ? "Startup files prepared" : "Startup preparation needs attention", systemImage: guide.phase == .candidateComplete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(guide.phase == .candidateComplete ? Color.green : Color.orange)
                Text("First-time setup is a preview. Startup restore has limited preview support.")
                if guide.phase == .candidateComplete {
                    Text("Keep the saved setup and backup folders in their current locations; the prepared files depend on them.").foregroundStyle(.secondary)
                }
                if let error = guide.candidateError { DisclosureGroup("Preparation details") { Text(error).textSelection(.enabled) } }
                if let directory = guide.candidateDirectory { Button("Show Startup Files in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) } }
                recoveryFileButtons
                HStack {
                    Button("Done") { finish() }; Spacer()
                    if guide.phase == .candidateFailed { Button("Try Again") { guide.retryCandidate() }.keyboardShortcut(.defaultAction) }
                    if guide.canReviewPreflight { Button("Next: Check Startup Files") { preflightReady = false; guide.reviewPreflight() }.keyboardShortcut(.defaultAction) }
                }
            case .preflightInstructions:
                Label("Check Startup Files", systemImage: "externaldrive.badge.checkmark").font(.headline)
                Text("The app will temporarily start its recovery tools, check your SNES and compare its data with the backup. It copies the startup files into memory and verifies them, but does not start them or install firmware. Games and saves are not changed.")
                GroupBox("Get your SNES ready") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Turn the SNES OFF. Unplug USB from the console and wait 10 seconds.")
                        Text("2. Slide the power switch ON while USB is still unplugged.")
                        Text("3. Hold RESET and reconnect USB. Hold it for 5 seconds, then release it.")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("The power light and TV should stay dark. Keep only this SNES connected.").foregroundStyle(.secondary)
                Toggle("I released RESET and the light and screen are dark", isOn: $preflightReady)
                HStack {
                    Button("Back") { preflightReady = false; guide.cancelPreflight() }; Spacer()
                    Button("Start Check") { Task { await guide.startPreflight(ready: preflightReady) } }
                        .disabled(!preflightReady).keyboardShortcut(.defaultAction)
                }
            case .preflightWorking:
                HStack { ProgressView().controlSize(.small); Text("Checking startup files…").font(.headline) }
                Text("Leave power and USB connected. This check can take several minutes; no software is being installed.").foregroundStyle(.secondary)
            case .preflightReturnToNormal:
                Label(guide.preflightError == nil && guide.preflightBackupMatches == true ? "Startup file check finished" : "Startup file check needs attention", systemImage: guide.preflightError == nil && guide.preflightBackupMatches == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(guide.preflightError == nil && guide.preflightBackupMatches == true ? Color.green : Color.orange)
                if let error = guide.preflightError { Text(error).textSelection(.enabled) }
                else if guide.preflightBackupMatches == false { Text("The console data no longer matches the saved backup. A fresh backup will be needed before installation.") }
                else { Text("The startup files were copied to memory and verified, and the console data matched the backup. The startup files have not been started or installed.") }
                Text("1. Turn the SNES off and unplug USB.\n2. Wait ten seconds, reconnect USB with RESET released, and turn it on.\n3. Check the normal menu and a built-in game.")
                HStack {
                    Button("Menu or Game Doesn't Work") { guide.reportNormalBootProblem() }; Spacer()
                    Button("Normal Menu and Game Work") { guide.confirmPreflightNormalBoot() }.keyboardShortcut(.defaultAction)
                }
            case .preflightComplete, .preflightBackupChanged, .preflightFailed:
                Label(guide.phase == .preflightComplete ? "Startup file check passed" : "Startup file check needs attention", systemImage: guide.phase == .preflightComplete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(guide.phase == .preflightComplete ? Color.green : Color.orange)
                if guide.phase == .preflightBackupChanged { Text("Your console data changed after the backup. Keep your existing backup and take a fresh one before installation.") }
                if let error = guide.preflightError { DisclosureGroup("Check details") { Text(error).textSelection(.enabled) } }
                Text("First-time setup is a preview. Startup restore has limited preview support.")
                if let directory = guide.preflightDirectory { Button("Show Startup Check in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) } }
                recoveryFileButtons
                HStack {
                    Button("Done") { finish() }; Spacer()
                    if guide.phase == .preflightBackupChanged {
                        Button("Back Up Current Console Data") { dataReady = false; guide.reviewDataBackup() }.keyboardShortcut(.defaultAction)
                    }
                    if guide.phase == .preflightFailed { Button("Try Again") { guide.retryPreflight() }.keyboardShortcut(.defaultAction) }
                    if guide.canReviewTrial { Button("Next: Temporary Startup") { trialReady = false; trialBackupUnderstood = false; guide.reviewTrial() }.keyboardShortcut(.defaultAction) }
                }
            case .trialInstructions:
                Label("Try Temporary Startup", systemImage: "play.circle").font(.headline)
                Text("The app will start the prepared software in memory. It will not install firmware. Normal settings or game progress may be saved while you play.")
                Text("The backup matched at the earlier check, before the last normal startup. Settings or saves may have changed since that backup.").foregroundStyle(.secondary)
                GroupBox("Get your SNES ready") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Turn the SNES OFF. Unplug USB from the console and wait 10 seconds.")
                        Text("2. Slide the power switch ON while USB is still unplugged.")
                        Text("3. Hold RESET and reconnect USB. Hold it for 5 seconds, then release it.")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("The power light and TV should stay dark. Keep HDMI, a controller and only this SNES connected.").foregroundStyle(.secondary)
                Toggle("I released RESET and the light and screen are dark", isOn: $trialReady)
                Toggle("I understand this test can save changes after my backup", isOn: $trialBackupUnderstood)
                HStack {
                    Button("Back") { trialReady = false; trialBackupUnderstood = false; guide.cancelTrial() }; Spacer()
                    Button("Start Temporary Test") { Task { await guide.startTrial(ready: trialReady && trialBackupUnderstood) } }
                        .disabled(!trialReady || !trialBackupUnderstood).keyboardShortcut(.defaultAction)
                }
            case .trialWorking:
                HStack { ProgressView().controlSize(.small); Text("Starting temporary software…").font(.headline) }
                Text("Leave power and USB connected. The checks can take several minutes; nothing is being installed.").foregroundStyle(.secondary)
            case .trialPlaying:
                Label("Check the SNES", systemImage: "gamecontroller").font(.headline)
                Text("If asked, choose your language. Start a built-in game and check the picture, sound and controller. Press RESET once to return to the game-selection menu, and leave the console powered on and connected.")
                Text("The Mac will then check the temporary startup again. No firmware is installed.").foregroundStyle(.secondary)
                HStack {
                    Button("Menu or Game Doesn't Work") { Task { await guide.checkTrial(gameWorks: false) } }; Spacer()
                    Button("Menu and Game Work") { Task { await guide.checkTrial(gameWorks: true) } }.keyboardShortcut(.defaultAction)
                }
            case .trialPostWorking:
                HStack { ProgressView().controlSize(.small); Text("Checking temporary startup…").font(.headline) }
                Text("Leave the game-selection menu visible and keep power and USB connected. This check can take several minutes.").foregroundStyle(.secondary)
            case .trialReturnToNormal:
                Label(guide.trialError == nil ? "Temporary check finished" : "Temporary check needs attention", systemImage: guide.trialError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(guide.trialError == nil ? Color.green : Color.orange)
                if let error = guide.trialError { Text(error).textSelection(.enabled) }
                else { Text("The temporary menu and game were checked. No firmware was installed.") }
                Text("1. Turn the SNES off and unplug USB.\n2. Wait ten seconds, reconnect USB with RESET released, and turn it on.\n3. Check the normal menu and a built-in game.")
                HStack {
                    Button("Menu or Game Doesn't Work") { guide.reportNormalBootProblem() }; Spacer()
                    Button("Normal Menu and Game Work") { guide.confirmTrialNormalBoot() }.keyboardShortcut(.defaultAction)
                }
            case .trialComplete, .trialFailed:
                Label(guide.phase == .trialComplete ? "Temporary startup checked" : "Temporary startup needs attention", systemImage: guide.phase == .trialComplete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(guide.phase == .trialComplete ? Color.green : Color.orange)
                if let error = guide.trialError { DisclosureGroup("Test details") { Text(error).textSelection(.enabled) } }
                Text("First-time setup is a preview. Startup restore has limited preview support.")
                if let directory = guide.trialDiagnosticDirectory { Button("Show Test Diagnostic in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) } }
                recoveryFileButtons
                HStack {
                    Button("Done") { finish() }; Spacer()
                    if guide.canReviewActiveBackup { Button("Next: Save Startup Area") { activeReady = false; guide.reviewActiveBackup() }.keyboardShortcut(.defaultAction) }
                }
            case .activeInstructions:
                Label("Save Startup Area", systemImage: "externaldrive.badge.checkmark").font(.headline)
                Text("The app will copy and verify a small part of the SNES startup storage on this Mac. This does not install firmware or change games or saves.")
                GroupBox("Get your SNES ready") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Turn the SNES OFF. Unplug USB from the console and wait 10 seconds.")
                        Text("2. Slide the power switch ON while USB is still unplugged.")
                        Text("3. Hold RESET and reconnect USB. Hold it for 5 seconds, then release it.")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("The power light and TV should stay dark. Keep only this SNES connected.").foregroundStyle(.secondary)
                Toggle("I released RESET and the light and screen are dark", isOn: $activeReady)
                HStack {
                    Button("Back") { activeReady = false; guide.cancelActiveBackup() }; Spacer()
                    Button("Save Startup Area") { Task { await guide.startActiveBackup(ready: activeReady) } }
                        .disabled(!activeReady).keyboardShortcut(.defaultAction)
                }
            case .activeWorking:
                HStack { ProgressView().controlSize(.small); Text("Saving startup area…").font(.headline) }
                Text("Leave power and USB connected. The check can take several minutes; nothing is being installed.").foregroundStyle(.secondary)
            case .activeReturnToNormal:
                Label(guide.activeError == nil ? "Startup area saved" : "Startup backup needs attention", systemImage: guide.activeError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(guide.activeError == nil ? Color.green : Color.orange)
                if let error = guide.activeError { Text(error).textSelection(.enabled) }
                else { Text("The startup area was copied and checked on this Mac. No firmware was installed.") }
                Text("1. Turn the SNES off and unplug USB.\n2. Wait ten seconds, reconnect USB with RESET released, and turn it on.\n3. Check the normal menu and a built-in game.")
                HStack {
                    Button("Menu or Game Doesn't Work") { guide.reportNormalBootProblem() }; Spacer()
                    Button("Normal Menu and Game Work") { guide.confirmActiveNormalBoot() }.keyboardShortcut(.defaultAction)
                }
            case .activeComplete, .activeFailed:
                Label(guide.phase == .activeComplete ? "Startup area saved" : "Startup backup needs attention", systemImage: guide.phase == .activeComplete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(guide.phase == .activeComplete ? Color.green : Color.orange)
                if let error = guide.activeError { DisclosureGroup("Backup details") { Text(error).textSelection(.enabled) } }
                if let directory = guide.activeDirectory { Button("Show Startup Backup in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) } }
                if let directory = guide.activeDiagnosticDirectory { Button("Show Backup Diagnostic in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) } }
                if let directory = guide.freshDataDiagnosticDirectory { Button("Show Saved Backup in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) } }
                Text("First-time setup is a preview. Startup restore has limited preview support.")
                if guide.canReviewFreshDataBackup { Text("You can save an updated data backup after playing, without repeating the game test.").foregroundStyle(.secondary) }
                if guide.canPreparePlan { Text("You can also prepare a temporary review using the earlier backup. This does not connect to the console or install anything.").foregroundStyle(.secondary) }
                recoveryFileButtons
                HStack {
                    Button("Done") { finish() }; Spacer()
                    if guide.phase == .activeFailed { Button("Try Again") { guide.retryActiveBackup() }.keyboardShortcut(.defaultAction) }
                    if guide.canPreparePlan { Button("Review Earlier Backup") { Task { await guide.preparePlan() } } }
                    if guide.canReviewFreshDataBackup { Button("Save Updated Backup") { freshDataReady = false; guide.reviewFreshDataBackup() }.keyboardShortcut(.defaultAction) }
                }
            case .freshDataInstructions:
                Label("Save Updated Data Backup", systemImage: "externaldrive.badge.checkmark").font(.headline)
                Text("The app will save and check another copy of your SNES data on this Mac. Your earlier backup stays in place. No firmware is installed and you do not need to repeat the game test.")
                GroupBox("Get your SNES ready") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Turn the SNES OFF. Unplug USB from the console and wait 10 seconds.")
                        Text("2. Slide the power switch ON while USB is still unplugged.")
                        Text("3. Hold RESET and reconnect USB. Hold it for 5 seconds, then release it.")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("The power light and TV should stay dark. Keep only this SNES connected.").foregroundStyle(.secondary)
                Toggle("I released RESET and the light and screen are dark", isOn: $freshDataReady)
                HStack {
                    Button("Back") { freshDataReady = false; guide.cancelFreshDataBackup() }; Spacer()
                    Button("Save Updated Backup") { Task { await guide.startFreshDataBackup(ready: freshDataReady) } }
                        .disabled(!freshDataReady).keyboardShortcut(.defaultAction)
                }
            case .freshDataWorking:
                HStack { ProgressView().controlSize(.small); Text("Saving updated backup…").font(.headline) }
                Text(guide.dataDetail)
                Text("Leave power and USB connected. This can take several minutes; nothing is being installed.").foregroundStyle(.secondary)
            case .freshDataPowerOff:
                Label(guide.freshDataError == nil ? "Updated backup checked" : "Updated backup needs attention", systemImage: guide.freshDataError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(guide.freshDataError == nil ? Color.green : Color.orange)
                if let error = guide.freshDataError { Text(error).textSelection(.enabled) }
                else { Text("The updated backup was saved and checked on this Mac. No firmware was installed.") }
                Text("Turn the SNES OFF and unplug USB from the console. If the light stays on, unplugging USB will turn it off.")
                Text("You can start the console normally afterward. Starting it may change the data, so the app must check it again before any installation.").foregroundStyle(.secondary)
                HStack { Spacer(); Button("Console Is Off and USB Is Unplugged") { guide.confirmFreshDataPowerOff() }.keyboardShortcut(.defaultAction) }
            case .freshDataReturnToNormal:
                Label("Check Normal Startup", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("The updated backup did not finish its checks. Reconnect USB with RESET released, turn the SNES on normally, and check the game menu and a built-in game.")
                HStack {
                    Button("Menu or Game Doesn't Work") { guide.reportNormalBootProblem() }; Spacer()
                    Button("Normal Menu and Game Work") { guide.confirmFreshDataNormalBoot() }.keyboardShortcut(.defaultAction)
                }
            case .freshDataComplete, .freshDataFailed:
                Label(guide.phase == .freshDataComplete ? "Updated backup saved" : "Updated backup needs attention", systemImage: guide.phase == .freshDataComplete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(guide.phase == .freshDataComplete ? Color.green : Color.orange)
                if let error = guide.freshDataError { DisclosureGroup("Backup details") { Text(error).textSelection(.enabled) } }
                if let directory = guide.freshDataDirectory { Button("Show Updated Backup in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) } }
                if let directory = guide.freshDataDiagnosticDirectory { Button("Show Saved Backup in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) } }
                Text("Your earlier backup is still on this Mac. First-time setup is a preview.")
                if guide.phase == .freshDataComplete { Text("If you start the console again, you can save another updated backup without repeating the game test.").foregroundStyle(.secondary) }
                recoveryFileButtons
                HStack {
                    Button("Done") { finish() }; Spacer()
                    if guide.phase == .freshDataFailed { Button("Try Again") { freshDataReady = false; guide.retryFreshDataBackup() }.keyboardShortcut(.defaultAction) }
                    if guide.canReviewFreshDataBackup { Button("Save Another Backup") { freshDataReady = false; guide.reviewFreshDataBackup() } }
                    if guide.canPreparePlan { Button("Prepare Installation Review") { Task { await guide.preparePlan() } }.keyboardShortcut(.defaultAction) }
                }
            case .planWorking:
                HStack { ProgressView().controlSize(.small); Text("Preparing installation review…").font(.headline) }
                Text("The app is checking the saved records on this Mac. It is not connecting to the console or installing firmware.").foregroundStyle(.secondary)
            case .planComplete, .planFailed:
                Label(guide.phase == .planComplete ? "Installation review prepared" : "Review needs attention", systemImage: guide.phase == .planComplete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(guide.phase == .planComplete ? Color.green : Color.orange)
                if let plan = guide.firmwarePlan {
                    Text("The console’s startup software would need to be updated. No firmware has been installed.")
                    DisclosureGroup("Technical details") { Text("\(plan.changedUnits) startup-storage blocks would change.") }
                    Text(guide.freshDataDirectory == nil ? "This review uses the earlier backup. It does not check whether your current games and saves still match it; a fresh backup and console check will be needed before installation." : "This review uses the updated backup. It does not check whether your current games and saves still match it; the console must be checked again before installation.").foregroundStyle(.secondary)
                    Text("A fresh console check and separate approval are required for the first startup update.").foregroundStyle(.secondary)
                    if let saved = plan.savedReview {
                        Text("A draft review is saved on this Mac. You can check its files again from the setup guide; the console will need a fresh check before installation.").foregroundStyle(.secondary)
                        Button("Show Review in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved.directory]) }
                        if firstStageInstalled {
                            Text("The first startup update was checked. Continue with the menu and game-folder steps.").foregroundStyle(.secondary)
                        } else {
                            Button("Continue to Console Check") { initialSavedReview = saved; showingSavedReview = true }
                        }
                    } else {
                        Text("This review is temporary and closes with this window. The app will need to check the saved records again before installation.").foregroundStyle(.secondary)
                    }
                }
                if let error = guide.planError { DisclosureGroup("Review details") { Text(error).textSelection(.enabled) } }
                recoveryFileButtons
                HStack {
                    Button("Done") { finish() }; Spacer()
                    if guide.phase == .planFailed { Button("Try Again") { guide.retryPlan() }.keyboardShortcut(.defaultAction) }
                }
            case .normalBootNeedsHelp:
                Label("Console needs attention", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.orange)
                Text("The normal menu or game did not work. Keep the backup and any diagnostic files on this Mac. Do not repeat setup or install software until the problem is understood.")
                if let error = guide.errorMessage { DisclosureGroup("Backup check details") { Text(error).textSelection(.enabled) } }
                if let error = guide.startupError { DisclosureGroup("Startup check details") { Text(error).textSelection(.enabled) } }
                if let error = guide.menuSupportError { DisclosureGroup("Menu check details") { Text(error).textSelection(.enabled) } }
                if let error = guide.componentsError { DisclosureGroup("System check details") { Text(error).textSelection(.enabled) } }
                if let error = guide.dataError { DisclosureGroup("Data backup details") { Text(error).textSelection(.enabled) } }
                if let error = guide.runtimeError { DisclosureGroup("System library details") { Text(error).textSelection(.enabled) } }
                if let error = guide.preflightError { DisclosureGroup("Startup check details") { Text(error).textSelection(.enabled) } }
                if let error = guide.trialError { DisclosureGroup("Temporary startup details") { Text(error).textSelection(.enabled) } }
                if let error = guide.activeError { DisclosureGroup("Startup backup details") { Text(error).textSelection(.enabled) } }
                if let error = guide.freshDataError { DisclosureGroup("Updated backup details") { Text(error).textSelection(.enabled) } }
                if let directory = guide.activeDirectory { Button("Show Startup Backup in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) } }
                if let directory = guide.activeDiagnosticDirectory { Button("Show Backup Diagnostic in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) } }
                if let directory = guide.trialDiagnosticDirectory { Button("Show Test Diagnostic in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) } }
                if let directory = guide.startupDirectory {
                    Button("Show Startup Check in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                if let directory = guide.diagnosticDirectory {
                    Button("Show Backup Diagnostic in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                if let directory = guide.startupDiagnosticDirectory {
                    Button("Show Startup Diagnostic in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                if let directory = guide.menuSupportDirectory {
                    Button("Show Menu Files in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                if let directory = guide.menuSupportDiagnosticDirectory {
                    Button("Show Menu Diagnostic in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                if let directory = guide.componentsDirectory {
                    Button("Show System Files in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                if let directory = guide.componentsDiagnosticDirectory {
                    Button("Show System Diagnostic in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                if let directory = guide.dataDirectory {
                    Button("Show Data Backup in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                if let directory = guide.dataDiagnosticDirectory {
                    Button("Show Saved Backup in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                if let directory = guide.freshDataDirectory {
                    Button("Show Previous Updated Backup in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                if let directory = guide.freshDataDiagnosticDirectory {
                    Button("Show Updated Backup in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                if let directory = guide.runtimeDirectory {
                    Button("Show System Libraries in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                if let directory = guide.preflightDirectory {
                    Button("Show Startup File Check in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                recoveryFileButtons
                HStack { Spacer(); Button("Done") { finish() }.keyboardShortcut(.defaultAction) }
            }
        }
        .padding(24).frame(width: 560)
        .interactiveDismissDisabled()
        .sheet(isPresented: $showingResume) {
            SNESSetupResumeView(root: appState.snesBackupsDirectory, onResume: { result in
                try await guide.resume(result.evidence, unverifiedCount: result.unverifiedCount)
            }, onCancel: { guide.cancelResume() })
        }
        .sheet(isPresented: $showingSavedReview, onDismiss: { ready = false; initialSavedReview = nil }) {
            SNESReviewDraftView(initialReview: initialSavedReview, reportNormalBootProblem: { guide.reportNormalBootProblem() },
                                reportFirstStageComplete: { firstStageInstalled = true })
        }
        .sheet(isPresented: $showingRestorePreparation, onDismiss: { ready = false }) { SNESStartupRestorePreparationView() }
    }
    @ViewBuilder private var recoveryFileButtons: some View {
        if let directory = guide.backupDirectory {
            Button("Show Backup in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
        }
        if let directory = guide.recoveryDirectory {
            Button("Show Recovery Package in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
        }
        if let directory = guide.helpersDirectory {
            Button("Show Setup Helpers in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
        }
    }
    private func finish() {
        if guide.phase == .complete {
            appState.statusMessage = guide.recoveryError == nil && guide.helpersError == nil
                ? "SNES startup backup saved on this Mac."
                : "SNES startup backup saved. Additional setup files need attention."
        } else if guide.phase == .startupComplete {
            appState.statusMessage = "SNES startup check saved on this Mac."
        } else if guide.phase == .startupFailed {
            appState.statusMessage = "SNES startup check did not complete. The console is back in normal use."
        } else if guide.phase == .menuSupportComplete {
            appState.statusMessage = "SNES menu files saved on this Mac."
        } else if guide.phase == .menuSupportFailed {
            appState.statusMessage = "SNES menu check did not complete. The console is back in normal use."
        } else if guide.phase == .componentsComplete {
            appState.statusMessage = "SNES system files saved on this Mac."
        } else if guide.phase == .componentsFailed {
            appState.statusMessage = "SNES system check did not complete. The console is back in normal use."
        } else if guide.phase == .dataComplete {
            appState.statusMessage = "SNES console data backup saved on this Mac. Restore is not yet available."
        } else if guide.phase == .dataFailed {
            appState.statusMessage = "SNES data backup did not complete. The console is back in normal use."
        } else if guide.phase == .runtimeComplete {
            appState.statusMessage = "SNES system libraries saved on this Mac."
        } else if guide.phase == .runtimeFailed {
            appState.statusMessage = "SNES system library check did not complete. The console is back in normal use."
        } else if guide.phase == .candidateComplete {
            appState.statusMessage = firstStageInstalled ? "The first SNES startup update is checked. Continue with the menu and game-folder steps." : "SNES startup files prepared on this Mac. First-time setup is a preview."
        } else if guide.phase == .candidateFailed {
            appState.statusMessage = "SNES startup file preparation did not complete. No console software was installed."
        } else if guide.phase == .preflightComplete {
            appState.statusMessage = "SNES startup files were checked in memory. They have not been started or installed."
        } else if guide.phase == .preflightBackupChanged {
            appState.statusMessage = "SNES data changed since the backup. A fresh backup is needed before installation."
        } else if guide.phase == .preflightFailed {
            appState.statusMessage = "SNES startup file check did not complete. No firmware was installed."
        } else if guide.phase == .trialComplete {
            appState.statusMessage = "SNES temporary startup checked. No firmware was installed."
        } else if guide.phase == .trialFailed {
            appState.statusMessage = "SNES temporary startup did not complete. No firmware was installed."
        } else if guide.phase == .activeComplete {
            appState.statusMessage = "SNES startup area saved on this Mac. No firmware was installed."
        } else if guide.phase == .activeFailed {
            appState.statusMessage = "SNES startup backup did not complete. No firmware was installed."
        } else if guide.phase == .freshDataComplete {
            appState.statusMessage = "Updated SNES data backup saved on this Mac. No firmware was installed."
        } else if guide.phase == .freshDataFailed {
            appState.statusMessage = "Updated SNES data backup needs attention. No firmware was installed."
        } else if guide.phase == .planComplete {
            appState.statusMessage = "SNES installation review prepared on this Mac. No firmware was installed."
        } else if guide.phase == .planFailed {
            appState.statusMessage = "SNES installation review did not complete. No firmware was installed."
        } else if guide.phase == .normalBootNeedsHelp {
            appState.statusMessage = "SNES normal startup needs attention. Keep your saved backup and diagnostics."
        } else if guide.phase == .failed {
            appState.statusMessage = "SNES setup check did not complete. The console is back in normal use."
        }
        appState.isPreparingSync = false
        dismiss()
    }
}
