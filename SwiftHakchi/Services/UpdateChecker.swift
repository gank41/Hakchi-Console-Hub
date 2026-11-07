import AppKit
import Foundation
import Combine

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let projectURL = URL(string: "https://github.com/gank41/Hakchi-Console-Hub")!
    static let downloadsURL = URL(string: "https://github.com/gank41/Hakchi-Console-Hub/releases")!
    private static let apiURL = URL(string: "https://api.github.com/repos/gank41/Hakchi-Console-Hub/releases?per_page=100")!
    @Published private(set) var checking = false
    @Published private(set) var message = "Check GitHub for the latest installer."

    struct Release: Decodable {
        struct Asset: Decodable { let name: String; let state: String }
        let tag_name: String
        let draft: Bool
        let assets: [Asset]
        var tag: String { tag_name }
        var version: [Int]? { Self.versionNumbers(tag_name) }
        static func versionNumbers(_ value: String) -> [Int]? {
            let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
            let number = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let parts = number.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...4).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
                  let result = Optional(parts.compactMap({ Int($0) })), result.count == parts.count else { return nil }
            return result + Array(repeating: 0, count: 4 - result.count)
        }
        func isNewer(than current: String) -> Bool? {
            guard let available = version, let installed = Self.versionNumbers(current) else { return nil }
            return installed.lexicographicallyPrecedes(available)
        }
    }

    nonisolated static func release(from data: Data) throws -> Release? {
        let releases = try JSONDecoder().decode([Release].self, from: data)
        return releases.filter { !$0.draft && $0.version != nil && $0.assets.contains { $0.state == "uploaded" && $0.name.lowercased().hasSuffix(".dmg") } }
            .max { $0.version!.lexicographicallyPrecedes($1.version!) }
    }

    func check() {
        guard !checking else { return }
        checking = true; message = "Checking GitHub for an installer…"
        Task {
            defer { checking = false }
            do {
                var request = URLRequest(url: Self.apiURL, timeoutInterval: 20)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2_000_000 else { throw URLError(.badServerResponse) }
                if let release = try Self.release(from: data) {
                    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
                    if release.isNewer(than: current) == true {
                        message = "An installer for \(release.tag) is available. This app is version \(current)."
                    } else {
                        message = "Latest installer: \(release.tag). This app is version \(current). Preview builds may differ."
                    }
                } else { message = "No downloadable installer was found. You can check the releases page." }
            } catch { message = "Couldn't check for updates. Check your internet connection or open the releases page." }
            let alert = NSAlert()
            alert.messageText = "Check for Updates"
            alert.informativeText = message + "\n\nOpen Downloads to review the installer on GitHub."
            alert.addButton(withTitle: "Open Downloads")
            alert.addButton(withTitle: "Close")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(Self.downloadsURL) }
        }
    }
}
