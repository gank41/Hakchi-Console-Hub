import Foundation
import Testing
@testable import SwiftHakchi

struct DiagnosticLogExportTests {
    @Test func explainsWhenThereAreNoLogs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: DiagnosticLogExport.ExportError.self) {
            try DiagnosticLogExport.create(logs: root.appendingPathComponent("missing"), destination: root.appendingPathComponent("logs.zip"))
        }
    }
    @Test func exportsOnlyRegularAppLogs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent("Logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data("test connection".utf8).write(to: logs.appendingPathComponent("device.log"))
        try Data("{}".utf8).write(to: logs.appendingPathComponent("failure.jsonl"))
        try Data("not a log".utf8).write(to: logs.appendingPathComponent("private.dat"))
        try FileManager.default.createSymbolicLink(at: logs.appendingPathComponent("linked.log"), withDestinationURL: logs.appendingPathComponent("private.dat"))
        let zip = root.appendingPathComponent("logs.zip")
        try DiagnosticLogExport.create(logs: logs, destination: zip)
        let output = root.appendingPathComponent("unpacked")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, output.path]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let names = try Set(FileManager.default.contentsOfDirectory(atPath: output.path))
        #expect(names.contains("device.log") && names.contains("failure.jsonl"))
        #expect(!names.contains("linked.log") && !names.contains("private.dat"))
        #expect(try Data(contentsOf: output.appendingPathComponent("device.log")) == Data("test connection".utf8))
    }
    @Test func refusesOversizedLogWithoutReplacingAnExistingExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent("Logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data(count: 16 * 1024 * 1024 + 1).write(to: logs.appendingPathComponent("device.log"))
        let output = root.appendingPathComponent("logs.zip"), original = Data("existing file".utf8)
        try original.write(to: output)
        #expect(throws: (any Error).self) { try DiagnosticLogExport.create(logs: logs, destination: output) }
        #expect(try Data(contentsOf: output) == original)
    }
}
