import Foundation
import USBBridge
import SwiftHakchiCore

/// Only exact audited raw inputs can become a prepared recovery boot.
/// These immutable copies are complete before the service opens any USB handle.
struct PreparedRecoveryBoot: Sendable {
    let fes1: Data
    let uboot: Data
    let bootImage: Data

    init(fes1: Data, uboot: Data, bootImage: Data) throws {
        try RecoveryPayloadValidator.validateBootInputs(fes1: fes1, uboot: uboot, bootImage: bootImage)
        self.fes1 = fes1
        self.uboot = try RecoveryBootPatcher.bootCommand(in: uboot, transferAddress: UInt32(TRANSFER_BASE_M))
        self.bootImage = try RecoveryBootPatcher.commandLine(in: bootImage)
    }
}

/// Pure bounded edits; helper structure checks alone do not recognize stock or grant boot eligibility.
enum RecoveryBootPatcher {
    static func commandLine(in data: Data) throws -> Data {
        _ = try LegacyAndroidBootImage(data: data)
        var bytes = Array(data)
        let window = Array(bytes[64..<576])
        guard let terminator = window.firstIndex(of: 0),
              window[..<terminator].allSatisfy({ $0 >= 32 && $0 <= 126 }) else {
            throw RecoveryImageError.invalid("Recovery command line must be NUL-terminated ASCII without control characters.")
        }
        let original = String(decoding: window[..<terminator], as: UTF8.self)
        let tokens = original.split(separator: " ").map(String.init).filter { !$0.hasPrefix("hakchi-") }
        // The pinned recovery script uses substring grep, not token parsing.
        guard !tokens.contains(where: { $0.contains("hakchi-") }) else {
            throw RecoveryImageError.invalid("An embedded hakchi flag could activate recovery behavior; no image was prepared.")
        }
        let command = (tokens + ["hakchi-shell", "hakchi-memboot"]).joined(separator: " ")
        let patch = Array(command.utf8)
        guard patch.count < 512 else { throw RecoveryImageError.invalid("Recovery command line exceeds its 511-byte capacity; no truncated image was prepared.") }
        bytes.replaceSubrange(64..<576, with: patch + Array(repeating: 0, count: 512 - patch.count))
        return Data(bytes)
    }

    static func bootCommand(in data: Data, transferAddress: UInt32) throws -> Data {
        let slot = try RecoveryPayloadValidator.bootCommandRange(in: data)
        let command = Array(("boota " + String(transferAddress, radix: 16)).utf8)
        guard command.count <= slot.count else { throw RecoveryImageError.invalid("U-Boot bootcmd has insufficient capacity.") }
        var bytes = Array(data)
        // Retain the original NUL and all adjacent environment entries. Interior NULs
        // would terminate the embedded environment early; spaces preserve its layout.
        bytes.replaceSubrange(slot, with: command + Array(repeating: 32, count: slot.count - command.count))
        return Data(bytes)
    }
}
