import Foundation
import Testing
import USBBridge
@testable import SwiftHakchi
@testable import SwiftHakchiCore

actor FixedShell: ConsoleShell {
    var result: SSHResult
    init(exit: Int = 0, data: Data = Data("ok".utf8)) {
        result = SSHResult(stdout: String(data: data, encoding: .utf8) ?? "", stderr: "diagnostic", stdoutData: data, exitCode: exit)
    }
    func execute(_ command: String, timeout: Int) async throws -> SSHResult { result }
    func upload(data: Data, to remotePath: String, timeout: Int) async throws {}
    func uploadTar(data: Data, to directory: String, extraArgs: String, timeout: Int) async throws {}
}

struct ConsoleShellTests {
    @Test func failedRemoteCommandThrows() async {
        let shell = FixedShell(exit: 7)
        await #expect(throws: SSHError.self) { try await shell.executeChecked("mkdir /games") }
    }
    @Test func binaryResultPreservesZeros() async throws {
        let bytes = Data([0, 255, 1, 0, 2])
        let shell = FixedShell(data: bytes)
        #expect(try await shell.executeChecked("cat /backup").stdoutData == bytes)
    }
    @Test(arguments: [(100, 99, true, false), (100, 100, false, false), (100, 100, true, true)])
    func incompleteTransferCannotReportSuccess(sample: (UInt32, UInt32, Bool, Bool)) {
        #expect(ssh_transfer_completion(sample.0, sample.1, sample.2, sample.3) != 0)
    }
    @Test func completeTransferIsSuccessful() {
        #expect(ssh_transfer_completion(100, 100, true, false) == 0)
    }
    @Test func quotedPathDoesNotExpandShellContent() {
        #expect(LaunchCommand.shellQuote("/games/Bob's $(name)") == "'/games/Bob'\"'\"'s $(name)'")
    }
}
