import Foundation

/// Injected console boundary; tests never open USB devices.
protocol ConsoleShell: Sendable {
    func execute(_ command: String, timeout: Int) async throws -> SSHResult
    func upload(data: Data, to remotePath: String, timeout: Int) async throws
    func uploadTar(data: Data, to directory: String, extraArgs: String, timeout: Int) async throws
}

extension ConsoleShell {
    func executeChecked(_ command: String, timeout: Int = 30_000) async throws -> SSHResult {
        try Task.checkCancellation()
        let result = try await execute(command, timeout: timeout)
        guard result.succeeded else {
            throw SSHError.commandFailed(command: command, exitCode: result.exitCode, stderr: result.stderr)
        }
        return result
    }
}
