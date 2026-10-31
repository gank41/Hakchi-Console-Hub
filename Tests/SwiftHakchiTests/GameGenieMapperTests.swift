import Foundation
import Testing
@testable import SwiftHakchi

extension GameGenieTests {
    @Test func contraSpreadCodeTouchesOnlyTheUxROMFixedBank() throws {
        // Mapper 2 maps the last 16 KiB at $C000-$FFFF. The old 8 KiB
        // scan also modified 15 unrelated locations in a 128 KiB game.
        var data = Data([78, 69, 83, 26, 8, 1, 0x24, 0] + Array(repeating: 0, count: 8))
        data.append(Data(repeating: 0xCC, count: 512)) // trainer
        data.append(Data(repeating: 0x55, count: 131072))
        data.append(Data(repeating: 0x66, count: 8192)) // CHR
        data.append(Data(repeating: 0x77, count: 128)) // footer
        let target = 16 + 512 + 0x1DAD2
        data.replaceSubrange((target - 1)...(target + 2), with: [0xA9, 0x00, 0x95, 0xAA])
        var expected = data; expected[target] = 3
        let result = try NESGameGeniePatcher.patch(data: data, codes: ["LEIIXZ"])
        #expect(result.offsets == [target])
        #expect(result.data == expected)
    }

    @Test func uxROMSwitchableWindowUsesSixteenKiBBanks() throws {
        var data = Data([78, 69, 83, 26, 8, 0, 0x20, 0] + Array(repeating: 0, count: 8))
        data.append(Data(repeating: 0xD0, count: 131072))
        // $A123 is offset $2123 within each switchable 16 KiB bank.
        // A repeated compare value must not authorize writing at $0123.
        let code = GameGenieNES.encode(address: 0xA123, value: 0x24, compare: 0xD0)
        let offsets = [0x2133, 0x6133, 0xA133, 0xE133, 0x12133, 0x16133, 0x1A133, 0x1E133]
        var expected = data
        for offset in offsets { expected[offset] = 0x24 }
        let result = try NESGameGeniePatcher.patch(data: data, codes: [code])
        #expect(result.offsets == offsets)
        #expect(result.data == expected)
    }

    @Test func uxROMFixedWindowCompareCannotMatchAnUnmappedBank() throws {
        var data = Data([78, 69, 83, 26, 8, 0, 0x20, 0] + Array(repeating: 0, count: 8))
        data.append(Data(repeating: 0xD0, count: 131072))
        data[0x1DAE2] = 0x00
        let code = GameGenieNES.encode(address: 0xDAD2, value: 3, compare: 0xD0)
        #expect(throws: GameGenieError.self) { try NESGameGeniePatcher.patch(data: data, codes: [code]) }
    }
}
