import SwiftUI
import AppKit

struct SNESLibrarySetupCompletionView: View {
    @StateObject private var flow: SNESLibrarySetupCompletionFlow
    @Binding private var busy: Bool
    @State private var ready = false

    init?(app: AppState, record: SNESReviewedInstallationRecord, stage: SNESMenuSetupStageContext,
          upgrade: SNESFirmwareJournal.Prepared, busy: Binding<Bool>) {
        guard let parent = stage.parent, let flow = try? SNESLibrarySetupCompletionFlow(stage: stage, upgrade: upgrade, capture: { update in
            try await app.captureSNESReviewedOriginalGames(update, after: record.check, menu: parent, ready: true)
        }) else { return nil }
        _flow = StateObject(wrappedValue: flow); _busy = busy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch flow.phase {
            case .ready:
                Text("The app needs to read the included game list before it can review your library. This does not change games or saves.")
                Toggle("The SNES is on its game-selection menu, with no game running", isOn: $ready).disabled(busy)
                Button("Check Included Games") {
                    guard !busy, ready else { return }; busy = true
                    Task { defer { busy = false }; await flow.capture(ready: true) }
                }.disabled(busy || !ready)
            case .checking:
                HStack { ProgressView().controlSize(.small); Text("Checking included games…") }
                Text("Keep power and USB connected.").foregroundStyle(.secondary)
            case .complete:
                Label("Included games checked", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Connect the SNES normally to review and sync supported games. Check the folder links and games after syncing.").foregroundStyle(.secondary)
                if let catalog = flow.catalog { Button("Show Saved Game List in Finder") { NSWorkspace.shared.activateFileViewerSelecting([catalog]) } }
            case .failed:
                Label("Included-game check stopped", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("The SNES was not changed. Keep its backups and check the details before continuing.")
                if let error = flow.error { DisclosureGroup("Details") { Text(error).textSelection(.enabled) } }
            }
        }
    }
}
