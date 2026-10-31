import Foundation
import SwiftHakchiCore

/// Opaque startup evidence only; none of these records grants execution or write access.
struct SNESStartupFrame: Sendable {
    static let maximumSize = 12 * 1024 * 1024
    static let textDirectories = ["etc/init.d", "etc/modules-load.d", "etc/udev/rules.d"]
    static let textFiles = ["etc/clover/REGION", "etc/clover/boardtype", "etc/fstab", "etc/inittab", "etc/modules"]
    static let binaries = ["bin/busybox", "bin/sh", "sbin/init", "usr/bin/clover-canoe-shvc"]
    struct Record: Sendable {
        let kind: String, path: String, count: Int, digest: String
        let data: Data?
    }
    let raw: Data
    let records: [Record]
    static func failure() -> RecoveryProbeError {
        .refused("The SNES startup information was incomplete or did not pass its file checks. Nothing was installed.")
    }
    init(_ raw: Data) throws {
        guard raw.count <= Self.maximumSize else { throw Self.failure() }
        var cursor = 0
        func line() throws -> String {
            let limit = min(raw.count, cursor + 1152)
            guard cursor < limit, let end = raw[cursor..<limit].firstIndex(of: 10),
                  raw[cursor..<end].allSatisfy({ (32...126).contains($0) }),
                  let value = String(data: raw[cursor..<end], encoding: .ascii) else { throw Self.failure() }
            cursor = end + 1; return value
        }
        guard try line() == "SWIFTHAKCHI_SNES_STARTUP_V1", try line() == "TEXT_BEGIN" else { throw Self.failure() }
        var result: [Record] = [], seen: [String: String] = [:], moduleSection = false
        var previous = "", textCount = 0, textBytes = 0, moduleCount = 0, moduleBytes = 0
        while true {
            let header = try line()
            if header == "MODULES_BEGIN" {
                guard !moduleSection else { throw Self.failure() }
                moduleSection = true; previous = ""; continue
            }
            if header == "END" { guard moduleSection, cursor == raw.count else { throw Self.failure() }; break }
            let fields = header.components(separatedBy: " ")
            guard fields.count == 4, let count = Int(fields[2]), count >= 0, String(count) == fields[2] else { throw Self.failure() }
            let kind = fields[0], path = fields[1], digest = fields[3]
            guard Self.pathIsSafe(path), path > previous, seen[path] == nil else { throw Self.failure() }
            previous = path
            if moduleSection {
                moduleCount += 1
                guard moduleCount <= 2048, path == "lib/modules" || path.hasPrefix("lib/modules/"),
                      path.split(separator: "/").count <= 10, ["D", "M", "L", "A"].contains(kind),
                      kind != "A" || path == "lib/modules" else { throw Self.failure() }
                if path != "lib/modules" {
                    let parent = String(path[..<path.lastIndex(of: "/")!])
                    guard seen[parent] == "D" else { throw Self.failure() }
                } else { guard kind == "D" || kind == "A" else { throw Self.failure() } }
                if kind == "M" {
                    guard count <= 8*1024*1024, count <= 128*1024*1024 - moduleBytes else { throw Self.failure() }
                    moduleBytes += count
                }
            } else if Self.textDirectories.contains(path) {
                guard kind == "D" || kind == "A" else { throw Self.failure() }
            } else if Self.binaries.contains(path) {
                guard ["B", "L", "A"].contains(kind), count <= 32*1024*1024 else { throw Self.failure() }
            } else {
                let parent = path.contains("/") ? String(path[..<path.lastIndex(of: "/")!]) : ""
                guard Self.textFiles.contains(path) || (Self.textDirectories.contains(parent) && seen[parent] == "D"),
                      ["F", "L", "A"].contains(kind), kind != "A" || Self.textFiles.contains(path) else { throw Self.failure() }
                if kind == "F" || kind == "L" {
                    textCount += 1
                    guard textCount <= 128 else { throw Self.failure() }
                    if kind == "F" {
                        guard count <= 65536, count <= 8*1024*1024 - textBytes else { throw Self.failure() }
                        textBytes += count
                    }
                }
            }
            var content: Data?
            if kind == "A" || kind == "D" {
                guard count == 0, digest == "-" else { throw Self.failure() }
            } else {
                guard digest.count == 64, SNESRuntimeBinding.hex(digest) else { throw Self.failure() }
                if kind == "F" || kind == "L" {
                    guard kind != "L" || (count > 0 && count <= 512), count < raw.count - cursor else { throw Self.failure() }
                    let bytes = Data(raw[cursor..<cursor+count]); cursor += count
                    guard raw[cursor] == 10, BackupManifest.digest(bytes) == digest else { throw Self.failure() }; cursor += 1
                    if kind == "L" { guard bytes.allSatisfy({ (32...126).contains($0) }) else { throw Self.failure() } }
                    content = bytes
                }
            }
            seen[path] = kind; result.append(.init(kind: kind, path: path, count: count, digest: digest, data: content))
            guard result.count <= 2304 else { throw Self.failure() }
        }
        for path in Self.textFiles + Self.textDirectories + Self.binaries + ["lib/modules"] {
            guard seen[path] != nil else { throw Self.failure() }
        }
        for (path, value) in [("etc/clover/boardtype", "dp-shvc"), ("etc/clover/REGION", "USA")] {
            guard let item = result.first(where: { $0.path == path }), item.kind == "F", let bytes = item.data,
                  String(data: bytes, encoding: .ascii)?.trimmingCharacters(in: .newlines) == value else { throw Self.failure() }
        }
        for path in ["etc/inittab", "bin/busybox", "bin/sh", "sbin/init"] {
            guard seen[path] != "A", result.first(where: { $0.path == path })!.count > 0 else { throw Self.failure() }
        }
        self.raw = raw; records = result
    }
    static func pathIsSafe(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 512 else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [43, 45, 46, 95].contains($0)
            }
        }
    }
}
