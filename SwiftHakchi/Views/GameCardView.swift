import SwiftUI

/// Bounded cover and persistent title; artwork is never required to identify a game.
struct GameCardView: View {
    let game: Game
    let isActive: Bool
    let isOnBar: Bool
    var cardSize: CGFloat = 130

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                if let cover = game.coverImage {
                    Image(nsImage: cover).resizable().scaledToFit().padding(3)
                } else {
                    Image(systemName: game.isStock ? "star.fill" : "gamecontroller.fill")
                        .font(.title2).foregroundStyle(.secondary)
                }
            }.frame(width: cardSize, height: cardSize * 1.3)
            Text(game.name).font(.callout.weight(.medium)).lineLimit(2)
                .frame(width: cardSize, height: 34, alignment: .topLeading)
            Label(isOnBar ? "Selected" : "Not selected", systemImage: isOnBar ? "checkmark.circle.fill" : "circle")
                .font(.caption2).foregroundStyle(isOnBar ? Color.accentColor : .secondary)
        }
        .padding(6)
        .background(isActive ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(isActive ? Color.accentColor : .clear, lineWidth: 2) }
        .contentShape(Rectangle()).help(game.name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(game.name), \(isOnBar ? "selected" : "not selected")")
    }
}
