import Foundation

/// Normalizes search input only; it does not change game names or choose a region.
enum GameTitleSearch {
    static func title(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: #"(?i)\s*\[(?:cheat codes?|game genie)\]\s*$"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)\s*\((?:usa|us|europe|japan|world|uk|australia|canada|france|germany|spain|italy)(?:\s*,\s*(?:usa|us|europe|japan|world|uk|australia|canada|france|germany|spain|italy))*\)\s*$"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i),\s*(?:the|a)\s*$"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)^\s*(?:the|a)\s+"#, with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ArtworkHTTPResponse: Sendable {
    let data: Data
    let status: Int
    let url: URL
}

enum ArtworkPlatform: String, Sendable, Codable {
    case nes, snes, genesis
    init?(console: ConsoleType) {
        if console.isNES { self = .nes }
        else if console.isSNES { self = .snes }
        else if console == .megaDrive { self = .genesis }
        else { return nil }
    }
    var system: String {
        switch self {
        case .nes: return "Nintendo - Nintendo Entertainment System"
        case .snes: return "Nintendo - Super Nintendo Entertainment System"
        case .genesis: return "Sega - Mega Drive - Genesis"
        }
    }
    var baseURL: URL {
        URL(string: "https://thumbnails.libretro.com")!.appendingPathComponent(system).appendingPathComponent("Named_Boxarts", isDirectory: true)
    }
}

struct ArtworkCandidate: Identifiable, Hashable, Sendable {
    let filename: String
    let platform: ArtworkPlatform
    var id: String { platform.rawValue + "/" + filename }
    var title: String { String(filename.dropLast(4)) }
    var url: URL { platform.baseURL.appendingPathComponent(filename) }
}

enum ArtworkError: LocalizedError {
    case invalidIndex, response(Int), invalidImage, tooLarge, staleTarget
    var errorDescription: String? {
        switch self {
        case .invalidIndex: return "The artwork catalog could not be read. Try again later or browse for an image on your Mac."
        case .response(let status): return "Artwork service returned HTTP \(status). Try again later or browse for a local image."
        case .invalidImage: return "Choose a valid PNG, JPEG or other supported still image."
        case .tooLarge: return "The image or catalog exceeds the download limit. Choose a smaller image."
        case .staleTarget: return "The game or library changed. Close this window and reopen artwork for the current local game."
        }
    }
}

/// Public per-platform index and explicit artwork download. No API key or ROM upload.
actor ArtworkCatalogService {
    static let shared = ArtworkCatalogService()
    typealias Fetch = @Sendable (URL) async throws -> ArtworkHTTPResponse
    private let fetch: Fetch
    private var catalogs: [ArtworkPlatform: [ArtworkCandidate]] = [:]

    init(fetch: @escaping Fetch = ArtworkCatalogService.fetchHTTP) { self.fetch = fetch }

    static func fetchHTTP(_ url: URL) async throws -> ArtworkHTTPResponse {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("SwiftHakchi/1.0 (local artwork lookup)", forHTTPHeaderField: "User-Agent")
        let (stream, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, let finalURL = http.url else { throw ArtworkError.invalidIndex }
        guard http.statusCode == 200 else { throw ArtworkError.response(http.statusCode) }
        guard response.expectedContentLength <= 8 * 1024 * 1024 else { throw ArtworkError.tooLarge }
        var data = Data()
        for try await byte in stream {
            if data.count >= 8 * 1024 * 1024 { throw ArtworkError.tooLarge }
            data.append(byte)
        }
        return ArtworkHTTPResponse(data: data, status: http.statusCode, url: finalURL)
    }

    private func checked(_ url: URL, platform: ArtworkPlatform) async throws -> Data {
        let response = try await fetch(url)
        try Task.checkCancellation()
        guard response.status == 200 else { throw ArtworkError.response(response.status) }
        guard response.url.scheme == "https", response.url.host == "thumbnails.libretro.com",
              response.url.path.hasPrefix(platform.baseURL.path), response.data.count <= 8 * 1024 * 1024 else {
            throw ArtworkError.invalidIndex
        }
        return response.data
    }

    func catalog(platform: ArtworkPlatform) async throws -> [ArtworkCandidate] {
        if let cached = catalogs[platform] { return cached }
        let data = try await checked(platform.baseURL, platform: platform)
        let parsed = try Self.parseIndex(data, platform: platform)
        catalogs[platform] = parsed
        return parsed
    }

    func search(query: String, platform: ArtworkPlatform) async throws -> [ArtworkCandidate] {
        let words = Self.normalized(GameTitleSearch.title(query)).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return try await catalog(platform: platform).filter { candidate in
            let title = Self.normalized(candidate.title)
            return words.allSatisfy { title.contains($0) }
        }.sorted { ($0.title.count, $0.title) < ($1.title.count, $1.title) }
    }

    func download(_ candidate: ArtworkCandidate) async throws -> Data {
        guard Self.validFilename(candidate.filename) else { throw ArtworkError.invalidIndex }
        return try GameArtworkStore.png(from: await checked(candidate.url, platform: candidate.platform))
    }

    static func parseIndex(_ data: Data, platform: ArtworkPlatform) throws -> [ArtworkCandidate] {
        guard data.count <= 8 * 1024 * 1024, let html = String(data: data, encoding: .utf8) else { throw ArtworkError.invalidIndex }
        let regex = try NSRegularExpression(pattern: #"href="([^"]+\.png)""#, options: .caseInsensitive)
        var names = Set<String>()
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html),
                  let name = String(html[range]).replacingOccurrences(of: "&amp;", with: "&").removingPercentEncoding,
                  validFilename(name) else { continue }
            names.insert(name)
        }
        guard !names.isEmpty else { throw ArtworkError.invalidIndex }
        return names.sorted().map { ArtworkCandidate(filename: $0, platform: platform) }
    }

    static func validFilename(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 512 && name.lowercased().hasSuffix(".png") &&
        !name.contains("/") && !name.contains("\\") && !name.contains(":") &&
        !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    static func normalized(_ title: String) -> String {
        var text = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        if text.hasSuffix(", the") { text = "the " + text.dropLast(5) }
        text = text.replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        return text.split(separator: " ").joined(separator: " ")
    }

    /// Automatic filling is deliberately stricter than manual candidate search.
    static func uniqueMatch(title: String, region: String?, candidates: [ArtworkCandidate]) -> ArtworkCandidate? {
        guard let region, !region.isEmpty else { return nil }
        let expected = normalized(title)
        let matches = candidates.filter { candidate in
            let label = candidate.title
            guard !label.contains("["), let open = label.lastIndex(of: "("), label.hasSuffix(")") else { return false }
            let name = String(label[..<open]).trimmingCharacters(in: .whitespaces)
            // Exactly one region group; archival filenames with dates/publishers are excluded.
            guard !name.contains("("), normalized(name) == expected else { return false }
            let regions = label[label.index(after: open)..<label.index(before: label.endIndex)].split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            return regions.contains(region)
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
