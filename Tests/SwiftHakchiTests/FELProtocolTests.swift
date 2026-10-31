import Foundation
import Testing
import USBBridge

private final class FELWire {
    var replies: [Data]
    var writes: [Data] = []
    var readCount = 0
    var writeReturns: [Int: Int32] = [:]
    var readReturns: [Int: Int32] = [:]
    var waits: [UInt32] = []
    init(_ replies: [Data]) { self.replies = replies }
}

private func awAck(_ status: UInt8 = 0) -> Data {
    var bytes = Data("AWUS".utf8); bytes.append(Data(count: 8)); bytes.append(status); return bytes
}
private func felStatus(_ state: UInt8 = 0) -> Data {
    var bytes = Data(count: 8); bytes[4] = state; return bytes
}
private func boardReply(_ board: UInt32 = UInt32(EXPECTED_BOARD_ID)) -> Data {
    var bytes = Data("AWUSBFEX".utf8); bytes.append(Data(count: 24))
    for i in 0..<4 { bytes[8 + i] = UInt8(truncatingIfNeeded: board >> (i * 8)) }
    return bytes
}
private func verifyReplies(board: UInt32 = UInt32(EXPECTED_BOARD_ID), state: UInt8 = 0) -> [Data] {
    [awAck(), boardReply(board), awAck(), felStatus(state), awAck()]
}
private func memoryWriteReplies() -> [Data] { [awAck(), awAck(), felStatus(), awAck()] }
private func memoryReadReplies(_ data: Data) -> [Data] { [awAck(), data, awAck(), felStatus(), awAck()] }
private func executeReplies() -> [Data] { [awAck(), felStatus(), awAck()] }
private func word(_ bytes: Data, _ offset: Int) -> UInt32 {
    (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
}
private func memoryCommands(_ wire: FELWire) -> [Data] {
    wire.writes.filter { $0.count == 16 && [UInt8(1), 2, 3].contains($0[0]) && $0[1] == 1 }
}

private func withFELWire<T>(_ wire: FELWire, body: (UnsafeMutablePointer<fel_device_t>) throws -> T) throws -> T {
    let context = Unmanaged.passRetained(wire).toOpaque()
    defer { Unmanaged<FELWire>.fromOpaque(context).release() }
    var transport = fel_transport_t(write: { context, bytes, count in
        guard let context, let bytes else { return -6 }
        let wire = Unmanaged<FELWire>.fromOpaque(context).takeUnretainedValue()
        wire.writes.append(Data(bytes: bytes, count: Int(count)))
        return wire.writeReturns[wire.writes.count] ?? count
    }, read: { context, bytes, capacity in
        guard let context, let bytes else { return -6 }
        let wire = Unmanaged<FELWire>.fromOpaque(context).takeUnretainedValue()
        wire.readCount += 1
        guard !wire.replies.isEmpty else { return -4 }
        let reply = wire.replies.removeFirst()
        reply.prefix(Int(capacity)).withUnsafeBytes { source in
            if let start = source.baseAddress { memcpy(bytes, start, source.count) }
        }
        return wire.readReturns[wire.readCount] ?? Int32(reply.count)
    }, wait_us: { context, duration in
        guard let context else { return }
        Unmanaged<FELWire>.fromOpaque(context).takeUnretainedValue().waits.append(duration)
    })
    let device = try #require(fel_open_transport(&transport, context))
    defer { fel_close(device) }
    return try body(device)
}
private func authorize(_ device: UnsafeMutablePointer<fel_device_t>) throws {
    var reply = aw_fel_verify_response_t()
    try #require(fel_verify_device(device, &reply) == 0)
}

struct FELProtocolTests {
    @Test func readsExactlySixteenSIDBytesBeforeDRAMInitialization() throws {
        let sid=Data(1...16),wire=FELWire(verifyReplies()+memoryReadReplies(sid))
        try withFELWire(wire) { device in
            try authorize(device)
            var bytes=[UInt8](repeating:0,count:16)
            #expect(fel_read_memory(device,0x01c23800,&bytes,16,nil,nil)==0)
            #expect(Data(bytes)==sid && device.pointee.board_verified && !device.pointee.dram_initialized)
            let command=try #require(memoryCommands(wire).first)
            #expect(word(command,4)==0x01c23800 && word(command,8)==16)
            #expect(wire.replies.isEmpty)
        }
    }
    @Test func invalidHandlesAndMaximumWriteFailBeforeDereferencingOrTransport() throws {
        var byte: UInt8 = 0
        var response = aw_fel_verify_response_t()
        #expect(fel_verify_device(nil, &response) == -6)
        #expect(fel_write_memory(nil, 0x2000, &byte, 1, nil, nil) == -6)
        #expect(fel_read_memory(nil, 0x2000, &byte, 1, nil, nil) == -6)
        #expect(fel_exec(nil, 0x2000) == -6)
        #expect(fel_init_dram(nil, &byte, 128) == -6)
        #expect(fel_open_transport(nil, nil) == nil)
        let wire = FELWire(verifyReplies())
        try withFELWire(wire) { device in
            try authorize(device)
            let before = wire.writes.count
            #expect(fel_write_memory(device, 0x2000, &byte, .max, nil, nil) == -6)
            #expect(fel_write_memory(device, 0x2000, nil, 4, nil, nil) == -6)
            #expect(fel_read_memory(device, 0x2000, nil, 4, nil, nil) == -6)
            #expect(wire.writes.count == before)
        }
    }
    @Test func memoryTimeoutRevokesAuthorizationBeforeRetry() throws {
        let wire = FELWire(verifyReplies() + memoryWriteReplies() + executeReplies())
        try withFELWire(wire) { device in
            try authorize(device)
            wire.readReturns[wire.readCount + 1] = -4
            let data = Data(repeating: 1, count: 4)
            #expect(data.withUnsafeBytes { fel_write_memory(device, 0x2000, $0.bindMemory(to: UInt8.self).baseAddress, 4, nil, nil) } == -4)
            #expect(!device.pointee.board_verified && !device.pointee.dram_initialized)
            let before = wire.writes.count
            #expect(fel_exec(device, 0x2000) == -6)
            #expect(wire.writes.count == before)
        }
    }
    @Test func chunkedReadCopiesOnlyRequestedBytes() throws {
        let wire = FELWire(verifyReplies() + memoryReadReplies(Data(repeating: 0x55, count: 65536)) + memoryReadReplies(Data([0x77,0x88,0x99,0xAA])))
        try withFELWire(wire) { device in
            try authorize(device)
            var bytes = [UInt8](repeating: 0xCC, count: 65539)
            let result = bytes.withUnsafeMutableBufferPointer { fel_read_memory(device, 0x2000, $0.baseAddress!.advanced(by: 1), 65537, nil, nil) }
            #expect(result == 0)
            #expect(bytes[0] == 0xCC && bytes[65538] == 0xCC)
            #expect(bytes[1..<65537].allSatisfy { $0 == 0x55 } && bytes[65537] == 0x77)
            #expect(memoryCommands(wire).map { word($0, 8) } == [65536, 4])
        }
    }

    @Test func completeChallengeRequiresFinalStatusAndAuthorizesOnlyExpectedBoard() throws {
        let wire = FELWire(verifyReplies())
        try withFELWire(wire) { device in
            try authorize(device)
            #expect(device.pointee.board_verified)
            #expect(!device.pointee.dram_initialized)
            #expect(wire.replies.isEmpty)
            #expect(memoryCommands(wire).isEmpty)
        }
    }
    @Test(arguments: [1, 2, 3, 4, 5])
    func shortReadCannotAuthorizeBoard(read: Int) throws {
        let replies = verifyReplies(), wire = FELWire(replies)
        wire.readReturns[read] = Int32(replies[read - 1].count - 1)
        try withFELWire(wire) { device in
            var reply = aw_fel_verify_response_t()
            #expect(fel_verify_device(device, &reply) < 0)
            #expect(!device.pointee.board_verified)
        }
    }
    @Test(arguments: [1, 2, 3, 4])
    func shortRequestOrPayloadWriteFails(write: Int) throws {
        let wire = FELWire(verifyReplies()); wire.writeReturns[write] = write == 2 ? 15 : 31
        try withFELWire(wire) { device in
            var reply = aw_fel_verify_response_t()
            #expect(fel_verify_device(device, &reply) < 0)
            #expect(wire.writes.count == write)
            #expect(!device.pointee.board_verified)
        }
    }
    @Test func finalStatusTimeoutAndNonzeroStateAreNotDiscarded() throws {
        for timeout in [false, true] {
            let wire = FELWire(verifyReplies(state: timeout ? 0 : 1))
            if timeout { wire.readReturns[4] = -4 }
            try withFELWire(wire) { device in
                var reply = aw_fel_verify_response_t()
                let result = fel_verify_device(device, &reply)
                #expect(timeout ? result == -4 : result < 0)
                #expect(!device.pointee.board_verified)
            }
        }
    }
    @Test func badAcknowledgementOrBoardMagicFails() throws {
        for boardMagic in [false, true] {
            var replies = verifyReplies(); replies[boardMagic ? 1 : 0][0] = 0
            let wire = FELWire(replies)
            try withFELWire(wire) { device in
                var reply = aw_fel_verify_response_t()
                #expect(fel_verify_device(device, &reply) < 0)
                #expect(!device.pointee.board_verified)
            }
        }
    }
    @Test func wrongBoardCannotWriteOrExecute() throws {
        let wire = FELWire(verifyReplies(board: 0x123400) + memoryWriteReplies() + executeReplies())
        try withFELWire(wire) { device in
            try authorize(device) // A complete response may describe a different board.
            let before = wire.writes.count
            let bytes = Data(repeating: 1, count: 4)
            #expect(bytes.withUnsafeBytes { fel_write_memory(device, 0x2000, $0.bindMemory(to: UInt8.self).baseAddress, 4, nil, nil) } == -6)
            #expect(fel_exec(device, 0x2000) == -6)
            #expect(wire.writes.count == before)
            #expect(!device.pointee.board_verified)
        }
    }
    @Test func failedReverificationClearsPreviousAuthorization() throws {
        let wire = FELWire(verifyReplies() + verifyReplies(state: 1) + executeReplies())
        try withFELWire(wire) { device in
            try authorize(device)
            device.pointee.dram_initialized = true
            var reply = aw_fel_verify_response_t()
            #expect(fel_verify_device(device, &reply) < 0)
            #expect(!device.pointee.board_verified && !device.pointee.dram_initialized)
            let before = wire.writes.count
            #expect(fel_exec(device, 0x2000) == -6)
            #expect(wire.writes.count == before)
        }
    }
    @Test func zeroUnalignedAndWrappingRangesFailBeforeTransport() throws {
        let wire = FELWire(verifyReplies())
        try withFELWire(wire) { device in
            try authorize(device)
            let before = wire.writes.count
            let data = Data(repeating: 1, count: 8)
            for (address, length): (UInt32, UInt32) in [(0x2000, 0), (0x2001, 4), (0xFFFFFFFC, 8)] {
                #expect(data.withUnsafeBytes { fel_write_memory(device, address, $0.bindMemory(to: UInt8.self).baseAddress, length, nil, nil) } == -6)
            }
            var buffer = [UInt8](repeating: 0, count: 8)
            #expect(fel_read_memory(device, 0x2000, &buffer, .max, nil, nil) == -6)
            #expect(fel_exec(device, 0x2001) == -6)
            #expect(wire.writes.count == before)
        }
    }
    @Test func oversizedLogicalTransferIsRejectedBeforeAnyCommand() throws {
        let wire = FELWire(verifyReplies())
        try withFELWire(wire) { device in
            try authorize(device)
            let before = wire.writes.count
            let data = Data(repeating: 0, count: 32 * 1024 * 1024 + 1)
            #expect(data.withUnsafeBytes { fel_write_memory(device, 0x2000, $0.bindMemory(to: UInt8.self).baseAddress, UInt32(data.count), nil, nil) } == -6)
            #expect(wire.writes.count == before)
        }
    }
    @Test func paddedRangeCrossingIntoDRAMRequiresInitialization() throws {
        let wire = FELWire(verifyReplies())
        try withFELWire(wire) { device in
            try authorize(device)
            let before = wire.writes.count
            let data = Data(repeating: 1, count: 8)
            #expect(data.withUnsafeBytes { fel_write_memory(device, UInt32(DRAM_BASE) - 4, $0.bindMemory(to: UInt8.self).baseAddress, 5, nil, nil) } == -6)
            var buffer = [UInt8](repeating: 0, count: 8)
            #expect(fel_read_memory(device, UInt32(DRAM_BASE) - 4, &buffer, 5, nil, nil) == -6)
            #expect(fel_exec(device, UInt32(DRAM_BASE)) == -6)
            #expect(wire.writes.count == before)
        }
    }
    @Test func oddWritePadsLocallyAndOddReadPreservesSentinels() throws {
        let wire = FELWire(verifyReplies() + memoryWriteReplies() + memoryReadReplies(Data([1,2,3,0xEE])))
        try withFELWire(wire) { device in
            try authorize(device)
            let data = Data([1,2,3])
            #expect(data.withUnsafeBytes { fel_write_memory(device, 0x2000, $0.bindMemory(to: UInt8.self).baseAddress, 3, nil, nil) } == 0)
            #expect(wire.writes.contains(Data([1,2,3,0])))
            var result = [UInt8](repeating: 0xA5, count: 5)
            let status = result.withUnsafeMutableBufferPointer { fel_read_memory(device, 0x2000, $0.baseAddress!.advanced(by: 1), 3, nil, nil) }
            #expect(status == 0 && result == [0xA5,1,2,3,0xA5])
            #expect(data == Data([1,2,3]))
        }
    }
    @Test func transferChunkBoundAndAddressProgressAreExact() throws {
        let wire = FELWire(verifyReplies() + memoryWriteReplies() + memoryWriteReplies())
        try withFELWire(wire) { device in
            try authorize(device)
            let data = Data(repeating: 0x23, count: 65537)
            #expect(data.withUnsafeBytes { fel_write_memory(device, 0x2000, $0.bindMemory(to: UInt8.self).baseAddress, UInt32(data.count), nil, nil) } == 0)
            let commands = memoryCommands(wire)
            #expect(commands.map { word($0, 4) } == [0x2000, 0x12000])
            #expect(commands.map { word($0, 8) } == [65536, 4])
            #expect(wire.writes.contains(Data([0x23,0,0,0])))
        }
    }
    @Test func initializationReadsBackBeforeExecAndDoesNotTrustSRAMTail() throws {
        let fes = Data(repeating: 0x5A, count: 128)
        let wire = FELWire(verifyReplies() + memoryWriteReplies() + memoryReadReplies(fes) + executeReplies())
        try withFELWire(wire) { device in
            try authorize(device)
            #expect(fes.withUnsafeBytes { fel_init_dram(device, $0.bindMemory(to: UInt8.self).baseAddress, UInt32(fes.count)) } == 0)
            #expect(memoryCommands(wire).map { $0[0] } == [1,3,2])
            #expect(device.pointee.dram_initialized)
            #expect(wire.waits == [2_000_000])
        }
    }
    @Test func failedFesReadbackPreventsExecAndInitialization() throws {
        let fes = Data(repeating: 0x5A, count: 128)
        let wire = FELWire(verifyReplies() + memoryWriteReplies() + memoryReadReplies(Data(repeating: 0, count: 128)) + executeReplies())
        try withFELWire(wire) { device in
            try authorize(device)
            #expect(fes.withUnsafeBytes { fel_init_dram(device, $0.bindMemory(to: UInt8.self).baseAddress, UInt32(fes.count)) } < 0)
            #expect(!memoryCommands(wire).contains { $0[0] == 2 })
            #expect(!device.pointee.dram_initialized)
            #expect(wire.waits.isEmpty)
        }
    }
}
