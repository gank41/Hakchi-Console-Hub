import Foundation
import USBBridge

/// Isolated from the 6a01 probe and ordinary console connections.
enum SNESTemporaryMenuUSBPolicy {
    static let product = "Swift Hakchi SNES Menu Test"
    static func nativeIdentity(_ device: RecoveryProbeUSBDevice) throws -> hakchi_usb_identity_t {
        guard device.vendorID == 0x1f3a, device.productID == 0xefe8, device.deviceVersion == 0x6a02,
              device.deviceClass == 0, device.product == product, device.locationID != 0,
              let entry = device.registryEntryID, entry > 0 else { throw SNESRuntimeBinding.failure() }
        return hakchi_usb_identity_t(registry_entry_id: entry, location_id: device.locationID, vendor_id: device.vendorID,
            product_id: device.productID, device_version: device.deviceVersion, device_class: device.deviceClass, require_empty_product: false)
    }
    static func after(_ devices: [RecoveryProbeUSBDevice], original: RecoveryProbeUSBDevice) throws -> RecoveryProbeUSBDevice? {
        _ = try RecoveryProbePolicy.before([original])
        if devices.isEmpty || devices == [original] { return nil }
        guard devices.count == 1, let device = devices.first, device.locationID == original.locationID,
              device.registryEntryID != original.registryEntryID else { throw SNESRuntimeBinding.failure() }
        _ = try nativeIdentity(device); return device
    }
}
protocol SNESTemporaryMenuIO: Sendable {
    func inventory() async throws -> [RecoveryProbeUSBDevice]
    func boot(expected: RecoveryProbeUSBDevice) async throws
    func connect(expected: RecoveryProbeUSBDevice) async throws
    func startReport(challenge: UUID) async throws -> Data
    func report(challenge: UUID) async throws -> Data
    func diagnostics() async throws -> Data
    func disconnect() async
}
struct SNESTemporaryMenuResult: Sendable {
    let before: RecoveryProbeUSBDevice, after: RecoveryProbeUSBDevice
    let challenges: [UUID], reports: [Data]
    let phase: String
    func validate(expected: SNESTemporaryMenuExpectation) throws {
        try expected.validate()
        guard try SNESTemporaryMenuUSBPolicy.after([after], original: before) == after,
              ["started", "after-gameplay"].contains(phase), challenges.count == (phase == "started" ? 2 : 1),
              challenges.count == reports.count, Set(challenges).count == challenges.count else { throw SNESRuntimeBinding.failure() }
        for (challenge, report) in zip(challenges, reports) { _ = try SNESTemporaryMenuReport(report, expected: expected, challenge: challenge) }
    }
}
struct SNESTemporaryMenuFailure: Error, Sendable, LocalizedError {
    let stage: String, report: Data, diagnostics: Data
    let capturedReports: [Data]
    init(stage: String, report: Data, diagnostics: Data, capturedReports: [Data] = []) {
        self.stage = stage; self.report = report; self.diagnostics = diagnostics; self.capturedReports = capturedReports
    }
    var errorDescription: String? { "The temporary SNES test stopped at \(stage). Its private diagnostic was retained. No firmware was installed." }
}
actor SNESTemporaryMenuService {
    private var busy = false
    private let wait: @Sendable () async throws -> Void
    init(wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) { self.wait = wait }
    func start(expected: SNESTemporaryMenuExpectation, io: any SNESTemporaryMenuIO,
               validate: @escaping @Sendable () async throws -> Void,
               progress: @escaping RecoveryProgressSink = { _ in }) async throws -> SNESTemporaryMenuResult {
        try await run(expected: expected, started: nil, io: io, validate: validate, progress: progress)
    }
    func check(expected: SNESTemporaryMenuExpectation, started: SNESTemporaryMenuResult, io: any SNESTemporaryMenuIO,
               validate: @escaping @Sendable () async throws -> Void,
               progress: @escaping RecoveryProgressSink = { _ in }) async throws -> SNESTemporaryMenuResult {
        try await run(expected: expected, started: started, io: io, validate: validate, progress: progress)
    }
    private func run(expected: SNESTemporaryMenuExpectation, started: SNESTemporaryMenuResult?, io: any SNESTemporaryMenuIO,
                     validate: @escaping @Sendable () async throws -> Void, progress: @escaping RecoveryProgressSink) async throws -> SNESTemporaryMenuResult {
        guard !busy else { throw LegacyInspectionError.busy }; busy = true; defer { busy = false }
        var stage = "source-check", latest = Data(), connected = false, closed = false
        var capturedReports: [Data] = []
        func checkedSource() async throws { try Task.checkCancellation(); try await validate(); try Task.checkCancellation() }
        do {
            try expected.validate(); try await checkedSource()
            var before: RecoveryProbeUSBDevice
            let after: RecoveryProbeUSBDevice
            if let started {
                try started.validate(expected: expected)
                guard started.phase == "started" else { throw SNESRuntimeBinding.failure() }
                before = started.before; stage = "existing-connection"
                guard try await io.inventory() == [started.after] else { throw SNESRuntimeBinding.failure() }
                try await checkedSource(); after = started.after
            } else {
                stage = "recovery-connection"; await progress(.checkingUSB)
                let devices = try await io.inventory(); try await checkedSource()
                before = try RecoveryProbePolicy.before(devices)
                stage = "temporary-startup"; await progress(.uploadingRecovery)
                try await io.boot(expected: before); try await checkedSource()
                await progress(.waitingForRecovery); stage = "menu-connection"
                var found: RecoveryProbeUSBDevice?
                for _ in 0..<60 {
                    let devices = try await io.inventory(); try await checkedSource()
                    found = try SNESTemporaryMenuUSBPolicy.after(devices, original: before)
                    if found != nil { break }; try await wait(); try await checkedSource()
                }
                guard let found else { throw SNESRuntimeBinding.failure() }; after = found
            }
            let devices = try await io.inventory(); try await checkedSource()
            guard devices == [after] else { throw SNESRuntimeBinding.failure() }
            stage = "opening-menu-connection"
            try await io.connect(expected: after); connected = true; try await checkedSource()
            var reports: [Data] = [], challenges: [UUID] = []
            for index in 0..<(started == nil ? 2 : 1) {
                stage = started == nil && index == 0 ? "startup-report" : "live-menu-report"
                await progress(.checkingIdentity)
                let challenge = UUID()
                try await checkedSource()
                latest = try await (started == nil && index == 0 ? io.startReport(challenge: challenge) : io.report(challenge: challenge))
                try await checkedSource()
                _ = try SNESTemporaryMenuReport(latest, expected: expected, challenge: challenge)
                reports.append(latest); capturedReports.append(latest); challenges.append(challenge)
            }
            stage = "final-connection-check"
            guard try await io.inventory() == [after] else { throw SNESRuntimeBinding.failure() }
            try await checkedSource()
            let result = SNESTemporaryMenuResult(before: before, after: after, challenges: challenges, reports: reports,
                phase: started == nil ? "started" : "after-gameplay")
            try result.validate(expected: expected)
            stage = "closing"
            await progress(.closing); try await checkedSource()
            connected = false; closed = true; await io.disconnect()
            try await checkedSource()
            return result
        } catch {
            if let failure = error as? SNESTemporaryMenuReadFailure { latest = failure.received }
            var diagnostics = (error as? SNESTemporaryMenuReadFailure)?.details ?? Data()
            if connected && !(error is CancellationError) && !Task.isCancelled {
                // A changed source must not lead to a further console command.
                do { try await checkedSource(); let current = try await io.diagnostics(); if !current.isEmpty {
                        if diagnostics.isEmpty { diagnostics = Data(current.prefix(65536)) }
                        else { diagnostics = Data((diagnostics + Data("\nSNES_LATEST_DIAGNOSTICS\n".utf8) + current).prefix(65536)) }
                    } } catch { }
            }
            if !closed { closed = true; await io.disconnect() }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw SNESTemporaryMenuFailure(stage: stage, report: Data(latest.prefix(65536)), diagnostics: diagnostics, capturedReports: capturedReports)
        }
    }
}
