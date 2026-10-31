import Foundation
import Testing
@testable import SwiftHakchi
@testable import SwiftHakchiCore

private final class UploadProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(Int64, Int64)] = []
    func append(_ sent: Int64, _ total: Int64) {
        lock.lock(); defer { lock.unlock() }
        samples.append((sent, total))
    }
    func snapshot() -> [(Int64, Int64)] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }
}

struct LegacyStageTransferTests {
    @Test func streamsArchiveInBoundedFramesAndChecksExactBytes() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("menu.tar")
        let bytes = Data((0..<4097).map { UInt8($0 % 251) })
        try bytes.write(to: archive)
        let usb = LegacyFakeUSB(.uploadReceipt)
        let client = LegacyInspectionClient(transport: usb)
        let progress = UploadProgressRecorder()
        try await client.connect(timeoutMilliseconds: 1000)
        let lease = try await client.reserveForChange()
        let result = try await lease.uploadFile(archive, operationID: UUID(), expectedSHA256: BackupManifest.digest(bytes),
                                                expectedBytes: Int64(bytes.count), timeoutMilliseconds: 2000) {
            progress.append($0, $1)
        }
        #expect(result.succeeded)
        #expect(await usb.streamedInput == bytes)
        #expect(await usb.commands.filter { $0 == 12 }.count == 9) // length-bounded data, no hazardous EOF
        #expect(await usb.execPayloads.count == 1)
        let samples = progress.snapshot()
        #expect(samples.count == 9)
        #expect(samples.last?.0 == Int64(bytes.count))
        #expect(samples.allSatisfy { $0.1 == Int64(bytes.count) })
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0.0.0 < $0.1.0 })
        await lease.release()
        await client.disconnect()
    }

    @Test func wrongDigestOrLengthNeverOpensACommand() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("menu.tar")
        let bytes = Data([1, 2, 3]); try bytes.write(to: archive)
        let usb = LegacyFakeUSB(.stream), client = LegacyInspectionClient(transport: usb)
        try await client.connect(timeoutMilliseconds: 1000)
        let lease = try await client.reserveForChange()
        await #expect(throws: (any Error).self) {
            try await lease.uploadFile(archive, operationID: UUID(), expectedSHA256: String(repeating: "0", count: 64),
                                       expectedBytes: 3, timeoutMilliseconds: 1000)
        }
        await #expect(throws: (any Error).self) {
            try await lease.uploadFile(archive, operationID: UUID(), expectedSHA256: BackupManifest.digest(bytes),
                                       expectedBytes: 4, timeoutMilliseconds: 1000)
        }
        #expect(await usb.execPayloads.isEmpty)
        await lease.release()
        await client.disconnect()
    }

    @Test func missingAckClosesSessionWithoutCompletion() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("menu.tar")
        let bytes = Data(repeating: 7, count: 1024); try bytes.write(to: archive)
        let usb = LegacyFakeUSB(.waiting), client = LegacyInspectionClient(transport: usb)
        try await client.connect(timeoutMilliseconds: 1000)
        let lease = try await client.reserveForChange()
        await #expect(throws: (any Error).self) {
            try await lease.uploadFile(archive, operationID: UUID(), expectedSHA256: BackupManifest.digest(bytes),
                                       expectedBytes: Int64(bytes.count), timeoutMilliseconds: 100)
        }
        #expect(await client.isConnected == false)
        #expect(await usb.streamedInput.isEmpty)
    }

    @Test func duplicatedAcknowledgementCannotAdvanceTheStream() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("menu.tar")
        let bytes = Data(repeating: 7, count: 1024); try bytes.write(to: archive)
        let usb = LegacyFakeUSB(.duplicateAck), client = LegacyInspectionClient(transport: usb)
        try await client.connect(timeoutMilliseconds: 1000)
        let lease = try await client.reserveForChange()
        await #expect(throws: (any Error).self) {
            try await lease.uploadFile(archive, operationID: UUID(), expectedSHA256: BackupManifest.digest(bytes),
                                       expectedBytes: Int64(bytes.count), timeoutMilliseconds: 1000)
        }
        #expect(await client.isConnected == false)
    }

    @Test func badRemoteReceiptRefusesCompletion() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("menu.tar")
        let bytes = Data(repeating: 7, count: 1024); try bytes.write(to: archive)
        let usb = LegacyFakeUSB(.badUploadReceipt), client = LegacyInspectionClient(transport: usb)
        try await client.connect(timeoutMilliseconds: 1000)
        let lease = try await client.reserveForChange()
        await #expect(throws: LegacyInspectionError.self) {
            try await lease.uploadFile(archive, operationID: UUID(), expectedSHA256: BackupManifest.digest(bytes),
                                       expectedBytes: Int64(bytes.count), timeoutMilliseconds: 1000)
        }
        #expect(await usb.streamedInput == bytes)
        await lease.release()
        await client.disconnect()
    }

    @Test func shortenedSourceDuringTransferClosesUSBWithoutReceipt() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("menu.tar")
        let bytes = Data(repeating: 7, count: 2048); try bytes.write(to: archive)
        let usb = LegacyFakeUSB(.uploadReceipt), client = LegacyInspectionClient(transport: usb)
        try await client.connect(timeoutMilliseconds: 1000)
        let lease = try await client.reserveForChange()
        await #expect(throws: (any Error).self) {
            try await lease.uploadFile(archive, operationID: UUID(), expectedSHA256: BackupManifest.digest(bytes),
                                       expectedBytes: Int64(bytes.count), timeoutMilliseconds: 1000) { sent, _ in
                if sent == 512 { try? Data().write(to: archive) }
            }
        }
        #expect(await client.isConnected == false)
        #expect(await usb.streamedInput.count < bytes.count)
    }

    @Test func cancelledUploadClosesUSBAndInvalidatesLease() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("menu.tar")
        let bytes = Data(repeating: 7, count: 1024); try bytes.write(to: archive)
        let usb = LegacyFakeUSB(.waiting), client = LegacyInspectionClient(transport: usb)
        try await client.connect(timeoutMilliseconds: 1000)
        let lease = try await client.reserveForChange()
        let pending = Task {
            try await lease.uploadFile(archive, operationID: UUID(), expectedSHA256: BackupManifest.digest(bytes),
                                       expectedBytes: Int64(bytes.count), timeoutMilliseconds: 1000)
        }
        await usb.waitForExecute()
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await client.isConnected == false)
        await usb.setMode(.uploadReceipt)
        try await client.connect(timeoutMilliseconds: 1000)
        await #expect(throws: LegacyInspectionError.self) {
            try await lease.uploadFile(archive, operationID: UUID(), expectedSHA256: BackupManifest.digest(bytes),
                                       expectedBytes: Int64(bytes.count), timeoutMilliseconds: 1000)
        }
        await client.disconnect()
    }

    @Test func receiptAndDestinationAreExactAndInactive() throws {
        let id = UUID()
        let hash = String(repeating: "a", count: 64)
        let command = try LegacyStageTransfer.command(operationID: id, sha256: hash, bytes: 4096)
        #expect(command.utf8.count < 1020)
        #expect(command.contains(LegacyStageTransfer.directory(for: id)))
        #expect(!command.contains(LegacyConsoleReport.gameRoot + "/000"))
        let expected = "STAGED:\(id.uuidString):\(hash):4096\n"
        let good = SSHResult(stdout: expected, stderr: "", stdoutData: Data(expected.utf8), exitCode: 0)
        try LegacyStageTransfer.requireReceipt(good, operationID: id, sha256: hash, bytes: 4096)
        let wrong = SSHResult(stdout: "STAGED\n", stderr: "", stdoutData: Data("STAGED\n".utf8), exitCode: 0)
        #expect(throws: LegacyInspectionError.self) {
            try LegacyStageTransfer.requireReceipt(wrong, operationID: id, sha256: hash, bytes: 4096)
        }
        let failed = SSHResult(stdout: expected, stderr: "", stdoutData: Data(expected.utf8), exitCode: 42)
        #expect(throws: LegacyInspectionError.self) {
            try LegacyStageTransfer.requireReceipt(failed, operationID: id, sha256: hash, bytes: 4096)
        }
        let noisy = SSHResult(stdout: expected, stderr: "warning", stdoutData: Data(expected.utf8), exitCode: 0)
        #expect(throws: LegacyInspectionError.self) {
            try LegacyStageTransfer.requireReceipt(noisy, operationID: id, sha256: hash, bytes: 4096)
        }
    }
}
