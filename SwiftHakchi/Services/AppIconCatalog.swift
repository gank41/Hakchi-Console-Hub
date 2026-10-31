import Foundation
import AppKit

/// App-owned choices only. A saved preference never becomes a filesystem path.
enum AppIconCatalog {
    struct Choice: Codable, Identifiable, Equatable, Sendable {
        let id: String
        let title: String
    }
    static let defaultID = "pow-block"
    static let choices: [Choice] = {
        guard let folder = Bundle.appBundle.url(forResource: "AppIcons", withExtension: nil),
              let data = try? Data(contentsOf: folder.appendingPathComponent("catalog.json")),
              let choices = try? decode(data) else {
            return [.init(id: defaultID, title: "POW Block")]
        }
        return choices
    }()
    static func decode(_ data: Data) throws -> [Choice] {
        guard data.count <= 65536 else { throw CocoaError(.fileReadCorruptFile) }
        let rows = try JSONDecoder().decode([Choice].self, from: data)
        guard (1...64).contains(rows.count), rows.contains(where: { $0.id == defaultID }),
              Set(rows.map(\.id)).count == rows.count,
              rows.allSatisfy({ $0.id.range(of: #"^[a-z0-9-]{1,80}$"#, options: .regularExpression) != nil &&
                  !$0.title.isEmpty && $0.title.utf8.count <= 160 && $0.title.rangeOfCharacter(from: .controlCharacters) == nil }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return rows
    }
    static func canonicalID(_ value: String?) -> String {
        choices.first(where: { $0.id == value })?.id ?? defaultID
    }
    static func imageURL(for id: String) -> URL? {
        guard let choice = choices.first(where: { $0.id == id }),
              let folder = Bundle.appBundle.url(forResource: "AppIcons", withExtension: nil) else { return nil }
        return folder.appendingPathComponent(choice.id + ".png")
    }
    @MainActor static func image(for id: String) -> NSImage? {
        imageURL(for: canonicalID(id)).flatMap(NSImage.init(contentsOf:))
    }
    @MainActor static func apply(_ id: String) {
        if let image = image(for: id) ?? Bundle.appBundle.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:)) {
            NSApplication.shared.applicationIconImage = image
        }
    }
}
