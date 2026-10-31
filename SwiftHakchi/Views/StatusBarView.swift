import SwiftUI

/// Bottom status bar showing connection state, console type, and game count
struct StatusBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            // Connection indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.caption)
            }

            Divider()
                .frame(height: 12)

            // Console type + hardware ID
            if appState.deviceManager.consoleType != .unknown {
                Text(appState.deviceManager.consoleType.displayName)
                    .font(.caption)

                if !appState.deviceManager.uniqueId.isEmpty {
                    Text(appState.deviceManager.uniqueId)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()
                    .frame(height: 12)
            }

            // Shared USB ID: legacy Clovershell and FEL both use 1f3a:efe8
            if appState.deviceManager.felDevicePresent && appState.deviceManager.legacyReport == nil {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("Legacy / FEL USB")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Divider()
                    .frame(height: 12)
            }

            // Background activity indicator
            if let stage = appState.deviceManager.connectionStage {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text(stage.title).font(.caption).foregroundStyle(.secondary)
                }
                Divider().frame(height: 12)
            } else if let message = appState.statusMessage {
                HStack(spacing: 4) {
                    if appState.gameManager.isLoading || appState.isPreparingSync || appState.taskRunner.isRunning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "info.circle").font(.caption)
                    }
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()
                    .frame(height: 12)
            }

            if let report = appState.deviceManager.legacyReport {
                let free = ByteCountFormatter.string(fromByteCount: report.freeBytes, countStyle: .binary)
                let projection = appState.legacyCapacityPreview
                Text("\(free) free now on NES")
                    .font(.caption).foregroundStyle(.secondary)
                if let projection, projection.freeBytes == report.freeBytes {
                    Divider().frame(height: 12)
                    Text(projection.headroomBytes >= 0
                         ? "≤\(ByteCountFormatter.string(fromByteCount: projection.headroomBytes, countStyle: .binary)) staging headroom"
                         : "Short \(ByteCountFormatter.string(fromByteCount: -projection.headroomBytes, countStyle: .binary)) for staging")
                        .font(.caption)
                        .foregroundStyle(projection.headroomBytes >= 0 ? Color.secondary : Color.orange)
                        .help("Estimate for the games checked in Sync Library. A temporary new menu and the current menu coexist; the exact preview checks storage again before transfer.")
                }
            }
            Spacer()

            // Game counts
            let allGames = appState.gameManager.games
            let stockGames = allGames.filter { $0.source == .stock }
            let selectedStock = stockGames.filter { $0.isSelected }.count
            let customCount = allGames.filter { $0.source != .stock }.count
            let selectedCustom = allGames.filter { $0.isSelected && $0.source != .stock }.count

            if appState.deviceManager.legacyReport != nil {
                Text("\(stockGames.filter(\.isOnConsole).count)/\(stockGames.count) built-in on NES")
                    .font(.caption).foregroundStyle(.secondary)
                Divider().frame(height: 12)
                Text("\(allGames.filter { $0.source != .stock && $0.isOnConsole }.count)/\(customCount) imported on NES")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if !stockGames.isEmpty {
                    Text("\(selectedStock)/\(stockGames.count) built-in")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()
                        .frame(height: 12)
                }

                Text("\(selectedCustom)/\(customCount) custom games selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var statusColor: Color {
        if appState.deviceManager.isConnected {
            return .green
        } else if appState.deviceManager.felDevicePresent {
            return .orange
        }
        return .red
    }

    private var statusText: String {
        if appState.deviceManager.legacyReport != nil { return "Connected — legacy Clovershell" }
        if appState.deviceManager.isConnected {
            let name = appState.deviceManager.consoleType.displayName
            return "Connected — \(name)"
        } else if appState.deviceManager.felDevicePresent {
            return "Legacy USB / FEL detected"
        }
        return "Disconnected"
    }
}
