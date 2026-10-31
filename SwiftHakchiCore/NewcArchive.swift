import Foundation

public struct NewcEntry: Equatable, Sendable {
    public var name: String
    /// Original 13 newc numeric fields, including Linux mode, ownership and inode metadata.
    public var fields: [UInt32]
    public var data: Data
    public init(name: String, fields: [UInt32], data: Data) { self.name = name; self.fields = fields; self.data = data }
}

/// Supports the audited initramfs types only. Links are values, never host filesystem operations.
public struct NewcArchive: Equatable, Sendable {
    public let entries: [NewcEntry]
    private static let maximum = LZOPArchive.maximumSize
    private static func failure() -> RecoveryImageError { .invalid("The startup archive contains damaged or unsupported file records.") }

    public init(data: Data) throws {
        guard data.count <= Self.maximum else { throw Self.failure() }
        var reader = BootByteReader(data), result: [NewcEntry] = []
        var sawTrailer = false
        while reader.position < reader.bytes.count {
            guard try reader.take(6) == Array("070701".utf8) else { throw Self.failure() }
            var fields: [UInt32] = []
            for _ in 0..<13 {
                let raw = try reader.take(8)
                guard raw.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                      let value = UInt32(String(decoding: raw, as: UTF8.self), radix: 16) else { throw Self.failure() }
                fields.append(value)
            }
            let nameSize = Int(fields[11]), size = Int(fields[6])
            guard (1...4097).contains(nameSize), size <= Self.maximum else { throw Self.failure() }
            let rawName = try reader.take(nameSize)
            guard rawName.last == 0, rawName.dropLast().allSatisfy({ (32...126).contains($0) }) else { throw Self.failure() }
            let name = String(decoding: rawName.dropLast(), as: UTF8.self)
            try Self.align(&reader)
            let contents = Data(try reader.take(size))
            try Self.align(&reader)
            guard fields[12] == 0 else { throw Self.failure() }
            if name == "TRAILER!!!" {
                guard size == 0, reader.bytes[reader.position...].allSatisfy({ $0 == 0 }) else { throw Self.failure() }
                sawTrailer = true; break
            }
            result.append(NewcEntry(name: name, fields: fields, data: contents))
            guard result.count <= 4096 else { throw Self.failure() }
        }
        guard sawTrailer else { throw Self.failure() }
        try self.init(entries: result)
    }

    public init(entries: [NewcEntry]) throws {
        guard entries.count <= 4096 else { throw Self.failure() }
        var paths: [String: UInt32] = [:], total = 0
        for entry in entries {
            guard entry.fields.count == 13 else { throw Self.failure() }
            let f = entry.fields, kind = f[1] & 0xf000
            let path = try Self.path(entry.name)
            guard paths[path] == nil, f[6] == entry.data.count, f[11] == entry.name.utf8.count + 1,
                  f[12] == 0, f[4] > 0, f[1] & ~UInt32(0xffff) == 0,
                  f[9] == 0, f[10] == 0, [UInt32(0x8000), 0x4000, 0xa000].contains(kind),
                  entry.data.count <= Self.maximum - total else { throw Self.failure() }
            total += entry.data.count
            if kind == 0x4000 {
                guard entry.data.isEmpty else { throw Self.failure() }
            } else {
                guard f[4] == 1, path != "." else { throw Self.failure() }
            }
            if kind == 0xa000 {
                guard (1...4096).contains(entry.data.count), entry.data.allSatisfy({ (32...126).contains($0) }) else { throw Self.failure() }
            }
            paths[path] = kind
        }
        for path in paths.keys where path != "." {
            let parts = path.split(separator: "/")
            for index in 1..<parts.count {
                let ancestor = parts.prefix(index).joined(separator: "/")
                if let kind = paths[ancestor], kind != 0x4000 { throw Self.failure() }
            }
        }
        self.entries = entries
    }

    /// Explicit regular-file edits only; additions carry explicit complete metadata.
    public func updating(replacements: [String: Data], additions: [NewcEntry] = []) throws -> Self {
        var updated = entries
        for (path, bytes) in replacements {
            guard let index = updated.firstIndex(where: { $0.name == path }),
                  updated[index].fields[1] & 0xf000 == 0x8000, bytes.count <= Self.maximum else { throw Self.failure() }
            updated[index].data = bytes; updated[index].fields[6] = UInt32(bytes.count)
        }
        updated.append(contentsOf: additions)
        _ = try Self(entries: updated)
        // Adding a directory changes its parent's link count; a file addition does not.
        for entry in additions where entry.fields.count == 13 && entry.fields[1] & 0xf000 == 0x4000 {
            let path = try Self.path(entry.name)
            let parts = path.split(separator: "/")
            let parent = parts.count > 1 ? parts.dropLast().joined(separator: "/") : "."
            if let index = updated.firstIndex(where: { (try? Self.path($0.name)) == parent }) {
                guard updated[index].fields[4] < UInt32.max else { throw Self.failure() }
                updated[index].fields[4] += 1
            }
        }
        return try Self(entries: updated)
    }

    public func encoded() throws -> Data {
        _ = try Self(entries: entries)
        let trailer = NewcEntry(name: "TRAILER!!!", fields: [0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 11, 0], data: Data())
        var output = Data()
        for entry in entries + [trailer] {
            let header = "070701" + entry.fields.map { String(format: "%08x", $0) }.joined()
            let name = Data(entry.name.utf8)
            guard header.utf8.count + name.count + entry.data.count + 7 <= Self.maximum - output.count else { throw Self.failure() }
            output.append(Data(header.utf8)); output.append(name); output.append(0)
            while output.count % 4 != 0 { output.append(0) }
            output.append(entry.data)
            while output.count % 4 != 0 { output.append(0) }
        }
        guard try Self(data: output).entries == entries else { throw Self.failure() }
        return output
    }
    private static func path(_ name: String) throws -> String {
        guard (1...4096).contains(name.utf8.count), name.utf8.allSatisfy({ (32...126).contains($0) }),
              name != "TRAILER!!!", name.first != "/" else { throw failure() }
        let path = name.hasPrefix("./") ? String(name.dropFirst(2)) : name
        if path == "." { return path }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw failure() }
        return path
    }
    private static func align(_ reader: inout BootByteReader) throws {
        let count = (4 - reader.position % 4) % 4
        guard try reader.take(count).allSatisfy({ $0 == 0 }) else { throw failure() }
    }
}
