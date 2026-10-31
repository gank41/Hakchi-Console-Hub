import Foundation
import SwiftHakchiCore

enum ConsoleAttachmentPolicy {
    enum Kind: Equatable, Sendable { case recovery, legacy, nativeSNES, rndis, unsupported }
    static func kind(of device: RecoveryProbeUSBDevice) -> Kind {
        guard (device.registryEntryID ?? 0) > 0, device.locationID > 0 else { return .unsupported }
        if device.isFEL, device.deviceClass == 0 {
            if device.deviceVersion == 0x02b3, device.product.isEmpty { return .recovery }
            if [UInt16(0x6a04), UInt16(0x6a05), UInt16(0x6a06),UInt16(0x6a07),UInt16(0x6a08),UInt16(0x6a09),UInt16(0x6a0a),UInt16(0x6a0b)].contains(device.deviceVersion),
               device.product == SNESStartupTrialUSBPolicy.product { return .nativeSNES }
            if device.deviceVersion == 0x0233,
               device.product.range(of: #"^CLV-[A-Z0-9-]{1,40}$"#, options: .regularExpression) != nil { return .legacy }
        }
        if device.isRNDIS, device.deviceClass == 224 { return .rndis }
        return .unsupported
    }
    static func single(_ devices: [RecoveryProbeUSBDevice]) -> RecoveryProbeUSBDevice? {
        guard devices.count == 1, let device = devices.first, kind(of: device) != .unsupported else { return nil }
        return device
    }
}

enum LegacyConsoleIdentity {
    static let command = #"set -e; board=$(cat /etc/clover/boardtype); region=$(cat /etc/clover/REGION); printf 'SWIFTHAKCHI_CONSOLE_ID_V1\nBOARD=%s\nREGION=%s\nEND\n' "$board" "$region""#
    static func parse(_ data: Data) throws -> ConsoleType {
        guard data.count <= 1024, let text = String(data: data, encoding: .ascii) else { throw LegacyInspectionError.invalidReport }
        let lines = text.components(separatedBy: "\n")
        guard lines.count == 5, lines[0] == "SWIFTHAKCHI_CONSOLE_ID_V1", lines[1].hasPrefix("BOARD="),
              lines[2].hasPrefix("REGION="), lines[3] == "END", lines[4].isEmpty else { throw LegacyInspectionError.invalidReport }
        let board = String(lines[1].dropFirst(6)), region = String(lines[2].dropFirst(7))
        switch (board, region) {
        case ("dp-nes", "EUR_USA"), ("dp-hvc", "EUR_USA"): return .nes
        case ("dp-nes", "JPN"), ("dp-hvc", "JPN"): return .famicom
        case ("dp-shvc", "USA"): return .snesUsa
        case ("dp-shvc", "EUR"): return .snesEur
        case ("dp-shvc", "JPN"): return .superFamicom
        default: throw LegacyInspectionError.invalidReport
        }
    }
}

struct ConnectedConsoleInfo: Sendable {
    let consoleType: ConsoleType
    var uniqueID = ""
    var bootVersion = ""
    var kernelVersion = ""
    var scriptVersion = ""
    var customFirmwareLoaded = false
    var canInteract = false
    var canSync = false
    var shell: SSHService?
    var legacy: LegacyInspectionClient?
    var nativeSNES: SNESLibraryConnectionSession?
    var nativeSNESContext: SNESLibraryContext?
    var legacyReport: LegacyConsoleReport?
    func close() async { await shell?.disconnect(); await legacy?.disconnect(); await nativeSNES?.disconnect() }
}

enum ConsoleRuntimeConnection {
    static func connect(_ attachment: RecoveryProbeUSBDevice,
                        makeLegacyClient: @Sendable () -> LegacyInspectionClient,
                        workspace: WorkspacePaths? = nil, sessionID: UUID = UUID(),
                        progress: ConsoleConnectionProgressSink = { _ in }) async throws -> ConnectedConsoleInfo {
        if ConsoleAttachmentPolicy.kind(of: attachment) != .nativeSNES { await progress(.openingUSB) }
        switch ConsoleAttachmentPolicy.kind(of: attachment) {
        case .legacy: return try await legacy(makeLegacyClient: makeLegacyClient)
        case .rndis:
            let shell = SSHService()
            do {
                try await shell.connect(expected: attachment)
                let probe = try await inspect(shell: shell)
                try Task.checkCancellation()
                return probe
            } catch { await shell.disconnect(); throw error }
        case .nativeSNES:
            guard let workspace else { throw SNESLibraryInstallation.failure() }
            let connection = try await NativeSNESLibraryIO.connect(attachment: attachment, sessionID: sessionID,
                workspace: workspace, progress: progress)
            var info = ConnectedConsoleInfo(consoleType: .snesUsa)
            info.nativeSNES = connection.session; info.nativeSNESContext = connection.context
            info.uniqueID = connection.context.installation.expected.hwid
            info.customFirmwareLoaded = true; info.kernelVersion = "3.4.113"
            return info
        case .recovery, .unsupported: throw FELError.deviceNotFound
        }
    }
    static func legacy(makeLegacyClient: @Sendable () -> LegacyInspectionClient) async throws -> ConnectedConsoleInfo {
        let client = makeLegacyClient()
        do {
            try await client.connect()
            let response = try await client.execute(.consoleIdentity)
            guard response.succeeded else { throw LegacyInspectionError.invalidReport }
            let type = try LegacyConsoleIdentity.parse(response.stdoutData)
            var info = ConnectedConsoleInfo(consoleType: type)
            info.legacy = client; info.customFirmwareLoaded = true
            info.uniqueID = try await LegacyDeviceIdentity.read(client: client)
            if type == .nes {
                let report = try await LegacyConsoleService.inspect(client: client)
                info.legacyReport = report; info.bootVersion = report.bootVersion
                info.kernelVersion = report.kernelVersion; info.scriptVersion = report.scriptVersion
            }
            try Task.checkCancellation()
            return info
        } catch { await client.disconnect(); throw error }
    }
    static func inspect(shell: SSHService) async throws -> ConnectedConsoleInfo {
        let system = try await shell.execute("cat /etc/clover/system_code 2>/dev/null")
        var type = system.succeeded ? ConsoleType.fromSystemCode(system.output) : .unknown
        if type == .unknown {
            let identity = try await shell.execute(LegacyConsoleIdentity.command)
            if identity.succeeded { type = (try? LegacyConsoleIdentity.parse(identity.stdoutData)) ?? .unknown }
        }
        let versions = try await shell.execute("cat /var/version 2>/dev/null")
        func value(_ key: String) -> String {
            let lines = versions.stdout.split(separator: "\n").filter { $0.hasPrefix(key + "=") }
            guard lines.count == 1 else { return "" }
            return String(lines[0].dropFirst(key.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        }
        if type == .unknown { type = ConsoleType.fromSystemCode(value("sftype") + "-" + value("sfregion")) }
        var info = ConnectedConsoleInfo(consoleType: type)
        info.shell = shell; info.bootVersion = value("bootVersion")
        info.kernelVersion = value("kernelVersion"); info.scriptVersion = value("hakchiVersion")
        let uid = try await shell.execute("cat /etc/clover/uid 2>/dev/null")
        info.uniqueID = uid.succeeded ? uid.output : ""
        let firmware = try await shell.execute("test -d /var/lib/hakchi")
        info.customFirmwareLoaded = firmware.succeeded
        info.canInteract = VersionTuple.parse(info.bootVersion) >= VersionTuple(1, 0, 2)
            && VersionTuple.parse(info.kernelVersion) >= VersionTuple(3, 4, 113)
            && VersionTuple.parse(info.scriptVersion) >= VersionTuple(1, 0, 4, 118)
        info.canSync = info.canInteract && type.isNES
        return info
    }
}
