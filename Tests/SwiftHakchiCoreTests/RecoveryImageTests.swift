import Foundation
import Testing
@testable import SwiftHakchiCore

func syntheticLegacyImage() -> Data {
    var data = Data(repeating: 0, count: 6144)
    data.replaceSubrange(0..<8, with: Data("ANDROID!".utf8))
    setBootField(&data, offset: 8, value: 100)
    setBootField(&data, offset: 16, value: 200)
    setBootField(&data, offset: 36, value: 2048)
    return data
}

func setBootField(_ data: inout Data, offset: Int, value: UInt32) {
    for i in 0..<4 { data[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
}

struct RecoveryImageTests {
    @Test func parsesExactSectionsAndNonzeroDataIndex() throws {
        let data = syntheticLegacyImage()
        let image = try LegacyAndroidBootImage(data: data)
        #expect(image.pageSize == 2048)
        #expect(image.kernelSize == 100 && image.ramdiskSize == 200)
        #expect(image.kernelRange == 2048..<2148)
        #expect(image.ramdiskRange == 4096..<4296)
        #expect(image.paddedSize == data.count)
        var prefixed = Data(repeating: 0xFF, count: 7); prefixed.append(data)
        #expect(try LegacyAndroidBootImage(data: prefixed.dropFirst(7)).paddedSize == data.count)
        #expect(KernelBackupStore.isRecognizedImage(data))
    }
    @Test(arguments: [UInt32(0), 512, 1024, 2049, 65536, UInt32.max])
    func refusesUnsupportedPages(page: UInt32) {
        var bytes = syntheticLegacyImage(); setBootField(&bytes, offset: 36, value: page)
        #expect(throws: (any Error).self) { try LegacyAndroidBootImage(data: bytes) }
    }
    @Test(arguments: [8, 16])
    func refusesEmptyRequiredSections(offset: Int) {
        var bytes = syntheticLegacyImage(); setBootField(&bytes, offset: offset, value: 0)
        #expect(throws: (any Error).self) { try LegacyAndroidBootImage(data: bytes) }
    }
    @Test(arguments: [24, 40, 44])
    func refusesSecondStageModernAndReservedHeaders(offset: Int) {
        var bytes = syntheticLegacyImage(); setBootField(&bytes, offset: offset, value: 1)
        #expect(throws: (any Error).self) { try LegacyAndroidBootImage(data: bytes) }
    }
    @Test func rejectsHostileLengthAndTruncatedOrAppendedBytes() {
        let good = syntheticLegacyImage()
        var oversizedSection = good; setBootField(&oversizedSection, offset: 8, value: .max)
        var missingMagic = good; missingMagic[0] = 0
        for bytes in [Data(good.prefix(100)), Data(good.dropLast()), good + Data([0]), oversizedSection, missingMagic, Data(repeating: 0, count: 16 * 1024 * 1024 + 1)] {
            #expect(throws: (any Error).self) { try LegacyAndroidBootImage(data: bytes) }
            #expect(!KernelBackupStore.isRecognizedImage(bytes))
        }
    }
    @Test func validCustomKernelIsNotRecognizedAsStock() throws {
        let data = syntheticLegacyImage()
        _ = try LegacyAndroidBootImage(data: data)
        #expect(throws: (any Error).self) { try StockKernelEvidence(data: data) }
    }
}
