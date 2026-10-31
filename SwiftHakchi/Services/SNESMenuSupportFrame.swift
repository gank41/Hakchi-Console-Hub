import Foundation
import SwiftHakchiCore

/// Supplemental evidence only. This type never permits a boot or executes source text.
struct SNESMenuSupportFrame: Sendable {
    static let maximumSize = 4 * 1024 * 1024
    static let rules = "lib/udev/rules.d"
    static let textFiles = ["etc/asound.conf", "etc/clover/buildtype", "etc/clover/ui", "etc/group",
                            "etc/nsswitch.conf", "etc/passwd", "etc/udev/udev.conf", "usr/bin/clover-canoe-shvc"]
    static let executables = ["sbin/udevadm", "sbin/udevd", "usr/bin/clover-mcp", "usr/bin/udevadm"]
    let raw: Data
    let records: [SNESStartupFrame.Record]
    static func failure() -> RecoveryProbeError {
        .refused("The remaining SNES startup files did not pass their checks. Nothing was installed.")
    }
    init(_ raw: Data) throws {
        guard raw.count <= Self.maximumSize else { throw Self.failure() }
        var cursor = 0
        func line() throws -> String {
            let endLimit = min(raw.count, cursor + 1152)
            guard cursor < endLimit, let end = raw[cursor..<endLimit].firstIndex(of: 10),
                  raw[cursor..<end].allSatisfy({ (32...126).contains($0) }),
                  let text = String(data: raw[cursor..<end], encoding: .ascii) else { throw Self.failure() }
            cursor = end + 1; return text
        }
        guard try line() == "SWIFTHAKCHI_SNES_MENU_SUPPORT_V1", try line() == "TEXT_BEGIN" else { throw Self.failure() }
        var records: [SNESStartupFrame.Record] = [], seen: [String: String] = [:]
        var executableSection = false, previous = "", textCount = 0, textBytes = 0
        while true {
            let header = try line()
            if header == "EXECUTABLES_BEGIN" {
                guard !executableSection else { throw Self.failure() }
                executableSection = true; previous = ""; continue
            }
            if header == "END" { guard executableSection, cursor == raw.count else { throw Self.failure() }; break }
            let fields = header.components(separatedBy: " ")
            guard fields.count == 4, let count = Int(fields[2]), count >= 0, String(count) == fields[2] else { throw Self.failure() }
            let kind = fields[0], path = fields[1], digest = fields[3]
            guard SNESStartupFrame.pathIsSafe(path), path > previous, seen[path] == nil else { throw Self.failure() }
            previous = path
            if executableSection {
                guard Self.executables.contains(path), ["B", "L", "A"].contains(kind), count <= 32*1024*1024 else { throw Self.failure() }
            } else if path == Self.rules {
                guard ["D", "A"].contains(kind) else { throw Self.failure() }
            } else {
                let parent = path.contains("/") ? String(path[..<path.lastIndex(of: "/")!]) : ""
                guard Self.textFiles.contains(path) || (parent == Self.rules && seen[parent] == "D"),
                      ["F", "L", "A"].contains(kind), kind != "A" || Self.textFiles.contains(path) else { throw Self.failure() }
                if kind == "F" || kind == "L" {
                    textCount += 1; guard textCount <= 128 else { throw Self.failure() }
                    if kind == "F" {
                        guard count <= 65536, count <= 2*1024*1024 - textBytes else { throw Self.failure() }
                        textBytes += count
                    }
                }
            }
            var data: Data?
            if kind == "A" || kind == "D" {
                guard count == 0, digest == "-" else { throw Self.failure() }
            } else {
                guard digest.count == 64, SNESRuntimeBinding.hex(digest) else { throw Self.failure() }
                if kind == "F" || kind == "L" {
                    guard kind != "L" || (count > 0 && count <= 512), count < raw.count - cursor else { throw Self.failure() }
                    let content = Data(raw[cursor..<cursor+count]); cursor += count
                    guard raw[cursor] == 10, BackupManifest.digest(content) == digest else { throw Self.failure() }; cursor += 1
                    if kind == "L" { guard content.allSatisfy({ (32...126).contains($0) }) else { throw Self.failure() } }
                    data = content
                }
            }
            seen[path] = kind
            records.append(.init(kind: kind, path: path, count: count, digest: digest, data: data))
            guard records.count <= 133 else { throw Self.failure() }
        }
        for path in Self.textFiles + Self.executables + [Self.rules] { guard seen[path] != nil else { throw Self.failure() } }
        guard let launcher = records.first(where: { $0.path == "usr/bin/clover-canoe-shvc" }), launcher.kind == "F", launcher.count > 0 else { throw Self.failure() }
        self.raw = raw; self.records = records
    }
}
