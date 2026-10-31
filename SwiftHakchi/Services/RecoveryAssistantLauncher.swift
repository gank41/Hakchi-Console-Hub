import Foundation
import AppKit

enum RecoveryAssistantLauncher {
    @MainActor static func open(workspace: URL) async throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NES Recovery Assistant.app")
        guard FileManager.default.fileExists(atPath:helper.appendingPathComponent("Contents/MacOS/SwiftHakchiRecoveryAssistant").path) else {
            throw RecoveryProbeError.refused("This build does not contain the Recovery Assistant. Open the latest packaged app built with scripts/build-app.sh. Save edits and quit the main app before starting recovery.")
        }
        let config = NSWorkspace.OpenConfiguration(); config.arguments = ["--workspace",workspace.path]
        _ = try await NSWorkspace.shared.openApplication(at:helper,configuration:config)
    }
}
