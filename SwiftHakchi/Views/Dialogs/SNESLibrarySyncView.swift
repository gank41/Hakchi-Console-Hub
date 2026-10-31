import SwiftUI
import AppKit
import SwiftHakchiCore

struct SNESLibrarySyncView: View {
    var originalsOnly = false
    var restoreSnapshot: SNESLibrarySnapshotReference? = nil
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var model: SNESLibrarySyncModel?
    @State private var tested = false
    @State private var atMenu = false
    var body: some View {
        Group {
            if let model { content(model) }
            else { ProgressView("Opening the SNES review…").padding(40) }
        }
        .frame(minWidth: 700, idealWidth: 800, maxWidth: 920, minHeight: 540, idealHeight: 680, maxHeight: 760)
        .task {
            guard model == nil else { return }
            let value = SNESLibrarySyncModel(app: app, originalsOnly: originalsOnly, restoreSnapshot: restoreSnapshot); model = value; await value.start()
        }
        .interactiveDismissDisabled(model?.phase.isBusy == true)
        .onDisappear {
            guard let model else { return }
            Task { await model.close(); app.isPreparingSync = false }
        }
    }
    private func content(_ model: SNESLibrarySyncModel) -> some View {
        SNESLibrarySyncBody(model: model, tested: $tested, atMenu: $atMenu, close: { dismiss() })
    }
}

private struct SNESLibrarySyncBody: View {
    @ObservedObject var model: SNESLibrarySyncModel
    @Binding var tested: Bool
    @Binding var atMenu: Bool
    let close: () -> Void
    @State private var showStructure = false
    @State private var confirmDiscard = false
    @State private var confirmReturn = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(model.isReturningPrevious ? "Recover Unfinished Sync — SNES Classic" : model.isRestoringSavedGames ? "Restore Games and Folders — SNES Classic" : model.originalsOnly ? "Return to Built-in Games — SNES Classic" : "Sync Library — SNES Classic", systemImage: "arrow.triangle.2.circlepath").font(.title2.bold())
                Spacer()
                Text(model.phase.isTerminal ? (model.phase == .cancelled ? "Cancelled" : "Finished") : model.isReturningPrevious ? "Review → Return → Remove unfinished copy" : "Review → Copy → Show → Finish").font(.callout).foregroundStyle(.secondary)
            }
            if model.phase.isBusy {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text(model.phase.progressTitle) }
                Text("Leave the console powered and connected at its game menu. First turn off My Game Play Demo and Classic Demo in the SNES Options menu.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text(model.message).fixedSize(horizontal: false, vertical: true)
            }
            capacity
            Divider()
            if model.phase == .readyToRollback {
                Text("Return to your previous game menu").font(.headline)
                Text("Games and saves stay on the console. After restarting normally, you can review removal of the unfinished copy. The previous library is saved in your Mac backup.").fixedSize(horizontal:false,vertical:true)
                Toggle("The game-selection menu is visible, with no game running",isOn:$atMenu)
                backupLink
                Spacer()
            } else if model.phase == .restart || model.phase == .rollbackRestart {
                restartInstructions
            } else if model.phase == .testing {
                Text(model.selectedGameCount == 0 ? "Check the original games and artwork. Start two built-in games and test picture, sound and controls, then return to the first game-selection screen." : "1. Check the folder links and box art.\n2. Start an added game as a new game and test picture, sound and controls.\n3. Test a built-in game too.\n4. Return to the first game-selection screen.")
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Both games and the menu work, and I am back at the first screen", isOn: $tested)
                Spacer()
            } else if model.phase == .readyToFinish {
                Label("Your tested library is saved on the Mac", systemImage: "checkmark.shield")
                Text("Temporary console files to remove: " + bytes(model.reclaimBytes)).font(.headline)
                Text("This ends immediate rollback on the console. You can restore the saved library from your Mac backup.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("The first game-selection screen is visible, with no game running", isOn: $atMenu)
                backupLink
                Spacer()
            } else if model.phase == .readyToDiscard {
                Text("Remove the unfinished copy").font(.headline)
                Text("This removes only temporary files for this sync (" + bytes(model.reclaimBytes) + "). Your currently playable games and saves stay on the console. You can start a new sync afterward.")
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("The game-selection menu is visible, with no game running", isOn: $atMenu)
                backupLink
                Spacer()
            } else if model.phase.isTerminal {
                Label(model.phase == .cancelled ? "Copy cancelled" : "Sync complete", systemImage: "checkmark.circle.fill").font(.title).foregroundStyle(.green)
                backupLink
                Spacer()
            } else {
                review
            }
            if let detail = model.detail {
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Divider()
            HStack {
                if model.phase.canEdit {
                    Button("Refresh Space") { Task { await model.refreshSpace() } }
                }
                if model.backupDirectory != nil { backupLink }
                Spacer()
                Button(model.phase.isTerminal ? "Close" : "Close for Now", action: close).disabled(model.phase.isBusy)
                if model.canReviewDiscard {
                    Button("Cancel This Copy…") { Task { await model.reviewDiscardCopy() } }
                }
                if model.canReviewPreviousGames {
                    Button("Return to Previous Games…") {Task {await model.reviewPreviousGames()}}
                }
                if model.canRetryOpening {
                    Button("Try Again") { Task { await model.retryOpening() } }.buttonStyle(.borderedProminent)
                }
                if model.canInspectInterruptedSync && !model.canReviewPreviousGames {
                    Button("Check Unfinished Sync") { Task { await model.inspectInterruptedSync() } }
                        .buttonStyle(.borderedProminent)
                }
                if model.phase.action != nil {
                    Button(model.phase.buttonTitle) {
                        if model.phase.isTerminal { close() }
                        else if model.phase == .readyToDiscard { confirmDiscard = true }
                        else if model.phase == .readyToRollback {confirmReturn=true}
                        else { Task { await model.perform() } }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(primaryDisabled)
                }
            }
        }.padding(22)
        .onChange(of: model.phase) { _, phase in
            if phase == .testing { tested = false }
            if phase == .readyToFinish || phase == .readyToDiscard || phase == .readyToRollback { atMenu = false }
        }
        .confirmationDialog("Return to your previous games?",isPresented:$confirmReturn,titleVisibility:.visible) {
            Button("Return to Previous Games") {Task {await model.perform()}}
            Button("Cancel",role:.cancel) {}
        } message: {
            Text("This changes which menu starts. Games and saves stay. After a normal restart, you can review removal of the unfinished copy.")
        }
        .confirmationDialog("Remove the unfinished copy?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Remove Unfinished Copy", role: .destructive) { Task { await model.perform() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Only this unfinished copy will be removed. The games and saves you currently use stay on the console. Its Mac backup is kept.")
        }
        .sheet(isPresented: $showStructure, onDismiss: { Task { await model.useSavedStructure() } }) {
            ConsoleStructureView(console: .snesUsa, games: model.previewGames, stockCodes: model.stockCodes, allowsSyncShortcut: false)
        }
    }
    private var primaryDisabled: Bool {
        if model.phase.isBusy { return true }
        if model.phase == .testing { return !tested }
        if model.phase == .readyToFinish || model.phase == .readyToDiscard || model.phase == .readyToRollback { return !atMenu }
        if model.phase == .review { return model.projection?.canFit != true || model.draft?.unresolvedDuplicateCodes.isEmpty != true }
        return false
    }
    private var capacity: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 18) {
                Text(model.isReturningPrevious ? "Games and saves are kept" : model.originalsOnly ? "Built-in games: \(model.originalGameCount)" : "Added games to sync: \(model.selectedGameCount)").fontWeight(.medium)
                if let free = model.freeBytes { Text("Console free: " + bytes(free)) }
                Spacer()
            }
            if !model.isReturningPrevious,let projection = model.projection {
                HStack(spacing: 18) {
                    Text("Needed to copy: " + bytes(projection.neededToCopy))
                        .foregroundStyle(projection.canFit ? Color.secondary : Color.orange)
                    Text("After finishing: about " + bytes(max(0, projection.freeAfterFinishing)))
                }
                Text("The final estimate does not yet count space cleared from the previous menu.").font(.caption).foregroundStyle(.secondary)
            }
        }.font(.callout).padding(10).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
    @ViewBuilder private var backupLink: some View {
        if let path = model.backupDirectory {
            Button("Show Mac Backup") { NSWorkspace.shared.activateFileViewerSelecting([path]) }
        }
    }
    private var restartInstructions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.phase == .rollbackRestart ? "Restart to show your previous games":"Restart to show your games").font(.headline)
            Text("1. Turn the SNES OFF and wait for its light to go out.\n2. Unplug USB from the console for ten seconds.\n3. Reconnect USB with RESET released, then turn it ON normally.\n4. Leave the game-selection menu visible.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Keep HDMI connected so you can check the menu. Do not hold RESET for this restart.").foregroundStyle(.secondary)
            Spacer()
        }
    }
    @ViewBuilder private var review: some View {
        if model.isRestoringSavedGames {
            if let graph = model.graph { ConsoleLayoutPreview(graph: graph).frame(maxHeight: 200) }
            Text("This restores \(model.selectedGameCount) added games and their saved folders and artwork. Your current saves and settings are kept. The library you replace is backed up on the Mac before copying.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        } else if model.originalsOnly {
            if let graph = model.graph { ConsoleLayoutPreview(graph: graph).frame(maxHeight: 200) }
            Text("All \(model.originalGameCount) built-in games will appear on the first screen. The setup software stays installed. Added games are removed only after you test and finish this change.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        } else if let draft = model.draft {
            if let graph = model.graph { ConsoleLayoutPreview(graph: graph).frame(maxHeight: 150) }
            if model.compatibilityLayoutOnly {
                Text("Folder preview only. Additional emulator support is still being developed, so these games cannot be synced yet. You can keep them on your Mac and sync the other selected games.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Picker("Folder structure", selection: Binding(get: { draft.structure.mode }, set: { mode in Task { await model.setMode(mode) } })) {
                    ForEach(ConsoleStructure.Mode.allCases, id: \.self) { Text($0.displayTitle).tag($0) }
                }
                Picker("Games per page", selection: Binding(get: { draft.structure.maximumGamesPerPage }, set: { limit in Task { await model.setLimit(limit) } })) {
                    ForEach(ConsoleMenuLimit.allCases) { Text($0.menuTitle + ($0.rawValue > 35 ? " — not available yet" : "")).tag($0).disabled($0.rawValue > 35) }
                }.frame(maxWidth: 230)
            }.disabled(!model.phase.canEdit)
            HStack {
                Button("Edit Folder Structure…") { showStructure = true }
                Spacer()
                Picker("Sort games by", selection: Binding(get: { draft.order.reviewKey }, set: { key in
                    Task { await model.setOrder(key == "release-date" ? .releaseDate : key == "publisher" ? .publisher : .title) }
                })) {
                    Text("Title").tag("title"); Text("Release Date").tag("release-date"); Text("Publisher").tag("publisher")
                }.frame(maxWidth: 280)
            }.disabled(!model.phase.canEdit)
            if model.phase == .ready {
                Text("Adds \(model.addedGames) • Removes \(model.removedGames) • \(model.totalGames) games in the updated menu")
                    .font(.callout).fontWeight(.medium)
            }
            HStack {
                Button("Select All") { Task { await model.selectAll(true) } }
                Button("Select None") { Task { await model.selectAll(false) } }
                if !draft.unresolvedDuplicateCodes.isEmpty {
                    Spacer(); Button("Keep All Built-in Versions") { Task { await model.keepBuiltIns() } }
                }
            }.disabled(!model.phase.canEdit)
            if !draft.excludedCodes.isEmpty {
                Toggle("Keep unsupported games on this Mac (\(draft.excludedCodes.count))", isOn: Binding(
                    get: { draft.allowSkippingUnavailable }, set: { skip in Task { await model.skipUnavailable(skip) } }))
                    .disabled(!model.phase.canEdit)
            }
            if !draft.excludedCodes.isEmpty {
                DisclosureGroup("Games kept on this Mac") {
                    ForEach(draft.review.rows.filter { draft.excludedCodes.contains($0.game.code) }, id: \.game.code) { row in
                        Text(row.game.name + ": " + (row.guidance ?? draft.unavailableReason(row.game.code) ?? "Add artwork and refresh the review."))
                            .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(draft.review.rows, id: \.game.code) { row in
                        gameRow(row, draft: draft)
                        Divider()
                    }
                }
            }
            Text("Showing games checked in your Mac library. Built-in games stay included; matches keep the built-in version unless you choose an imported version.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            if let graph = model.graph { ConsoleLayoutPreview(graph: graph).frame(maxHeight: 220) }
            Text("Continue the saved sync using its reviewed games and folder layout.").foregroundStyle(.secondary)
            Spacer()
        }
    }
    private func versionKey(_ row: SNESLibraryCompatibility.Row, draft: SNESLibraryReviewDraft) -> String {
        if let selected = draft.decisions[row.game.code] { return selected == .keepBuiltIn ? "builtin" : "import" }
        return row.needsDecision ? "choose" : "builtin"
    }
    @ViewBuilder private func gameRow(_ row: SNESLibraryCompatibility.Row, draft: SNESLibraryReviewDraft) -> some View {
        HStack(alignment: .top) {
            Toggle(row.game.name, isOn: Binding(get: { draft.selected.contains(row.game.code) },
                set: { selected in Task { await model.select(row.game.code, selected: selected) } }))
                .disabled(!model.phase.canEdit)
            Spacer()
            if !row.matches.isEmpty {
                Picker("Version", selection: Binding(get: { versionKey(row, draft: draft) }, set: { key in
                    let choice: SNESLibraryCompatibility.Resolution?
                    if key == "choose" { choice = nil } else if key == "builtin" { choice = .keepBuiltIn } else { choice = .keepImported }
                    Task { await model.decide(row.game.code, choice: choice) }
                })) {
                    if row.needsDecision { Text("Choose version").tag("choose") }
                    Text("Keep built-in").tag("builtin")
                    Text("Use imported").tag("import")
                }.labelsHidden().frame(width: 170).disabled(!model.phase.canEdit)
            } else if draft.unavailableCodes.contains(row.game.code) {
                Text(row.readiness == .ready ? "Artwork or details needed" : row.readiness.title).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 3)
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}
