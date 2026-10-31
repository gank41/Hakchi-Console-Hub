import Foundation

/// Allocated storage measured on the console; no backup or deletion is performed.
struct LegacyStorageReport: Sendable {
    struct Entry: Identifiable, Sendable {
        let path: String
        let bytes: Int64
        var id: String { path }
        var isTemporary: Bool {
            path.hasPrefix("/var/lib/hakchi/games/nes.swift-")
                || path.hasPrefix("/var/lib/hakchi/.swift-hakchi-")
        }
        var label: String {
            if path == LegacyConsoleReport.gameRoot { return "Installed games" }
            if path == "/var/lib/clover/profiles/0" { return "Save data" }
            if path.contains("nes.swift-old-") { return "Previous menu " + String(path.suffix(36).prefix(8)) }
            if path.contains(".swift-hakchi-sync-") { return "Transfer files " + String(path.suffix(36).prefix(8)) }
            return URL(fileURLWithPath: path).lastPathComponent
        }
    }
    let freeBytes: Int64
    let entries: [Entry]
    var activeGameBytes: Int64 { entries.first { $0.path == LegacyConsoleReport.gameRoot }?.bytes ?? 0 }
    var temporaryBytes: Int64 { entries.filter(\.isTemporary).reduce(0) { $0 + $1.bytes } }

    static let command = #"""
    set -e
    export LC_ALL=C
    printf 'STORAGE_V1\n'
    df -Pk /var/lib | awk 'NR==2 {print "FREE_KIB=" $4}'
    for p in /var/lib/hakchi/games/* /var/lib/hakchi/.swift-hakchi-* /var/lib/clover/profiles/0; do
      [ -d "$p" ] && [ ! -L "$p" ] || continue
      du -sk "$p"
    done
    printf 'END_STORAGE\n'
    """#

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= 65536, let text = String(data: data, encoding: .utf8) else {
            throw LegacyInspectionError.invalidResponse
        }
        let lines = text.split(separator: "\n").map(String.init)
        guard lines.first == "STORAGE_V1", lines.last == "END_STORAGE", lines.count >= 3,
              lines[1].hasPrefix("FREE_KIB="),
              let free = Int64(lines[1].dropFirst(9)), free >= 0, free <= Int64.max / 1024 else {
            throw LegacyInspectionError.invalidResponse
        }
        var entries: [Entry] = [], seen = Set<String>()
        for line in lines.dropFirst(2).dropLast() {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count == 2, let kib = Int64(fields[0]), kib >= 0,
                  kib <= 1024 * 1024, seen.insert(fields[1]).inserted,
                  !fields[1].contains(".."), !fields[1].contains("\\"),
                  fields[1] == "/var/lib/clover/profiles/0"
                    || fields[1].range(of: #"^/var/lib/hakchi/(games/[A-Za-z0-9._-]+|\.swift-hakchi-[A-Za-z0-9._-]+)$"#,
                                        options: .regularExpression) != nil else {
                throw LegacyInspectionError.invalidResponse
            }
            entries.append(Entry(path: fields[1], bytes: kib * 1024))
        }
        return Self(freeBytes: free * 1024, entries: entries.sorted { $0.bytes > $1.bytes })
    }
}
