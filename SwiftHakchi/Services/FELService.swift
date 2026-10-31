import Foundation
import USBBridge

/// Checked RAM-boot transport only. Firmware install/reset eligibility is separate.
actor FELService: FELBooting {
    private let makeSession: @Sendable () -> any FELSessionTransport
    private var busy = false

    init(makeSession: @escaping @Sendable () -> any FELSessionTransport = { IOKitFELSessionTransport() }) {
        self.makeSession = makeSession
    }

    private func acquire() throws {
        guard !busy else { throw FELError.busy }
        busy = true
    }

    /// Read the actual FEL response; shared USB identifiers are insufficient proof.
    func verifyDevice() async throws -> UInt32 {
        try acquire(); defer { busy = false }
        try Task.checkCancellation()
        let session = makeSession()
        do {
            try await session.open()
            try Task.checkCancellation()
            let board = try await session.verifyBoard()
            try Task.checkCancellation()
            guard board == UInt32(EXPECTED_BOARD_ID) else { throw FELError.wrongBoard(board) }
            await session.close()
            return board
        } catch { await session.close(); throw error }
    }

    /// Validates and patches all input bytes before USB, then verifies the complete RAM
    /// copies on one board-verified handle. This requests execution, not a verified USB boot.
    func memboot(fes1Data: Data, ubootData: Data, bootImgData: Data,
                 progress: (@Sendable (String, Double) -> Void)? = nil) async throws {
        try acquire(); defer { busy = false }
        try Task.checkCancellation()
        let prepared = try PreparedRecoveryBoot(fes1: fes1Data, uboot: ubootData, bootImage: bootImgData)
        try Task.checkCancellation()
        try await transfer(fes1: prepared.fes1, uboot: prepared.uboot, image: prepared.bootImage, progress: progress)
    }

    func memboot(probe: PreparedSNESRAMProbe, progress: (@Sendable (String, Double) -> Void)? = nil) async throws {
        try acquire(); defer { busy = false }
        try Task.checkCancellation()
        try probe.validateCurrent()
        try await transfer(fes1: probe.fes1, uboot: probe.uboot, image: probe.image, progress: progress)
    }

    func memboot(menu: PreparedSNESTemporaryMenu, progress: (@Sendable (String, Double) -> Void)? = nil) async throws {
        try acquire(); defer { busy = false }
        try Task.checkCancellation(); try menu.validateCurrent()
        try await transfer(fes1: menu.fes1, uboot: menu.uboot, image: menu.image, progress: progress)
    }

    func memboot(originalMenu: PreparedSNESOriginalMenu, progress: (@Sendable (String, Double) -> Void)? = nil) async throws {
        try acquire(); defer { busy = false }
        try Task.checkCancellation(); try originalMenu.validateCurrent()
        try await transfer(fes1: originalMenu.fes1, uboot: originalMenu.uboot, image: originalMenu.image, progress: progress, validateSource: { try originalMenu.validateCurrent() })
    }

    func memboot(alienTrial: PreparedSNESAlienTrial, progress: (@Sendable (String, Double) -> Void)? = nil) async throws {
        try acquire(); defer { busy = false }
        try Task.checkCancellation(); try alienTrial.validateCurrent()
        try await transfer(fes1: alienTrial.base.fes1, uboot: alienTrial.base.uboot, image: alienTrial.image, progress: progress,
                           expectedHWID: alienTrial.expectation.binding.expectedHWID,
                           validateSource: { try alienTrial.validateCurrent() })
    }

    func memboot(startupTrial: PreparedSNESStartupTrial, progress: (@Sendable (String, Double) -> Void)? = nil) async throws {
        try acquire(); defer { busy = false }
        // Reconstructing historical evidence must remain possible for stock recovery.
        // Refuse unsupported execution here, before creating or opening a USB session.
        try SNESColdBootPolicy.requireSupportedImage(startupTrial.image)
        try startupTrial.validateCurrent()
        try await transfer(fes1: startupTrial.fes1, uboot: startupTrial.uboot, image: startupTrial.image, progress: progress,
            expectedHWID: startupTrial.expectedHWID, validateSource: { try startupTrial.validateCurrent() })
    }

    private func transfer(fes1: Data, uboot: Data, image: Data, progress: (@Sendable (String, Double) -> Void)?,
                          expectedHWID: String? = nil, validateSource: @Sendable () throws -> Void = {}) async throws {
        func check() throws { try Task.checkCancellation(); try validateSource(); try Task.checkCancellation() }
        try check()
        let session = makeSession()
        func checkSID() async throws {
            guard let expectedHWID else { return }
            progress?("Checking console hardware identity…", 0.10)
            let bytes = try await session.readHardwareIdentity()
            try check()
            let actual: String
            do { actual = try SNESStartupSID.decode(bytes) }
            catch { throw RecoveryProbeError.refused("The hardware identity read returned invalid bytes: " + bytes.prefix(16).map { String(format: "%02x", $0) }.joined()) }
            guard actual == expectedHWID else {
                throw RecoveryProbeError.refused("The hardware identity read did not match the saved console: " + actual)
            }
        }
        do {
            progress?("Opening FEL recovery connection…", 0.05)
            try check()
            try await session.open()
            try check()
            if expectedHWID != nil { progress?("Checking the recovery board…", 0.08) }
            let board = try await session.verifyBoard()
            try check()
            guard board == UInt32(EXPECTED_BOARD_ID) else { throw FELError.wrongBoard(board) }
            try await checkSID(); try check()

            progress?("Verifying DRAM loader and initializing memory…", 0.15)
            try check()
            try await session.initializeDRAM(fes1: fes1)
            try check()

            progress?("Uploading prepared U-Boot…", 0.30)
            try check()
            try await session.write(address: UInt32(UBOOT_BASE_M), data: uboot)
            try check()
            let ubootReadback = try await session.read(address: UInt32(UBOOT_BASE_M), count: uboot.count)
            try check()
            guard ubootReadback == uboot else { throw FELError.readbackMismatch("U-Boot") }

            progress?("Uploading prepared recovery kernel…", 0.55)
            try check()
            try await session.write(address: UInt32(TRANSFER_BASE_M), data: image)
            try check()
            let kernelReadback = try await session.read(address: UInt32(TRANSFER_BASE_M), count: image.count)
            try check()
            guard kernelReadback == image else { throw FELError.readbackMismatch("recovery kernel") }
            try await checkSID(); try check()

            progress?("RAM images verified; requesting recovery boot…", 0.95)
            try check()
            try await session.execute(address: UInt32(UBOOT_BASE_M))
            // Execution may already have started: do not relabel it as an unstarted
            // operation if cancellation arrives during the final command.
            await session.close()
            progress?("Boot execution requested; recovery USB startup still needs verification.", 1.0)
        } catch { await session.close(); throw error }
    }
}

enum FELError: Error, LocalizedError {
    case deviceNotFound, busy, invalidTransfer
    case communicationError(Int32)
    case wrongBoard(UInt32)
    case dramInitFailed(Int32)
    case writeError(Int32)
    case readError(Int32)
    case execError(Int32)
    case readbackMismatch(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotFound: return "FEL device not found. Connect the console in FEL mode."
        case .busy: return "A FEL operation is already running."
        case .invalidTransfer: return "Invalid or oversized recovery memory transfer."
        case .communicationError(let code): return "USB communication error (code: \(code))."
        case .wrongBoard(let board): return "Unexpected board ID: 0x\(String(board, radix: 16))."
        case .dramInitFailed(let code): return "DRAM loader verification or initialization failed (code: \(code))."
        case .writeError(let code): return "Memory upload failed (code: \(code))."
        case .readError(let code): return "Memory readback failed (code: \(code))."
        case .execError(let code): return "Device execution request failed (code: \(code)); its outcome may be uncertain."
        case .readbackMismatch(let image): return "\(image) RAM readback differs from the prepared copy. Boot execution was not requested."
        }
    }
}
