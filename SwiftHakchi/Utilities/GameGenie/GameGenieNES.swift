import Foundation

/// NES Game Genie bit permutation, verified against hakchi2 2.30 known answers.
enum GameGenieNES {
    private static let alphabet = Array("APZLGITYEOXUKSVN")
    static func decode(_ code: String) -> (address: UInt16, value: UInt8, compare: UInt8?)? {
        let letters = Array(code.uppercased())
        guard letters.count == 6 || letters.count == 8 else { return nil }
        var n: [UInt8] = []
        for letter in letters {
            guard let index = alphabet.firstIndex(of: letter) else { return nil }
            n.append(UInt8(index))
        }
        guard (n[2] & 8 != 0) == (n.count == 8) else { return nil }
        let a = UInt16(n[3] & 7) << 12 | UInt16(n[4] & 8) << 8 | UInt16(n[5] & 7) << 8
        let b = UInt16(n[1] & 8) << 4 | UInt16(n[2] & 7) << 4 | UInt16(n[3] & 8) | UInt16(n[4] & 7)
        let value = (n[0] & 8) << 4 | (n[1] & 7) << 4 | (n[0] & 7) | (n[n.count == 8 ? 7 : 5] & 8)
        let compare: UInt8? = n.count == 8 ? (n[6] & 8) << 4 | (n[7] & 7) << 4 | (n[6] & 7) | (n[5] & 8) : nil
        return (0x8000 | a | b, value, compare)
    }
    static func encode(address: UInt16, value: UInt8, compare: UInt8? = nil) -> String {
        let addr = address & 0x7FFF
        var n: [UInt8] = [
            ((value >> 4) & 8) | (value & 7),
            ((value >> 4) & 7) | UInt8((addr >> 4) & 8),
            UInt8((addr >> 4) & 7) | (compare == nil ? 0 : 8),
            UInt8(addr & 8) | UInt8((addr >> 12) & 7),
            UInt8((addr >> 8) & 8) | UInt8(addr & 7),
            ((compare ?? value) & 8) | UInt8((addr >> 8) & 7)
        ]
        if let compare {
            n.append(((compare >> 4) & 8) | (compare & 7))
            n.append((value & 8) | ((compare >> 4) & 7))
        }
        return String(n.map { alphabet[Int($0)] })
    }
}
