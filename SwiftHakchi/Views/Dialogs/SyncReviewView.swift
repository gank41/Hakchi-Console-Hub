import SwiftUI
import SwiftHakchiCore

struct SyncReviewView: View {
    let plan: SyncPlan
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review Console Changes").font(.title2.bold())
            Text("A verified backup will be saved before uploading. Your current library stays installed while the replacement is prepared.")
                .foregroundStyle(.secondary)
            HStack(spacing: 20) {
                Label("\(plan.pages.count) menu page(s)", systemImage: "folder")
                Text("Staging: " + ByteCountFormatter.string(fromByteCount: plan.requiredStagingBytes, countStyle: .file))
            }.font(.callout)
            Text("Maximum \(plan.maximumGamesPerPage) games per page; navigation entries are additional.")
                .font(.caption).foregroundStyle(.secondary)
            if plan.maximumGamesPerPage >= 50 {
                Text("This large page limit is not recommended and has not been hardware-tested.")
                    .font(.callout).foregroundStyle(.orange)
            }
            List {
                changes("Add", codes: plan.addedCodes)
                changes("Keep", codes: plan.keptCodes)
                changes("Remove from console", codes: plan.removedCodes)
                Section("Built-in games shown (\(plan.selectedGames.filter(\.isStock).count))") {
                    ForEach(plan.selectedGames.filter(\.isStock), id: \.code) { game in Text(game.name) }
                }
            }
            Text("Original ROM files and console saves are not removed by game synchronization.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Back Up and Sync", action: confirm).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(minWidth: 560, minHeight: 480)
    }
    private func changes(_ title: String, codes: Set<String>) -> some View {
        Section("\(title) (\(codes.count))") {
            if codes.isEmpty { Text("None").foregroundStyle(.secondary) }
            ForEach(codes.sorted(), id: \.self) { code in
                Text(plan.gameNames[code] ?? code)
            }
        }
    }
}
