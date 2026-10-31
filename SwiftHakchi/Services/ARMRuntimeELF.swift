import Foundation

/// Bounded ELF metadata inspection only; never executes or maps a supplied binary on the Mac.
struct ARMRuntimeELF: Sendable {
    let type: UInt16
    let interpreter: String?
    let dependencies: [String]
    static let maximumSize = 2 * 1024 * 1024
    init(data: Data, allowedRPath: String? = nil) throws {
        func fail() -> RecoveryProbeError { .refused("The SNES USB runtime uses an unsupported or damaged ARM executable.") }
        guard (52...Self.maximumSize).contains(data.count) else { throw fail() }
        let b = Array(data)
        func word(_ offset: Int, _ count: Int = 4) throws -> UInt32 {
            guard offset >= 0, count <= b.count - offset else { throw fail() }
            return (0..<count).reduce(UInt32(0)) { $0 | UInt32(b[offset+$1]) << (8*$1) }
        }
        guard b[0..<7].elementsEqual([127, 69, 76, 70, 1, 1, 1]), [0, 3].contains(b[7]),
              try word(18, 2) == 40, try word(20) == 1, try word(40, 2) == 52,
              try word(36) & 0xff000000 == 0x05000000,
              // Linux ARM EF_ARM_HASENTRY (0x2) is present in the pinned static utility.
              try word(36) & 0x00fff9fd == 0, try word(36) & 0x600 != 0x600,
              try word(42, 2) == 32 else { throw fail() }
        let type = try word(16, 2), count = Int(try word(44, 2)), start = Int(try word(28))
        guard [2, 3].contains(type), (1...128).contains(count), start >= 52,
              start <= b.count, count * 32 <= b.count - start else { throw fail() }
        struct Segment { let type: UInt32, offset: Int, address: UInt64, size: Int, memorySize: UInt64 }
        var segments: [Segment] = []
        for index in 0..<count {
            let at = start + index*32
            let offset = Int(try word(at+4)), address = UInt64(try word(at+8))
            let size = Int(try word(at+16)), memory = UInt64(try word(at+20)), alignment = try word(at+28)
            guard offset <= b.count, size <= b.count - offset, UInt64(size) <= memory,
                  address + memory <= UInt64(UInt32.max) + 1,
                  alignment == 0 || alignment & (alignment - 1) == 0 else { throw fail() }
            segments.append(Segment(type: try word(at), offset: offset, address: address, size: size, memorySize: memory))
        }
        let mapped = segments.filter { $0.type == 1 }
        guard !mapped.isEmpty else { throw fail() }
        for (index, load) in mapped.enumerated() where load.memorySize > 0 {
            for other in mapped.dropFirst(index + 1) where other.memorySize > 0 {
                guard load.address + load.memorySize <= other.address || other.address + other.memorySize <= load.address else { throw fail() }
            }
        }
        func string(_ offset: Int, limit: Int) throws -> String {
            guard offset >= 0, offset < limit, limit <= b.count,
                  let end = b[offset..<limit].firstIndex(of: 0), end - offset <= 256,
                  b[offset..<end].allSatisfy({ (33...126).contains($0) }) else { throw fail() }
            return String(decoding: b[offset..<end], as: UTF8.self)
        }
        let interpreters = segments.filter { $0.type == 3 }, dynamics = segments.filter { $0.type == 2 }
        guard interpreters.count <= 1, dynamics.count <= 1 else { throw fail() }
        let interpreter = try interpreters.first.map { s -> String in
            let value = try string(s.offset, limit: s.offset+s.size)
            guard value.utf8.count + 1 == s.size else { throw fail() }; return value
        }
        var dependencies: [String] = []
        if let dynamic = dynamics.first {
            guard dynamic.size >= 8, dynamic.size % 8 == 0, dynamic.size <= 65536 else { throw fail() }
            let owners = mapped.filter { dynamic.address >= $0.address && dynamic.address + UInt64(dynamic.size) <= $0.address + UInt64($0.size) }
            guard owners.count == 1,
                  owners[0].offset + Int(dynamic.address - owners[0].address) == dynamic.offset else { throw fail() }
            var tags: [(UInt32, UInt32)] = [], ended = false
            for offset in stride(from: dynamic.offset, to: dynamic.offset+dynamic.size, by: 8) {
                let tag = try word(offset), value = try word(offset+4)
                if tag == 0 { ended = true; break }; tags.append((tag, value))
            }
            guard ended else { throw fail() }
            // These tags alter dependency loading or search paths beyond the reviewed pair.
            let unsupported: Set<UInt32> = [29, 0x7fffffff, 0x7ffffffd, 0x6ffffefa, 0x6ffffefb, 0x6ffffefc]
            guard tags.allSatisfy({ !unsupported.contains($0.0) }) else { throw fail() }
            let tables = tags.filter { $0.0 == 5 }, sizes = tags.filter { $0.0 == 10 }
            guard tables.count == 1, sizes.count == 1, sizes[0].1 > 0, sizes[0].1 <= 1_048_576 else { throw fail() }
            let address = UInt64(tables[0].1), length = Int(sizes[0].1)
            let loads = segments.filter { $0.type == 1 && address >= $0.address && address + UInt64(length) <= $0.address + UInt64($0.size) }
            guard loads.count == 1 else { throw fail() }
            let base = loads[0].offset + Int(address - loads[0].address)
            let rpaths = tags.filter { $0.0 == 15 }
            guard rpaths.count <= 1 else { throw fail() }
            if let rpath = rpaths.first {
                guard let allowedRPath, rpath.1 < length,
                      try string(base + Int(rpath.1), limit: base + length) == allowedRPath else { throw fail() }
            }
            for (tag, value) in tags where tag == 1 {
                guard value < length else { throw fail() }
                let name = try string(base+Int(value), limit: base+length)
                guard !name.isEmpty, !name.contains("/"), !dependencies.contains(name), dependencies.count < 16 else { throw fail() }
                dependencies.append(name)
            }
        }
        self.type = UInt16(type); self.interpreter = interpreter; self.dependencies = dependencies
    }
}
