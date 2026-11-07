import SwiftUI

/// Inspects saved uncertain updates without issuing a firmware write.
struct SNESFirmwareRecoveryView: View {
    @StateObject private var flow: SNESFirmwareRecoveryFlow
    @Binding private var busy: Bool
    @State private var ready = false

    init?(app: AppState, check: SNESReviewedConsoleCheck, phase: SNESFirmwareJournal.Phase,
          upgrade: SNESReviewedUpgradeRecord? = nil, busy: Binding<Bool>) {
        guard let flow = try? SNESFirmwareRecoveryFlow(phase: phase, inspect: {
            try await app.inspectSNESUncertainInstallation(after: check, upgrade: upgrade, ready: true) { _ in }
        }) else { return nil }
        _flow = StateObject(wrappedValue: flow); _busy = busy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch flow.phase {
            case .ready:
                Text("Check the stopped update").font(.headline)
                Text("This read-only check compares the startup software with the saved update and backup. It does not repair or install anything.")
                Text("If an update may still be running, keep power connected and get help first. Once it has stopped, turn the SNES OFF, unplug USB for 10 seconds, slide power ON while unplugged, hold RESET while reconnecting USB, wait five seconds, then release RESET.")
                Toggle("The power light is off and the TV is blank", isOn: $ready).disabled(busy)
                Button("Inspect Stopped Update") {
                    guard !busy, ready else { return }; busy = true
                    Task { defer { busy = false }; await flow.inspect(ready: true) }
                }.disabled(busy || !ready)
            case .checking:
                HStack { ProgressView().controlSize(.small); Text("Inspecting the stopped update…") }
                Text("Keep power and USB connected.").foregroundStyle(.secondary)
            case .complete:
                if flow.result == .mixed {
                    Label("Startup needs attention", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    Label("Inspection complete", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                if let result = flow.result {
                    switch result {
                    case .preimage: Text("The checked startup area matches the earlier version.")
                    case .target: Text("The checked startup area matches the proposed update.")
                    case .mixed: Text("The checked startup area does not fully match either version.")
                    }
                }
                Text("This does not confirm normal startup or approve another update. Keep power and USB connected, preserve the backup and get help before making changes.").foregroundStyle(.secondary)
            case .failed:
                Label("Inspection stopped", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("The update could not be checked. Keep power and USB connected, preserve the backup and get help before making changes.")
                if let error = flow.error { DisclosureGroup("Details") { Text(error).textSelection(.enabled) } }
            }
        }
    }
}
