import SwiftUI
import AppKit
import SwiftHakchiCore

struct SNESLibrarySyncView: View {
    var originalsOnly = false
    var restoreSnapshot: SNESLibrarySnapshotReference? = nil
    var replacementSnapshot: SNESLibrarySnapshotReference? = nil
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var model: SNESLibrarySyncModel?
    @State private var atMenu = false
    var body: some View {
        Group {
            if let model { content(model) }
            else { ProgressView("Opening the SNES review…").padding(40) }
        }
        .frame(minWidth: 780, idealWidth: 1000, maxWidth: 1100, minHeight: 600, idealHeight: 800, maxHeight: 950)
        .task {
            guard model == nil else { return }
            let value = SNESLibrarySyncModel(app: app, originalsOnly: originalsOnly, restoreSnapshot: restoreSnapshot, replacementSnapshot: replacementSnapshot); model = value; await value.start()
        }
        .interactiveDismissDisabled(model?.phase.isBusy == true)
        .onDisappear {
            guard let model else { return }
            Task { await model.close(); app.isPreparingSync = false }
        }
    }
    private func content(_ model: SNESLibrarySyncModel) -> some View {
        SNESLibrarySyncBody(model: model, atMenu: $atMenu, close: { dismiss() })
    }
}

private struct SNESLibrarySyncBody: View {
    @ObservedObject var model: SNESLibrarySyncModel
    @Binding var atMenu: Bool
    let close: () -> Void
    @State private var showStructure = false
    @State private var confirmDiscard = false
    @State private var confirmReturn = false
    @AppStorage("showAdvancedFeatures") private var showAdvancedFeatures = false
    @State private var showFolderOptions = false
    @State private var showGameList = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(model.isReturningPrevious ? "Recover Unfinished Sync — SNES Classic" : model.isRestoringReplacement ? "Copy Games to Replacement — SNES Classic" : model.isRestoringSavedGames ? "Restore Games and Folders — SNES Classic" : model.originalsOnly ? "Return to Built-in Games — SNES Classic" : "Sync Library — SNES Classic", systemImage: "arrow.triangle.2.circlepath").font(.title2.bold())
                Spacer()
                Picker("View", selection: $showAdvancedFeatures) {
                    Text("Easy").tag(false)
                    Text("Advanced").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 160)
                    .help("Easy shows the main steps. Advanced also shows folder and game details.")
                if model.phase.isTerminal {
                    Text(model.phase == .cancelled ? "Cancelled" : "Finished").foregroundStyle(.secondary)
                } else if !model.isReturningPrevious, let step = model.phase.syncStep {
                    Text("Step \(step) of 5").font(.headline).foregroundStyle(.secondary)
                }
            }
            if model.phase.isBusy {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text("Working…").font(.title2.bold()).foregroundStyle(.green)
                    }
                    Text(model.phase.progressTitle).font(.headline).multilineTextAlignment(.center)
                    if !model.phase.progressDetail.isEmpty {
                        Text(model.phase.progressDetail).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    Text("Keep the SNES turned on, connected by USB, and on its game-selection screen. Keep this window open.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(20)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            } else {
                if model.phase == .testing {
                    Label("Ready to finish", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
                } else if [.restart, .rollbackRestart, .deferredReady, .readyToFinish, .readyToDiscard, .readyToRollback].contains(model.phase) {
                    Label("Your turn", systemImage: "hand.raised.fill").font(.headline).foregroundStyle(.orange)
                } else if model.phase == .interrupted {
                    Label("Needs attention", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.red)
                } else if model.phase == .needsSetup {
                    Label("Needs attention", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
                }
                Text(model.message).fixedSize(horizontal: false, vertical: true)
            }
            capacity
            Divider()
            if model.phase.isBusy {
                Spacer(minLength: 20)
            } else if model.phase == .deferredReady {
                Text("Get ready to sync").font(.headline)
                Text("Leave the SNES turned on and connected to the Mac. On your TV, return to the first game screen and close any game or demo. Then select the checkbox and choose Continue Sync.")
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("The first game screen is visible and no game is running", isOn: $atMenu)
                Text("The app will make or reuse a recovery backup, then safely remove the previous sync’s old copy. This may take several minutes.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
            } else if model.phase == .readyToRollback {
                Text("Return to your previous game menu").font(.headline)
                Text("Games and saves stay on the console. After restarting normally, you can review removal of the unfinished copy. The previous library is saved in your Mac backup.").fixedSize(horizontal:false,vertical:true)
                Toggle("The game-selection menu is visible, with no game running",isOn:$atMenu)
                backupLink
                Spacer()
            } else if model.phase == .restart || model.phase == .rollbackRestart {
                restartInstructions
            } else if model.phase == .testing {
                Text("Leave the console on its game menu, then choose Finish Sync.")
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Also keep a current backup of my console games and saves", isOn: $model.createFinalBackup)
                Text(model.createFinalBackup
                     ? "The app will save a backup or use an existing matching backup. This can take several minutes. Once it is checked, the app will remove the previous console copy to free space. Your current games and saves stay."
                     : "No additional backup will be made now. The previous console copy stays until your next sync; the app will use the recovery backup made then to safely remove it. Your earlier Mac backup is kept.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
            } else if model.phase == .readyToFinish {
                Label("Your current library is saved on the Mac", systemImage: "checkmark.shield")
                Text("Old console copy to remove: " + bytes(model.reclaimBytes)).font(.headline)
                Text("The app kept the previous game menu temporarily. Finishing removes that older copy to free space. Your current games and saves remain, and a backup stays on this Mac. Returning immediately to the old menu will no longer be available.")
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
                if model.phase == .cancelled {
                    Label("Copy cancelled", systemImage: "stop.circle").font(.title).foregroundStyle(.secondary)
                } else {
                    Label("Sync complete", systemImage: "checkmark.circle.fill").font(.title).foregroundStyle(.green)
                }
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
            if phase == .deferredReady || phase == .readyToFinish || phase == .readyToDiscard || phase == .readyToRollback { atMenu = false }
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
        if model.phase == .deferredReady || model.phase == .readyToFinish || model.phase == .readyToDiscard || model.phase == .readyToRollback { return !atMenu }
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
                    Text("After old copies are removed: about " + bytes(max(0, projection.freeAfterFinishing)))
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
            Text("1. Leave this app open. On the SNES, slide the POWER switch to OFF and wait for the light to go out.\n\n2. Unplug the USB cable from the SNES for 10 seconds.\n\n3. Plug USB back in, then turn the SNES ON normally. Do not hold the RESET button.\n\n4. Wait until the list of games appears on your TV. Return here and choose the button below to continue.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Keep the HDMI cable connected so you can see the console’s game menu on your TV.").foregroundStyle(.secondary)
            Spacer()
        }
    }
    @ViewBuilder private var review: some View {
        if model.isRestoringSavedGames {
            if let graph = model.graph { ConsoleLayoutPreview(graph: graph).frame(maxHeight: 200) }
            Text(model.isRestoringReplacement ? "This copies \(model.selectedGameCount) added games, folders and artwork. Saved-game progress is not copied yet. The replacement's current games and saves are backed up before copying." : "This restores \(model.selectedGameCount) added games and their saved folders and artwork. Your current saves and settings are kept. The library you replace is backed up on the Mac before copying.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        } else if model.originalsOnly {
            if let graph = model.graph { ConsoleLayoutPreview(graph: graph).frame(maxHeight: 200) }
            Text("All \(model.originalGameCount) built-in games will appear on the first screen. Your saves and setup software stay. You can choose whether to back up and remove the previous console copy when finishing.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        } else if let draft = model.draft {
            if model.phase == .review {
                Text("Before you begin, leave the SNES on the list of games shown on your TV. If it starts games by itself, turn off My Game Play Demo and Classic Demo in the SNES Options menu.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("The app checks for a recovery backup before making changes and may create one if needed. A second backup after syncing is optional.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.compatibilityLayoutOnly {
                Text("Folder preview only. Additional emulator support is still being developed, so these games cannot be synced yet. You can keep them on your Mac and sync the other selected games.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if showAdvancedFeatures {
                folderOptions(draft)
            } else {
                Text("Your games will use the saved folder arrangement on your console.").foregroundStyle(.secondary)
                DisclosureGroup("Review or change console folders", isExpanded: $showFolderOptions) {
                    folderOptions(draft).padding(.top, 10)
                }
            }
            if model.phase == .ready {
                Text("Adds \(model.addedGames) • Removes \(model.removedGames) • \(model.totalGames) games in the console’s updated game menu")
                    .font(.callout).fontWeight(.medium)
            }
            if !draft.unresolvedDuplicateCodes.isEmpty {
                HStack {
                    Label("Choose which version to keep for matching games below.", systemImage: "exclamationmark.circle")
                    Spacer()
                    Button("Keep All Built-in Versions") { Task { await model.keepBuiltIns() } }.disabled(!model.phase.canEdit)
                }
            }
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
            if showAdvancedFeatures {
                gameList(draft)
            } else {
                if !draft.unresolvedDuplicateCodes.isEmpty {
                    gameList(draft, onlyUnresolved: true).frame(minHeight: 55, maxHeight: 140)
                }
                DisclosureGroup("Review selected Mac games (\(draft.review.rows.count))", isExpanded: $showGameList) {
                    gameList(draft).frame(minHeight: 120).padding(.top, 10)
                }
                Spacer(minLength: 0)
            }
            Text("Currently showing the games selected in your Mac library. Built-in games are included; if a game matches one of them, the built-in version stays on the console unless you choose your imported version.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            if let graph = model.graph { ConsoleLayoutPreview(graph: graph).frame(maxHeight: 220) }
            Text("Continue the saved sync using its reviewed games and folder layout.").foregroundStyle(.secondary)
            Spacer()
        }
    }
    @ViewBuilder private func folderOptions(_ draft: SNESLibraryReviewDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let graph = model.graph { ConsoleLayoutPreview(graph: graph).frame(maxHeight: 150) }
            HStack {
                Picker("Folder structure", selection: Binding(get: { draft.structure.mode }, set: { mode in Task { await model.setMode(mode) } })) {
                    ForEach(ConsoleStructure.Mode.allCases, id: \.self) { Text($0.displayTitle).tag($0) }
                }
                Picker("Games per page", selection: Binding(get: { draft.structure.maximumGamesPerPage }, set: { limit in Task { await model.setLimit(limit) } })) {
                    ForEach(ConsoleMenuLimit.allCases) { Text($0.menuTitle + ($0.rawValue > 35 ? " — not available yet" : "")).tag($0).disabled($0.rawValue > 35) }
                }.frame(maxWidth: 230)
            }
            HStack {
                Button("Edit Folder Structure…") { showStructure = true }
                Spacer()
                Picker("Sort games by", selection: Binding(get: { draft.order.reviewKey }, set: { key in
                    Task { await model.setOrder(key == "release-date" ? .releaseDate : key == "publisher" ? .publisher : .title) }
                })) {
                    Text("Title").tag("title"); Text("Release Date").tag("release-date"); Text("Publisher").tag("publisher")
                }.frame(maxWidth: 280)
            }
        }.disabled(!model.phase.canEdit)
    }
    private func gameList(_ draft: SNESLibraryReviewDraft, onlyUnresolved: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !onlyUnresolved {
                HStack {
                    Button("Select All") { Task { await model.selectAll(true) } }
                    Button("Select None") { Task { await model.selectAll(false) } }
                }.disabled(!model.phase.canEdit)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(draft.review.rows.filter { !onlyUnresolved || draft.unresolvedDuplicateCodes.contains($0.game.code) }, id: \.game.code) { row in
                        gameRow(row, draft: draft)
                        Divider()
                    }
                }
            }
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
