import Foundation
import Testing
@testable import SwiftHakchi

struct SNESNativeProcessSnapshotTests {
    @Test func acceptsBoundedProcessAndEventfdRecords() throws {
        let text = "SNES-PROCESS-V1\nPROC 42 1 clover-mcp\nFD 42 7 00000001 1 63\nPROC 71 42 canoe-shvc\nARG 71 wait 7\nEND\n"
        let snapshot = try SNESNativeProcessSnapshot.parse(Data(text.utf8))
        #expect(snapshot.processes.count == 2)
        #expect(snapshot.processes.first?.name == "clover-mcp")
        #expect(snapshot.processes.first?.eventFDs.first?.number == 7)
        #expect(snapshot.processes.last?.parent == 42)
        #expect(snapshot.processes.last?.transitions["wait"] == 7)
        #expect(snapshot.processes.first?.eventFDs.first?.id == 63)
    }
    @Test func capturesBoundedManagerOptionNames() throws {
        let text = "SNES-PROCESS-V1\nPROC 71 42 canoe-shvc\nOPT 71 save-on-quit\nOPT 71 save-screenshot-on-quit\nOPT 71 rollback-mode\nOPT 71 graphic-filter\nEND\n"
        let snapshot = try SNESNativeProcessSnapshot.parse(Data(text.utf8), allowAdditionalOptions: true)
        #expect(snapshot.processes[0].options == ["save-on-quit", "save-screenshot-on-quit", "rollback-mode", "graphic-filter"])
        for bad in ["private/path", "token=private", String(repeating: "a", count: 65), "save-on-quit\nOPT 71 save-on-quit"] {
            let input = "SNES-PROCESS-V1\nPROC 71 42 canoe-shvc\nOPT 71 " + bad + "\nEND\n"
            #expect(throws: (any Error).self) { try SNESNativeProcessSnapshot.parse(Data(input.utf8), allowAdditionalOptions: true) }
        }
        #expect(throws: (any Error).self) { try SNESNativeProcessSnapshot.parse(Data(text.utf8)) }
        #expect(SNESNativeProcessSnapshot.commandWithOptionNames.contains("if (!seen[$0]++)"))
        #expect(!SNESNativeProcessSnapshot.command.contains("if (!seen[$0]++)"))
        #expect(!SNESNativeProcessSnapshot.commandWithOptionNames.contains(";skip=1;next}"))
        #expect(SNESNativeProcessSnapshot.command.contains(";skip=1;next}"))
    }
    @Test func acceptsOlderKernelsWithoutEventfdCounters() throws {
        let text = "SNES-PROCESS-V1\nPROC 42 1 clover-mcp\nFD 42 9 - - -\nEND\n"
        let snapshot = try SNESNativeProcessSnapshot.parse(Data(text.utf8))
        #expect(snapshot.processes.first?.eventFDs.first?.count == "-")
        #expect(snapshot.processes.first?.eventFDs.first?.id == nil)
    }
    @Test func temporaryOwnerIsOnlyAcceptedForOptInCapture() throws {
        let text = "SNES-PROCESS-V1\nPROC 42 1 clover-mcp\nPROC 71 42 trial-owner\nPROC 72 71 retroarch\nPROC 73 42 trial-menu-owne\nEND\n"
        #expect(throws: (any Error).self) { try SNESNativeProcessSnapshot.parse(Data(text.utf8)) }
        let result = try SNESNativeProcessSnapshot.parse(Data(text.utf8), allowTemporaryTrial: true)
        #expect(result.processes.map(\.name) == ["clover-mcp", "trial-owner", "retroarch", "trial-menu-owne"])
        #expect(SNESNativeProcessSnapshot.commandForTemporaryTrial.contains("|trial-owner|"))
        #expect(SNESNativeProcessSnapshot.commandForTemporaryTrial.contains("|trial-menu-owne|"))
        #expect(SNESNativeProcessSnapshot.commandForTemporaryTrial.contains("B=/probe/busybox"))
        #expect(!SNESNativeProcessSnapshot.commandForTemporaryTrial.contains("if (!seen[$0]++)"))
        #expect(!SNESNativeProcessSnapshot.command.contains("|trial-owner|"))
    }
    @Test func optInFilterEmitsOptionShapesWithoutPathsOrAssignedValues() throws {
        let command = SNESNativeProcessSnapshot.commandWithOptionNames
        let begin = try #require(command.range(of: #"awk -v pid="$pid" '"#)?.upperBound)
        let end = try #require(command.range(of: "' || :", range: begin..<command.endIndex)?.lowerBound)
        let awk = String(command[begin..<end])
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/awk")
        process.arguments = ["-v", "pid=7", awk]
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data("--save-screenshot-on-quit\n--rollback-ui\n--sram-file\n/private/path\n--token=secret\n--wait-transition-fd\n11\n".utf8))
        try input.fileHandleForWriting.close()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let text = String(decoding: result, as: UTF8.self)
        #expect(text == "OPT 7 save-screenshot-on-quit\nOPT 7 rollback-ui\nOPT 7 sram-file\nARG 7 wait 11\n")
        #expect(!text.contains("private"))
        #expect(!text.contains("secret"))
    }
    @Test func rejectsIncompleteOrInconsistentCaptures() {
        for text in ["SNES-PROCESS-V1\nPROC 42 1 clover-mcp\n", "SNES-PROCESS-V1\nFD 99 7 00000001 1 63\nEND\n", "SNES-PROCESS-V1\nPROC 42 1 clover-mcp\nPROC 42 1 canoe-shvc\nEND\n", "SNES-PROCESS-V1\nPROC 42 1 unknown\nEND\n"] {
            #expect(throws: (any Error).self) { try SNESNativeProcessSnapshot.parse(Data(text.utf8)) }
        }
    }
}
