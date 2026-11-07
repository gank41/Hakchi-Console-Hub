import SwiftUI

struct SNESSetupResumeView: View {
    let root: URL
    let onResume: @MainActor (SNESSetupResumeCatalog.Resolution) async throws -> Void
    let onCancel: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [SNESSetupResumeCatalog.Choice] = []
    @State private var selected: String?
    @State private var loading = true
    @State private var working = false
    @State private var resumeTask: Task<Void, Never>?
    @State private var didResume = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Resume SNES Setup").font(.title2.bold())
            Text("Choose the saved backup for this SNES. The app will check the saved files on this Mac before continuing.")
            if loading || working {
                HStack { ProgressView().controlSize(.small); Text(working ? "Checking saved files…" : "Finding saved backups…") }
                Text(working ? "The app may prepare files needed for setup on this Mac. The console will not be changed." : "The console will not be changed. This may take a few minutes.").foregroundStyle(.secondary)
            } else if choices.isEmpty {
                Text("No verified SNES setup backups were found.").foregroundStyle(.secondary)
            } else {
                List(choices, selection: $selected) { choice in
                    VStack(alignment: .leading) {
                        if let date = choice.savedDate { Text("Saved \(date.formatted(date: .abbreviated, time: .shortened))") }
                        else { Text("Saved SNES backup") }
                        Text("Console \(choice.consoleFingerprint) · Backup \(choice.id.suffix(8))").font(.caption).foregroundStyle(.secondary)
                    }.tag(choice.id)
                }.frame(height: 150)
            }
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button("Cancel") { resumeTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Resume Setup") {
                    guard let choice = choices.first(where: { $0.id == selected }) else { return }
                    working = true; error = nil
                    resumeTask = Task {
                        defer { resumeTask = nil }
                        do {
                            let result = try await AppState.runSNESRecoveryWorker {
                                try await SNESSetupResumeCatalog.resolve(root: root, backup: choice.backup, expectedManifest: choice.manifestSHA256)
                            }
                            try Task.checkCancellation()
                            try result.evidence.requireBackupManifest(choice.manifestSHA256)
                            try await onResume(result)
                            try Task.checkCancellation()
                            didResume = true
                            dismiss()
                        } catch {
                            if Task.isCancelled { return }
                            self.error = "The saved setup could not be verified. Your files were kept. \(error.localizedDescription)"
                            working = false
                        }
                    }
                }.disabled(loading || working || selected == nil).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 500)
        .onDisappear {
            resumeTask?.cancel()
            if !didResume { onCancel() }
        }
        .task {
            do {
                let found = try await AppState.runSNESRecoveryWorker { try SNESSetupResumeCatalog.list(root: root) }
                try Task.checkCancellation()
                choices = found
                selected = choices.count == 1 ? choices.first?.id : nil
            } catch {
                if Task.isCancelled { return }
                self.error = "Could not check saved backups. \(error.localizedDescription)"
            }
            loading = false
        }
    }
}
