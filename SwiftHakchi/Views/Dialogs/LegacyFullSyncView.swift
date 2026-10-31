import SwiftUI
import SwiftHakchiCore

/// Full-library entry point shares the already checked transfer and recovery stages
/// with the successful one-game trial while presenting a whole-library review.
struct LegacyFullSyncView: View {
    let workspace: WorkspacePaths
    let session: UUID

    var body: some View {
        LegacySyncTrialView(workspace: workspace, session: session, mode: .full)
    }
}
