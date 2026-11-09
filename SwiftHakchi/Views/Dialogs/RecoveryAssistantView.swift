import SwiftUI
import AppKit

struct RecoveryAssistantView: View {
    @ObservedObject var model: RecoveryAssistantModel
    let workspace: URL?
    @State private var mode = 0
    @State private var backups: URL?
    @State private var snapshot: URL?
    @State private var stock: URL?
    @State private var operation: URL?
    @State private var ready = false
    @State private var menuConfirmed = false
    @State private var detailsExpanded = false

    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Image(systemName:"cpu").font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment:.leading) {
                    Text(model.title).font(.title2.bold())
                    Text("NES Classic Mini • checked recovery").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy || model.demonstration { ProgressView().controlSize(.small) }
            }
            if model.demonstration {
                Label("Demonstration — no console access or changes",systemImage:"eye").font(.headline).foregroundStyle(.orange)
            }
            Text(model.status).font(.headline).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
            if model.busy { Text("Working… Leave console power and USB connected. This window will stay open until the operation stops.").font(.callout).foregroundStyle(.secondary) }
            if let started = model.startedAt {
                TimelineView(.periodic(from:.now,by:1)) { context in
                    Text("Elapsed: \(Int(max(0,(model.endedAt ?? context.date).timeIntervalSince(started)))) seconds")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    GroupBox("Keep recovery together") {
                        Text("Use this same Mac and macOS account until recovery is complete. The app does not check other accounts or Macs for unfinished operations, even when connected to the same console.")
                            .frame(maxWidth:.infinity,alignment:.leading)
                    }
                    if model.requiresPreservedPower {
                        GroupBox("Preserve the current state") {
                            Text("Keep the console powered and its USB cable connected. Preserve the operation folder. Do not retry or reboot; the stored write state needs inspection.")
                                .frame(maxWidth:.infinity,alignment:.leading)
                        }
                    }
                    if model.normalBootPending { normalBootInstructions }
                    if !model.busy && !model.normalBootPending && !model.requiresPreservedPower {
                        setupControls
                    }
                    if let review = model.review { reviewDetails(review) }
                    if let review = model.legacyReview { legacyReviewDetails(review) }
                    if let url = model.snapshotURL { fileLocation("Saved kernel snapshot",url:url) }
                    if let error = model.failure { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                    if !model.normalBootPending && !model.requiresPreservedPower { recoveryInstructions }
                }.padding(.trailing,8)
            }
            .disabled(model.busy || model.demonstration)
            DisclosureGroup("Activity details",isExpanded:$detailsExpanded) {
                ScrollView { Text(model.activity.details).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.frame(height:170)
            }
            HStack {
                Button("Copy Details") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.activity.details,forType:.string) }
                if let review = model.review { Button("Show Operation Folder") { NSWorkspace.shared.activateFileViewerSelecting([review.operationURL]) } }
                if let review = model.legacyReview { Button("Show Operation Folder") { NSWorkspace.shared.activateFileViewerSelecting([review.operationURL]) } }
                Spacer()
                Button(model.busy ? "Working…" : "Close") { NSApplication.shared.terminate(nil) }.disabled(model.busy)
            }
        }
        .padding(22).frame(minWidth:660,minHeight:700)
        .onChange(of:model.review) { _,_ in ready = false; menuConfirmed = false }
        .onChange(of:model.legacyReview) { _,_ in ready = false; menuConfirmed = false }
    }
    private var setupControls: some View {
        GroupBox("Choose an action") {
            VStack(alignment:.leading,spacing:10) {
                Picker("Action",selection:$mode) {
                    Text("Capture snapshot").tag(0)
                    Text("Prepare stock restore").tag(1)
                    Text("Open stock operation").tag(2)
                    Text("Prepare legacy connection").tag(3)
                    Text("Open legacy operation").tag(4)
                }.pickerStyle(.menu).onChange(of:mode) { _,_ in ready = false; model.clearWriteReview() }
                if mode == 0 {
                    pickerRow("Backups folder",url:backups) { backups = choose(directory:true,message:"Choose an existing folder for a new verified kernel snapshot") }
                    Button("Capture Kernel Snapshot") {
                        if let backups { start(.snapshot(backups)) }
                    }.disabled(backups == nil || !ready)
                    Button("Capture Install Evidence — Read Only") {
                        if let backups { start(.installEvidence(backups)) }
                    }.disabled(backups == nil || !ready)
                    Text("This reads boot1 and both kernel slots into a separate private snapshot. It does not install firmware, reset games or enable sync.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if mode == 1 {
                    pickerRow("Completed snapshot",url:snapshot) { snapshot = choose(directory:true,message:"Choose a completed Boot2Snapshot folder") }
                    pickerRow("Original stock image",url:stock) { stock = choose(directory:false,message:"Choose your original kernel-stock-NES.img; commercial kernels are not included") }
                    Text("Private operation folder: \(RecoveryFirmwareJournalPolicy.root.path)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Prepare and Review — Mac files only") {
                        if let snapshot, let stock { start(.prepare(snapshot:snapshot,stock:stock,journals:RecoveryFirmwareJournalPolicy.root)) }
                    }.disabled(snapshot == nil || stock == nil)
                } else if mode == 2 {
                    pickerRow("Operation folder",url:operation) { operation = choose(directory:true,message:"Choose an existing StockKernelRestore operation folder"); model.clearWriteReview() }
                    Button("Open Review — Mac files only") {
                        guard let operation else { return }
                        do { start(.inspect(try RecoveryAssistantReview.reference(at:operation))) }
                        catch { model.reportInputError(error) }
                    }.disabled(operation == nil)
                } else if mode == 3 {
                    pickerRow("Completed pre-restore snapshot",url:snapshot) { snapshot = choose(directory:true,message:"Choose the completed Boot2Snapshot of this NES's old custom kernel") }
                    pickerRow("Known stock image",url:stock) { stock = choose(directory:false,message:"Choose the original kernel-stock-NES.img for this NES") }
                    Text("Private operation folder: \(RecoveryFirmwareJournalPolicy.root.path)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Prepare Legacy Activation — Mac files only") {
                        if let snapshot, let stock { start(.legacyPrepare(snapshot:snapshot,stock:stock,journals:RecoveryFirmwareJournalPolicy.root)) }
                    }.disabled(snapshot == nil || stock == nil)
                    Text("This prepares the selected custom kernel. It does not write firmware or change games.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Choose only a startup backup captured from this console. The app cannot prove which console the backup came from.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    pickerRow("Legacy operation folder",url:operation) { operation = choose(directory:true,message:"Choose an existing LegacyBoot2Activation operation folder"); model.clearWriteReview() }
                    Button("Open Legacy Review — Mac files only") {
                        guard let operation else { return }
                        do { start(.legacyInspect(try LegacyRecoveryAssistantReview.reference(at:operation))) }
                        catch { model.reportInputError(error) }
                    }.disabled(operation == nil)
                }
                Text("Legacy activation, stock restore, game synchronization and a full factory reset are separate workflows. This assistant supports only the verified Western NES kernel paths.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(4)
        }
    }
    private var recoveryInstructions: some View {
        GroupBox("Before a console action") {
            VStack(alignment:.leading,spacing:8) {
                Text("1. Save edits and quit the main Swift Hakchi app. Disconnect any other app or virtual machine using this console over USB. Connect only the console being serviced.")
                Text("2. Leave USB in the same computer port. Connect HDMI and have a controller available.")
                Text("3. Switch NES OFF. Hold RESET, switch ON, wait five seconds, then release RESET.")
                Text("A dark power light and blank HDMI screen are expected in FEL recovery mode.").foregroundStyle(.secondary)
                Toggle("These steps are complete; the NES is in FEL and I can watch the monitor",isOn:$ready)
            }.font(.callout).frame(maxWidth:.infinity,alignment:.leading).padding(4)
        }
    }
    private var normalBootInstructions: some View {
        GroupBox(model.review?.phase == .readbackVerified || model.legacyReview?.phase == .readbackVerified ? "Verify the restored console" : "Return to the normal menu") {
            VStack(alignment:.leading,spacing:10) {
                Text("The recovery session has closed. Switch NES OFF, unplug USB for ten seconds, reconnect with RESET released, then switch ON. Select the NES HDMI input.")
                if model.review?.phase == .readbackVerified || model.legacyReview?.phase == .readbackVerified {
                    Text("Confirm the menu appears, then launch a built-in game and test controller input.")
                    Toggle("Menu appears; a built-in game launches and controls work",isOn:$menuConfirmed)
                } else { Toggle("The usual game-selection menu is visible",isOn:$menuConfirmed) }
                Button("Confirm Console Test") { Task { await model.confirmNormalBoot() }; menuConfirmed = false }.disabled(!menuConfirmed)
                Text("If the menu or game test fails, leave this result unconfirmed. Keep the operation folder for diagnosis; do not repeat the writer.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth:.infinity,alignment:.leading).padding(4)
        }
    }
    private func reviewDetails(_ review: RecoveryAssistantReview) -> some View {
        GroupBox("Reviewed stock-kernel operation") {
            VStack(alignment:.leading,spacing:9) {
                Text("State: \(review.phase.rawValue)").fontWeight(.medium)
                Text("Scope: active Western NES boot2 kernel only. Games, saves, partitions and full factory reset are separate.").font(.callout)
                Text("Stock: \(review.stockBytes) bytes\nSHA256: \(review.stockSHA256)\nPreserved preimage: \(review.preimageBytes) bytes\nSHA256: \(review.preimageSHA256)\nPlan SHA256: \(review.reviewSHA256)")
                    .font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                if model.canPreflight { Button("Run No-Flash Preflight") { start(.preflight(review)) }.disabled(!ready) }
                if model.writeEligible {
                    Toggle("I reviewed this image and scope; this action writes the stock kernel",isOn:Binding(
                        get: { model.reviewedWrite == review },
                        set: { model.acknowledgeWriteReview($0,for:review) }))
                    Button("Write Stock Kernel and Verify Readback") { start(.write(review)) }
                        .disabled(!ready || !model.canWrite).buttonStyle(.borderedProminent)
                }
            }.frame(maxWidth:.infinity,alignment:.leading).padding(4)
        }
    }
    private func legacyReviewDetails(_ review: LegacyRecoveryAssistantReview) -> some View {
        GroupBox("Reviewed legacy NES connection") {
            VStack(alignment:.leading,spacing:9) {
                Text("State: \(review.phase.rawValue)").fontWeight(.medium)
                Text("Scope: active boot2 on this Western NES only. Boot1, backup slot, games, saves and partitions are untouched.").font(.callout)
                Text("Current stock: \(review.stockBytes) bytes\nSHA256: \(review.stockSHA256)\nPreserved legacy: \(review.legacyBytes) bytes\nSHA256: \(review.legacySHA256)\nPlan SHA256: \(review.reviewSHA256)")
                    .font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                if model.canLegacyPreflight {
                    Button("Run No-Flash Legacy Preflight") { start(.legacyPreflight(review)) }.disabled(!ready)
                }
                if model.legacyWriteEligible {
                    Toggle("I reviewed this device and boot2-only scope; this action writes the preserved legacy kernel",isOn:Binding(
                        get: { model.reviewedLegacyWrite == review },
                        set: { model.acknowledgeLegacyWriteReview($0,for:review) }))
                    Button("Write Preserved Legacy Kernel and Verify Readback") { start(.legacyWrite(review)) }
                        .disabled(!ready || !model.canWriteLegacy).buttonStyle(.borderedProminent)
                }
            }.frame(maxWidth:.infinity,alignment:.leading).padding(4)
        }
    }
    private func pickerRow(_ title: String, url: URL?, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment:.leading) { Text(title).font(.caption); Text(url?.path ?? "Not selected").font(.callout).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
            Spacer(); Button("Choose…",action:action)
        }
    }
    private func fileLocation(_ title: String,url:URL) -> some View {
        GroupBox(title) { Text(url.path).font(.callout).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
    }
    private func choose(directory: Bool,message:String) -> URL? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = directory; panel.canChooseFiles = !directory
        panel.canCreateDirectories = directory; panel.allowsMultipleSelection = false; panel.message = message
        panel.directoryURL = workspace
        return panel.runModal() == .OK ? panel.url : nil
    }
    private func start(_ action: RecoveryAssistantAction) {
        let confirmed = ready; ready = false
        Task { await model.perform(action,ready:confirmed) }
    }
}
