import Foundation
import Testing
@testable import SwiftHakchi
@testable import SwiftHakchiCore

actor LegacyFakeUSB: LegacyUSBTransport {
    enum Mode: Sendable { case normal, stream, uploadReceipt, badUploadReceipt, duplicateAck, backpressure, refusedBeforeMutation, applied, packetReads, consoleReport, lateComplete, wrongPong, missingEOF, earlyResult, nonzero, waiting, oversized }
    var mode: Mode
    var queue: [Data] = []
    var isOpen = false
    var commands: [UInt8] = []
    var execStarted = false
    var execPayloads: [Data] = []
    var streamedInput = Data()
    var inputAckPending = false
    var expectedInputBytes = 0
    init(_ mode: Mode = .normal) { self.mode = mode }
    func open() throws { guard !isOpen else { throw LegacyInspectionError.busy }; isOpen = true; queue = []; execStarted = false }
    func packetSize() -> Int { mode == .packetReads ? 8 : 512 }
    func setMode(_ mode: Mode) { self.mode = mode }
    func close() { isOpen = false; queue = [] }
    func waitForExecute() async { while !execStarted { await Task.yield() } }
    func write(_ data: Data, timeoutMilliseconds: Int) throws {
        guard isOpen else { throw LegacyInspectionError.disconnected }
        var decoder = ClovershellFrameDecoder()
        let frame = try #require(decoder.feed(data).first)
        commands.append(frame.command)
        if frame.command == 0 {
            let payload = mode == .wrongPong ? Data("incorrect".utf8) : frame.payload
            queue.append(try ClovershellFrame(command: 1, connectionID: 0, payload: payload).encoded())
        } else if frame.command == 9 {
            execStarted = true
            execPayloads.append(frame.payload)
            streamedInput = Data()
            let command = String(decoding: frame.payload, as: UTF8.self)
            expectedInputBytes = command.range(of: #"head -c [0-9]+"#, options: .regularExpression)
                .flatMap { Int(command[$0].split(separator: " ").last!) } ?? 0
            var reply = try ClovershellFrame(command: 10, connectionID: 7, payload: Data()).encoded()
            if mode == .lateComplete {
                for command: UInt8 in [13, 14, 15] {
                    reply.append(try ClovershellFrame(command: command, connectionID: 7, payload: command == 15 ? Data([0]) : Data()).encoded())
                }
            }
            queue.append(reply)
            if expectedInputBytes == 0, mode != .waiting, mode != .lateComplete { try completeCommand() }
        } else if frame.command == 12, [.stream, .uploadReceipt, .badUploadReceipt, .duplicateAck, .backpressure, .refusedBeforeMutation, .applied].contains(mode), !frame.payload.isEmpty {
            if mode == .backpressure, inputAckPending { throw LegacyInspectionError.usb(-4) }
            streamedInput.append(frame.payload); inputAckPending = true
            let ack = try ClovershellFrame(command: 18, connectionID: 7, payload: Data([0,0,0,0,0,0,16,0])).encoded()
            queue.append(mode == .duplicateAck ? ack + ack : ack)
            if streamedInput.count == expectedInputBytes { try completeCommand() }
        } else if frame.command == 12, mode != .waiting, mode != .lateComplete {
            try completeCommand()
        }
    }
    private func completeCommand() throws {
            var frames = [ClovershellFrame(command: 13, connectionID: 8, payload: Data("other session".utf8))]
            let result = ClovershellFrame(command: 15, connectionID: 7, payload: Data([mode == .nonzero || mode == .refusedBeforeMutation ? 3 : 0, 0, 0, 0]))
            if mode == .earlyResult { frames.append(result) }
            let receipt: Data = {
                guard mode == .uploadReceipt || mode == .badUploadReceipt,
                      let command = execPayloads.last.flatMap({ String(data: $0, encoding: .utf8) }),
                      let start = command.range(of: "STAGED:"),
                      let end = command[start.lowerBound...].firstIndex(of: "\n") else { return Data() }
                return mode == .badUploadReceipt ? Data("STAGED:wrong\n".utf8) : Data(command[start.lowerBound...end].utf8)
            }()
            let isIdentity = String(decoding: execPayloads.last ?? Data(), as: UTF8.self).contains("SWIFTHAKCHI_CONSOLE_ID_V1")
            let isChip = String(decoding: execPayloads.last ?? Data(), as: UTF8.self).contains("SWIFTHAKCHI_CHIP_ID_V1")
            let report = isIdentity ? "SWIFTHAKCHI_CONSOLE_ID_V1\nBOARD=dp-nes\nREGION=EUR_USA\nEND\n" : isChip ? "SWIFTHAKCHI_CHIP_ID_V1\n0x01234567\n0x89abcdef\n0x00112233\n0x44556677\nEND\n" : legacyReportFixture
            frames.append(ClovershellFrame(command: 13, connectionID: 7, payload: mode == .uploadReceipt || mode == .badUploadReceipt ? receipt : mode == .refusedBeforeMutation ? Data("REFUSED_BEFORE_MUTATION\n".utf8) : mode == .applied ? Data("APPLIED\n".utf8) : mode == .consoleReport ? Data(report.utf8) : (mode == .oversized ? Data(repeating: 1, count: 128) : Data([0, 1, 255, 0, 2]))))
            if mode != .uploadReceipt && mode != .badUploadReceipt { frames.append(ClovershellFrame(command: 14, connectionID: 7, payload: Data("diagnostic".utf8))) }
            if mode != .missingEOF { frames.append(ClovershellFrame(command: 13, connectionID: 7, payload: Data())) }
            frames.append(ClovershellFrame(command: 14, connectionID: 7, payload: Data()))
            if mode != .earlyResult { frames.append(result) }
            let combined = try frames.reduce(into: Data()) { $0.append(try $1.encoded()) }
            // Fragment across headers, payloads and consecutive frame boundaries.
            for offset in stride(from: 0, to: combined.count, by: 7) { queue.append(Data(combined[offset..<min(offset + 7, combined.count)])) }
    }
    func read(maximumBytes: Int, timeoutMilliseconds: Int) async throws -> Data {
        guard isOpen else { throw LegacyInspectionError.disconnected }
        if !queue.isEmpty {
            if mode == .packetReads {
                let packet = Data(queue[0].prefix(8))
                queue[0].removeFirst(packet.count)
                if queue[0].isEmpty { queue.removeFirst() }
                // Model an aborted multi-packet IOKit request: consumed bytes are invalid.
                if maximumBytes > 8 && packet.count == 8 { return Data() }
                return packet
            }
            if mode == .lateComplete, execStarted { try await Task.sleep(for: .milliseconds(30)) }
            let value = queue.removeFirst()
            if value.first == 18 { inputAckPending = false }
            return value
        }
        await Task.yield(); return Data()
    }
}

struct LegacyProtocolTests {
    @Test func lengthBoundCommandsNeverCloseDaemonInputPipes() async throws {
        let usb = LengthBoundLegacyUSB()
        let client = LegacyInspectionClient(transport: usb)
        try await client.connect()
        #expect(try await client.execute(.report, timeoutMilliseconds: 100).succeeded)
        let lease = try await client.reserveForChange()
        let target = try LegacyHistoricalCleanup.Target(path: "/var/lib/hakchi/games/nes.swift-old-" + UUID().uuidString)
        #expect(try await lease.perform(.inventoryHistorical(target)).succeeded)
        #expect(await usb.emptyInputFrames == 0)
        let expected = try LegacyHistoricalCleanupCommands.inventory(target: target).trimmingCharacters(in: .newlines)
        #expect(await usb.receivedInput == Data(expected.utf8))
        await lease.release(); await client.disconnect()
    }
    @Test func usbTimeoutExplainsConnectionRecovery() {
        let message = LegacyInspectionError.usb(-4).localizedDescription
        #expect(message.contains("timed out"))
        #expect(message.contains("USB"))
    }

    @Test func framesDecodeAtEverySplitAndCoalesceWithoutLosingBinaryBytes() throws {
        let original = ClovershellFrame(command: 13, connectionID: 7, payload: Data([0, 255, 1, 0, 7]))
        let encoded = try original.encoded()
        for split in 0...encoded.count {
            var decoder = ClovershellFrameDecoder()
            let first = try decoder.feed(Data(encoded.prefix(split)))
            let second = try decoder.feed(Data(encoded.dropFirst(split)))
            #expect(first + second == [original])
        }
        var decoder = ClovershellFrameDecoder()
        #expect(try decoder.feed(encoded + encoded) == [original, original])
    }
    @Test func protocolPayloadLimitRejectsInvalidEncoding() {
        #expect(throws: (any Error).self) { try ClovershellFrame(command: 0, connectionID: 0, payload: Data(count: 65536)).encoded() }
    }
    @Test(arguments: [LegacyFakeUSB.Mode.normal, .earlyResult])
    func completeBinaryOutputRequiresBothEOFsAndResult(mode: LegacyFakeUSB.Mode) async throws {
        let usb = LegacyFakeUSB(mode); let client = LegacyInspectionClient(transport: usb)
        try await client.connect(timeoutMilliseconds: 1000)
        let result = try await client.execute(.report, timeoutMilliseconds: 1000)
        #expect(result.stdoutData == Data([0, 1, 255, 0, 2]))
        #expect(result.stderr == "diagnostic")
        #expect(result.exitCode == 0)
        #expect(await usb.commands == [0, 9]) // no session kills, stdin EOF, or upload commands
        await client.disconnect()
    }
    @Test func wrongPongCannotExecuteAnyShellCommand() async {
        let usb = LegacyFakeUSB(.wrongPong); let client = LegacyInspectionClient(transport: usb)
        await #expect(throws: (any Error).self) { try await client.connect(timeoutMilliseconds: 20) }
        #expect(await usb.commands == [0])
        #expect(await usb.isOpen == false)
    }
    @Test func missingEOFIsFailureEvenAfterResult() async throws {
        let usb = LegacyFakeUSB(.missingEOF); let client = LegacyInspectionClient(transport: usb)
        try await client.connect(timeoutMilliseconds: 1000)
        await #expect(throws: (any Error).self) { try await client.execute(.report, timeoutMilliseconds: 20) }
        #expect(await usb.isOpen == false)
    }
    @Test func nonzeroExitIsPreserved() async throws {
        let usb = LegacyFakeUSB(.nonzero); let client = LegacyInspectionClient(transport: usb)
        try await client.connect(timeoutMilliseconds: 1000)
        #expect(try await client.execute(.report, timeoutMilliseconds: 1000).exitCode == 3)
        await client.disconnect()
    }
    @Test func outputLimitCannotProducePartialSuccess() async throws {
        let usb = LegacyFakeUSB(.oversized); let client = LegacyInspectionClient(transport: usb, maximumOutputBytes: 32)
        try await client.connect(timeoutMilliseconds: 1000)
        await #expect(throws: (any Error).self) { try await client.execute(.report, timeoutMilliseconds: 1000) }
        #expect(await usb.isOpen == false)
    }
    @Test func overlappingCommandIsRejectedAndCancellationClosesUSB() async throws {
        let usb = LegacyFakeUSB(.waiting); let client = LegacyInspectionClient(transport: usb)
        try await client.connect(timeoutMilliseconds: 1000)
        let first = Task { try await client.execute(.report, timeoutMilliseconds: 1000) }
        await usb.waitForExecute()
        await #expect(throws: LegacyInspectionError.self) { try await client.execute(.report, timeoutMilliseconds: 1000) }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await usb.isOpen == false)
    }
}

/// The 2017 daemon closes its writer on EOF, then closes that descriptor again
/// during periodic cleanup. A later command can own the reused descriptor.
/// This peer requires length-bounded input and rejects that hazardous EOF path.
actor LengthBoundLegacyUSB: LegacyUSBTransport {
    var queue: [Data] = []
    var receivedInput = Data()
    var expectedInput = 0
    var emptyInputFrames = 0
    func open() {}
    func close() {}
    func packetSize() -> Int { 512 }
    func write(_ data: Data, timeoutMilliseconds: Int) throws {
        var decoder = ClovershellFrameDecoder()
        let frame = try #require(decoder.feed(data).first)
        if frame.command == 0 {
            queue.append(try ClovershellFrame(command: 1, connectionID: 0, payload: frame.payload).encoded())
        } else if frame.command == 9 {
            receivedInput = Data()
            let command = String(decoding: frame.payload, as: UTF8.self)
            expectedInput = command.range(of: #"head -c [0-9]+"#, options: .regularExpression)
                .flatMap { Int(command[$0].split(separator: " ").last!) } ?? 0
            queue.append(try ClovershellFrame(command: 10, connectionID: 7, payload: Data()).encoded())
            if expectedInput == 0 { try complete() }
        } else if frame.command == 12 {
            if frame.payload.isEmpty { emptyInputFrames += 1; throw LegacyInspectionError.invalidResponse }
            receivedInput.append(frame.payload)
            queue.append(try ClovershellFrame(command: 18, connectionID: 7, payload: Data([0,0,0,0,0,0,16,0])).encoded())
            if receivedInput.count == expectedInput { try complete() }
        }
    }
    private func complete() throws {
        for command: UInt8 in [13, 14, 15] {
            queue.append(try ClovershellFrame(command: command, connectionID: 7,
                payload: command == 15 ? Data([0]) : Data()).encoded())
        }
    }
    func read(maximumBytes: Int, timeoutMilliseconds: Int) async -> Data {
        if !queue.isEmpty { return queue.removeFirst() }
        await Task.yield(); return Data()
    }
}

extension LegacyProtocolTests {
    @Test func oldMenuInventoryCommandIsReadOnlyAndBoundToOneOperation() {
        let id = UUID()
        let script = LegacyStageVerification.oldInventoryCommand(operationID: id)
        #expect(script.contains(LegacySyncCommands.oldPath(for: id)))
        #expect(script.contains("old.identity"))
        #expect(script.contains("ACCEPTED"))
        #expect(script.contains("STAGE_INVENTORY:\(id.uuidString)"))
        #expect(!script.contains("rm -rf"))
    }

    @Test func lateCompleteResponseCannotBypassDeadline() async throws {
        let usb = LegacyFakeUSB(.lateComplete); let client = LegacyInspectionClient(transport: usb)
        try await client.connect(timeoutMilliseconds: 1000)
        await #expect(throws: (any Error).self) { try await client.execute(.report, timeoutMilliseconds: 5) }
        #expect(await usb.isOpen == false)
    }
    @Test func secondConnectDoesNotCloseExistingVerifiedSession() async throws {
        let usb = LegacyFakeUSB(); let client = LegacyInspectionClient(transport: usb)
        try await client.connect(timeoutMilliseconds: 1000)
        await #expect(throws: LegacyInspectionError.self) { try await client.connect(timeoutMilliseconds: 1000) }
        #expect(await usb.isOpen)
        #expect(try await client.execute(.report, timeoutMilliseconds: 1000).exitCode == 0)
        await client.disconnect()
    }
    @Test func disconnectedPendingReadCannotSurviveReconnect() async throws {
        let usb = LegacyFakeUSB(.waiting); let client = LegacyInspectionClient(transport: usb)
        try await client.connect(timeoutMilliseconds: 1000)
        let pending = Task { try await client.execute(.report, timeoutMilliseconds: 1000) }
        await usb.waitForExecute(); await client.disconnect()
        await #expect(throws: (any Error).self) { try await pending.value }
        await usb.setMode(.normal)
        try await client.connect(timeoutMilliseconds: 1000)
        #expect(try await client.execute(.report, timeoutMilliseconds: 1000).exitCode == 0)
        await client.disconnect()
    }
}

extension LegacyProtocolTests {
    @Test func packetSizedReadsAvoidLosingDataAtUSBIdleGaps() async throws {
        let usb = LegacyFakeUSB(.packetReads); let client = LegacyInspectionClient(transport: usb)
        try await client.connect(timeoutMilliseconds: 50)
        let result = try await client.execute(.report, timeoutMilliseconds: 1000)
        #expect(result.stdoutData == Data([0, 1, 255, 0, 2]))
        await client.disconnect()
    }
}
