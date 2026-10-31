import Foundation
import Testing
@testable import SwiftHakchiCore

struct KernelBackupTests {
    @Test func recoveryImagesNeverReuseAnotherDeviceOrOlderDump() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repo.appendingPathComponent(".build/test-fixtures/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = syntheticLegacyImage()
        let one = ConsoleProfile(deviceID: "ONE", systemCode: "nes-usa")
        let two = ConsoleProfile(deviceID: "TWO", systemCode: "snes-usa")
        let first = try KernelBackupStore.save(data: bytes, profile: one, root: root)
        let second = try KernelBackupStore.save(data: bytes, profile: one, root: root)
        let third = try KernelBackupStore.save(data: bytes, profile: two, root: root)
        #expect(first != second)
        #expect(first.deletingLastPathComponent().deletingLastPathComponent() != third.deletingLastPathComponent().deletingLastPathComponent())
        #expect(try Data(contentsOf: first) == bytes)
        #expect(FileManager.default.fileExists(atPath: first.deletingLastPathComponent().appendingPathComponent("manifest.json").path))
    }
    @Test func randomDataIsNotCalledAValidKernel() {
        #expect(KernelBackupStore.isRecognizedImage(Data(repeating: 0x23, count: 70_000)) == false)
    }
}
