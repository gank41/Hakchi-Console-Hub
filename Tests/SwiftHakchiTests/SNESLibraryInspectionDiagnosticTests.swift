import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESLibraryInspectionDiagnosticTests {
    @Test(arguments: [["--backup-native-snes-library"], ["--inspect-native-snes-library"], ["--inspect-native-snes-library", "relative", "/tmp"],
        ["--inspect-native-snes-library", "/tmp", "/tmp", "--copy"]])
    func malformedRequestNeverInspectsUSB(_ args: [String]) async throws {
        let events = SNESLibraryDiagnosticEvents()
        await #expect(throws: (any Error).self) {
            try await SNESLibraryInspectionDiagnostic.runIfPresent(args, checkHost: { await events.append("host") },
                inventory: { await events.append("usb"); return [] }, makeConnection: { _, _ in await events.append("open"); throw SNESLibraryInventory.failure() })
        }
        #expect(await events.values.isEmpty)
    }
    @Test func recoveryDescriptorCannotOpenTheNormalLibraryReader() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let events = SNESLibraryDiagnosticEvents()
        await #expect(throws: (any Error).self) {
            try await SNESLibraryInspectionDiagnostic.runIfPresent(["--inspect-native-snes-library", root.path, root.path],
                checkHost: { await events.append("host") }, inventory: { await events.append("usb"); return [probeFEL()] },
                makeConnection: { _, _ in await events.append("open"); throw SNESLibraryInventory.failure() })
        }
        #expect(await events.values == ["host", "usb"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
private actor SNESLibraryDiagnosticEvents {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
