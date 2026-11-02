import SwiftUI
import AppKit

struct TaskProgressSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    var body: some View { TaskProgressContent(runner:appState.taskRunner, close:{ dismiss() }) }
}
struct TaskProgressContent: View {
    @ObservedObject var runner: TaskRunner
    let close: () -> Void
    @State private var detailsExpanded = false
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(runner.operationName).font(.title2.bold())
            if runner.displayState == .working || runner.displayState == .stopping {
                HStack(alignment:.center,spacing:8) {
                    ProgressView().controlSize(.small)
                    Text(runner.displayState == .stopping ? "Stopping…" : "Working…").font(.headline)
                }
                Text(runner.currentTask).fixedSize(horizontal:false,vertical:true)
                if runner.hasMeasuredProgress {
                    ProgressView(value:runner.progress)
                    Text(runner.progress,format:.percent.precision(.fractionLength(0))).font(.caption).foregroundStyle(.secondary)
                }
                Text(runner.cancelRequested ? "Waiting for the operation to stop. Leave any connected console powered and plugged in." : "Keep this window open while the operation is working. If a console is connected, leave it powered and plugged in.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if runner.displayState == .cancelled {
                Label("Cancelled",systemImage:"stop.circle").font(.headline)
                Text("The operation stopped. Review the details before trying again.")
            } else if let error = runner.error {
                Label("Needs attention",systemImage:"exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
                Text(OperationActivity.safe(error.localizedDescription)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
            } else if runner.displayState == .completed {
                Label("Complete",systemImage:"checkmark.circle.fill").font(.headline).foregroundStyle(.green)
                Text(runner.currentTask).foregroundStyle(.secondary).textSelection(.enabled)
                Text("You can close this window to return to your library.").font(.callout)
            } else {
                Text("Getting ready…").foregroundStyle(.secondary)
            }
            if let start = runner.startedAt {
                TimelineView(.periodic(from:.now,by:1)) { context in
                    Text("Elapsed: \(Int(max(0,(runner.endedAt ?? context.date).timeIntervalSince(start)))) seconds")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Activity details",isExpanded:$detailsExpanded) {
                ScrollView { Text(runner.activity.details).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
                    .frame(height:180)
            }
            HStack {
                Button("Copy Details") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(runner.activity.details,forType:.string) }
                Spacer()
                if runner.isRunning {
                    if runner.canCancel { Button("Cancel") { runner.cancel() } }
                } else { Button("Done",action:close).keyboardShortcut(.defaultAction) }
            }
        }.padding(24).frame(width:540).interactiveDismissDisabled(runner.isRunning)
    }
}
