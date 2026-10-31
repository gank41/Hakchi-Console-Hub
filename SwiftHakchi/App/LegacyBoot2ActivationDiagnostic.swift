import Foundation
import SwiftHakchiCore

enum LegacyBoot2ActivationDiagnosticOptions: Equatable, Sendable {
    case prepare(String, String, String)
    case inspect(String, String), preflight(String, String), write(String, String), confirm(String, String)

    static func parseIfPresent(_ arguments: [String]) throws -> Self? {
        let names = ["--prepare-legacy-boot2", "--inspect-legacy-boot2", "--preflight-legacy-boot2",
                     "--write-legacy-boot2", "--confirm-legacy-menu"]
        guard let first = arguments.first, names.contains(first) else { return nil }
        func fail() -> RecoveryProbeError {
            .refused("Legacy activation usage: --prepare-legacy-boot2 /snapshot /stock.img /existing/Journals, or --inspect-legacy-boot2|--preflight-legacy-boot2|--write-legacy-boot2|--confirm-legacy-menu /operation REVIEW_SHA256. No write follows preflight automatically.")
        }
        func path(_ value: String) -> Bool { value.hasPrefix("/") && !value.contains("\0") }
        if first == names[0] {
            guard arguments.count == 4, arguments.dropFirst().allSatisfy(path) else { throw fail() }
            return .prepare(arguments[1], arguments[2], arguments[3])
        }
        guard arguments.count == 3, path(arguments[1]), arguments[2].count == 64,
              StockRestoreMaterial.hex(arguments[2]) else { throw fail() }
        switch first {
        case names[1]: return .inspect(arguments[1], arguments[2])
        case names[2]: return .preflight(arguments[1], arguments[2])
        case names[3]: return .write(arguments[1], arguments[2])
        default: return .confirm(arguments[1], arguments[2])
        }
    }
}

enum LegacyBoot2ActivationDiagnostic {
    static func run(mode: LegacyBoot2ActivationDiagnosticOptions,
                    loadInputs: @Sendable () async throws -> RecoveryBootInputs,
                    makeIO: @Sendable () -> any LegacyBoot2ActivationIO,
                    progress: @escaping RecoveryProgressSink = { _ in }) async throws -> String {
        await progress(.checkingMaterial)
        if case .prepare(let snapshot, let stock, let root) = mode {
            try RecoveryFirmwareJournalPolicy.require(URL(fileURLWithPath: root))
            let journalRoot = try RecoveryFirmwareJournalPolicy.ensureRoot()
            let material = try LegacyBoot2ActivationMaterial.load(
                snapshot: URL(fileURLWithPath: snapshot), stock: URL(fileURLWithPath: stock))
            let prepared = try LegacyBoot2ActivationJournal.prepare(material: material, root: journalRoot)
            return try output(operation: prepared.operation.path, review: prepared.reviewSHA256,
                              phase: .prepared, material: material, usbOpened: false)
        }
        let path: String, review: String
        switch mode {
        case .inspect(let p, let s), .preflight(let p, let s), .write(let p, let s), .confirm(let p, let s):
            path = p; review = s
        case .prepare: throw RestoreDirectory.failure()
        }
        let journal = try LegacyBoot2ActivationJournal(operation: URL(fileURLWithPath: path), reviewSHA256: review)
        do {
            let material = try await journal.verifiedMaterial()
            var usbOpened = false
            switch mode {
            case .inspect: break
            case .confirm: try await journal.append(.menuAccepted)
            case .preflight, .write:
                try RecoveryFirmwareJournalPolicy.require(URL(fileURLWithPath: path).deletingLastPathComponent())
                let transactionMode: LegacyBoot2Activation.Mode
                if case .write = mode { transactionMode = .write } else { transactionMode = .preflight }
                let expected: LegacyBoot2ActivationJournal.Phase = transactionMode == .write ? .preflightVerified : .prepared
                guard try await journal.phase() == expected else {
                    throw RecoveryProbeError.refused("Journal phase does not allow this legacy activation operation. No retry was dispatched.")
                }
                let inputs = try await loadInputs()
                _ = try inputs.prepare()
                try await RecoveryProbeUSBRegistry.requireOrdinaryAppClosed()
                try await LegacyBoot2Activation().run(journal: journal, inputs: inputs, io: makeIO(),
                                                      mode: transactionMode, progress: progress)
                usbOpened = true
            case .prepare: throw RestoreDirectory.failure()
            }
            let rendered = try output(operation: path, review: review, phase: await journal.phase(),
                                      material: material, usbOpened: usbOpened)
            try await journal.close()
            return rendered
        } catch {
            try? await journal.close()
            throw error
        }
    }

    private static func output(operation: String, review: String,
                               phase: LegacyBoot2ActivationJournal.Phase,
                               material: LegacyBoot2ActivationMaterial, usbOpened: Bool) throws -> String {
        let values: [String: Any] = [
            "operationDirectory": operation, "reviewSHA256": review, "phase": phase.rawValue,
            "scope": material.plan.scope, "stockBytes": material.stock.count,
            "stockSHA256": material.plan.stockSHA256, "legacyBytes": material.legacy.count,
            "legacySHA256": material.plan.legacySHA256, "USBOpened": usbOpened,
            "boot2ReadbackVerified": [.readbackVerified, .menuAccepted].contains(phase),
            "humanMenuAccepted": phase == .menuAccepted, "modernInstallerPerformed": false,
            "gamesChanged": false]
        return String(decoding: try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }

    static func failureMessage(writeRequested: Bool, error: any Error) -> String {
        if writeRequested {
            return "Legacy activation stopped: \(error.localizedDescription)\nA write may have been dispatched. Preserve power, cables and the operation journal; do not retry or reboot.\n"
        }
        return "Legacy activation diagnostic stopped: \(error.localizedDescription)\nNo flash command was invoked by this request. If recovery RAM was started, disconnect only after reviewing the failed stage.\n"
    }
}
