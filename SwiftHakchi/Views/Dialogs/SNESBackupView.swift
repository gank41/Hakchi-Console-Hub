import SwiftUI
import AppKit

struct SNESBackupView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var guide: SNESBackupGuide
    @State private var ready = false
    init(execute: @escaping @Sendable (@escaping RecoveryProgressSink) async throws -> URL) {
        _guide = StateObject(wrappedValue: SNESBackupGuide(execute: execute))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Prepare SNES Setup", systemImage: "externaldrive.badge.checkmark").font(.title2.bold())
            switch guide.phase {
            case .instructions:
                Text("Save the original SNES startup software and check its storage before setup. This does not install software or change games or saves.")
                Text("This first version supports the US SNES Classic. Keep only that console connected.").foregroundStyle(.secondary)
                Text("1. Turn the SNES off and unplug USB from the console.\n2. Wait ten seconds, then set its power switch ON while unplugged.\n3. Hold RESET and reconnect USB.\n4. Keep holding RESET for five seconds, then release it.\n\nThe power light and TV screen should stay dark.")
                Toggle("The SNES is in recovery mode and I am ready", isOn: $ready)
                HStack {
                    Button("Cancel") { finish() }
                    Spacer()
                    Button("Start Check") { Task { await guide.start(ready: ready) } }
                        .disabled(!ready).keyboardShortcut(.defaultAction)
                }
            case .working:
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(guide.stage == .readingBootloader ? "Saving the startup loader" : guide.stage.title)
                }
                Text("Leave power and USB connected. A blank TV screen is expected. This can take several minutes.").foregroundStyle(.secondary)
            case .returnToNormal:
                if guide.errorMessage == nil {
                    Text("The startup backup and storage checks were saved and verified on your Mac. The recovery connection is closed.")
                } else {
                    Text("The setup check did not complete. The recovery connection is closed.")
                    Text(guide.errorMessage ?? "").foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("1. Turn the SNES off and unplug USB from the console.\n2. Wait ten seconds.\n3. Reconnect USB with RESET released, then turn it on.\n4. Check that the normal menu appears and a built-in game plays.")
                if let directory = guide.diagnosticDirectory {
                    Button("Show Diagnostic in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                Button("Normal Menu and Game Work") { guide.confirmNormalBoot() }.keyboardShortcut(.defaultAction)
            case .complete, .failed:
                Text(guide.phase == .complete ? "SNES preparation complete. Your console is back in normal use." : "The console is back in normal use. No completed setup backup was saved.")
                if guide.phase == .complete { Text("Adding games to a stock SNES needs an installer that is still being developed.").foregroundStyle(.secondary) }
                if let directory = guide.backupDirectory {
                    Button("Show Backup in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                if let directory = guide.diagnosticDirectory {
                    Button("Show Diagnostic in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                }
                HStack { Spacer(); Button("Done") { finish() }.keyboardShortcut(.defaultAction) }
            }
        }
        .padding(24).frame(width: 560)
        .interactiveDismissDisabled()
    }
    private func finish() {
        if guide.phase == .complete {
            appState.statusMessage = "SNES preparation complete. The checked backup is saved on this Mac."
        } else if guide.phase == .failed {
            appState.statusMessage = "SNES setup check did not complete. The console is back in normal use."
        }
        appState.isPreparingSync = false
        dismiss()
    }
}
