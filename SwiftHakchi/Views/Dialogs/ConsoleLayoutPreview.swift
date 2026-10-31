import SwiftUI

/// A neutral picture of the actual planned screens, shared by layout and sync review.
struct ConsoleLayoutPreview: View {
    let graph: ConsoleMenuGraph

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How games will appear").font(.headline)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(graph.screens, id: \.number) { screen in
                        ConsoleScreenPreview(screen: screen)
                    }
                }
                .padding(.bottom, 4)
            }
            .frame(height: 184)
            Text("Each card is a screen on your console. Folder names show how to move between them.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ConsoleScreenPreview: View {
    let screen: ConsoleMenuGraph.Screen

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(screen.number == 0 ? "Main menu" : screen.title,
                  systemImage: screen.number == 0 ? "house.fill" : "folder.fill")
                .font(.callout.bold())
                .foregroundStyle(.tint)
                .lineLimit(1)
            Label("\(screen.gameCodes.count) games", systemImage: "gamecontroller")
                .font(.callout)
            ForEach(screen.links.prefix(3), id: \.target) { link in
                Label(link.title, systemImage: link.role == .back ? "arrow.uturn.backward" : "folder")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if screen.links.count > 3 {
                Text("+\(screen.links.count - 3) more…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 150, height: 144, alignment: .topLeading)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}
