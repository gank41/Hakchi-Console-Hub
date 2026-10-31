import Foundation

/// Offline SFROM preparation for an ordinary US, ROM-only cartridge trial.
/// Does not change source files, select compatibility presets, or grant console access.
public struct SNESCanoeTrialImage: Sendable {
    public enum PreparationError: Error { case unsupportedROM }
    public let data: Data
    public let sourcePrefixBytes: Int
    public let isHiROM: Bool
    public var requiresHardwareTrial: Bool { true }

    public init(rom: Data) throws {
        // Bound before normalizing Data indices or allocating a second copy.
        guard (32768...4*1024*1024+512).contains(rom.count) else { throw PreparationError.unsupportedROM }
        let prefix = rom.count % 32768 == 512 ? 512 : 0
        let length = rom.count-prefix
        guard length <= 4*1024*1024, length.nonzeroBitCount == 1 else { throw PreparationError.unsupportedROM }
        let payload = Array(rom.dropFirst(prefix))
        func word(_ at: Int) -> Int { Int(payload[at]) | Int(payload[at+1]) << 8 }
        let candidates = [(0x7fc0, false), (0xffc0, true)].filter { header, hi in
            guard header+64 <= length else { return false }
            let map = payload[header+0x15], size = Int(payload[header+0x17])
            return (hi ? [0x21, 0x31] : [0x20, 0x30]).contains(Int(map)) &&
                payload[header+0x16] == 0 && payload[header+0x18] == 0 && payload[header+0x19] == 1 &&
                size <= 12 && 1 << (size+10) == length &&
                (word(header+0x1c) ^ word(header+0x1e)) == 0xffff &&
                (0x8000..<0xffff).contains(word(header+0x3c)) &&
                payload[header..<header+21].allSatisfy { (32...126).contains($0) }
        }
        guard candidates.count == 1, let selected = candidates.first,
              payload.reduce(0, { $0 + Int($1) }) & 0xffff == word(selected.0+0x1e) else {
            throw PreparationError.unsupportedROM
        }
        // Layout follows pinned CE SfromHeader1 / packed SfromHeader2; see the format audit.
        let footer = 48+length, total = length+96
        var output = [UInt8](repeating: 0, count: total)
        func set32(_ at: Int, _ value: Int) {
            for i in 0..<4 { output[at+i] = UInt8((value >> (8*i)) & 255) }
        }
        set32(0, 0x100); set32(4, total); set32(8, 48); set32(12, footer)
        set32(16, total); set32(20, footer); set32(24, total); set32(32, footer+27)
        output.replaceSubrange(36..<44, with: Array("WUP-XXXX".utf8))
        output.replaceSubrange(48..<footer, with: payload)
        output[footer] = 60; set32(footer+1, length)
        output[footer+15] = 2; output[footer+16] = 0x5a
        output[footer+17] = selected.1 ? 0x15 : 0x14
        set32(footer+27, 1); set32(footer+31, 1)
        data = Data(output); sourcePrefixBytes = prefix; isHiROM = selected.1
    }
}
