import Foundation
import SwiftHakchiCore

struct LegacyConsoleReport: Codable, Equatable, Sendable {
    let bootVersion: String
    let kernelVersion: String
    let scriptVersion: String
    let activePage: String
    let freeBytes: Int64
    let savesPath: String
    let stockCodes: Set<String>
    let visibleCodes: Set<String>
    var canSync: Bool { false }
    var identityVerified: Bool { false }
    static let factoryRoot = "/var/squashfs/usr/share/games/nes/kachikachi"
    static let gameRoot = "/var/lib/hakchi/games/nes"

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= 65536, let text = String(data: data, encoding: .utf8) else { throw LegacyInspectionError.invalidReport }
        let markers = ["__VERSION__", "__ACTIVE__", "__CAPACITY__", "__SAVES__", "__FACTORY__", "__VISIBLE__", "__END__"]
        var sections: [String: [String]] = [:]
        var index = -1
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if markers.contains(line) {
                guard index + 1 < markers.count, markers[index + 1] == line else { throw LegacyInspectionError.invalidReport }
                index += 1; sections[line] = []
            } else if !line.isEmpty {
                guard index >= 0, index < markers.count - 1 else { throw LegacyInspectionError.invalidReport }
                sections[markers[index], default: []].append(line)
            }
        }
        guard index == markers.count - 1,
              let active = sections["__ACTIVE__"], active.count == 1,
              active[0].range(of: #"^/var/lib/hakchi/games/nes/[0-9]{3}$"#, options: .regularExpression) != nil,
              sections["__SAVES__"] == ["/var/lib/clover/profiles/0"],
              let capacity = sections["__CAPACITY__"]?.last else { throw LegacyInspectionError.invalidReport }
        let columns = capacity.split(whereSeparator: \.isWhitespace)
        guard columns.count >= 6, columns.last == "/var/lib", let blocks = Int64(columns[3]), blocks >= 0, blocks <= Int64.max / 1024 else { throw LegacyInspectionError.invalidReport }
        func version(_ key: String) throws -> String {
            let lines = (sections["__VERSION__"] ?? []).filter { $0.hasPrefix(key + "=") }
            guard lines.count == 1 else { throw LegacyInspectionError.invalidReport }
            let value = String(lines[0].dropFirst(key.count + 1))
            guard value.hasPrefix("'"), value.hasSuffix("'"), value.count > 2 else { throw LegacyInspectionError.invalidReport }
            return String(value.dropFirst().dropLast())
        }
        let stock = sections["__FACTORY__"] ?? []
        let visible = (sections["__VISIBLE__"] ?? []).filter { !$0.hasPrefix("CLV-S-") }
        guard !stock.isEmpty, stock.count <= 256, Set(stock).count == stock.count,
              stock.allSatisfy({ SyncPlanner.validCode($0) && !$0.hasPrefix("CLV-S-") }),
              visible.allSatisfy(SyncPlanner.validCode) else { throw LegacyInspectionError.invalidReport }
        return try Self(bootVersion: version("bootVersion"), kernelVersion: version("kernelVersion"), scriptVersion: version("hakchiVersion"), activePage: active[0], freeBytes: blocks * 1024, savesPath: "/var/lib/clover/profiles/0", stockCodes: Set(stock), visibleCodes: Set(visible))
    }
    func matchesLayout(of other: Self) -> Bool {
        bootVersion == other.bootVersion && kernelVersion == other.kernelVersion && scriptVersion == other.scriptVersion && stockCodes == other.stockCodes && savesPath == other.savesPath
    }
}
