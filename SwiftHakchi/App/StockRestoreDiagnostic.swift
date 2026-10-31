import Foundation
import SwiftHakchiCore

enum StockRestoreDiagnosticOptions: Equatable, Sendable {
    case prepare(String,String,String), inspect(String,String), preflight(String,String), write(String,String), confirm(String,String)
    static func parseIfPresent(_ arguments: [String]) throws -> Self? {
        let names = ["--prepare-stock-restore","--inspect-stock-restore","--preflight-stock-restore","--write-stock-boot2","--confirm-stock-menu"]
        guard let first = arguments.first, names.contains(first) else { return nil }
        func fail() -> RecoveryProbeError { .refused("Stock restore usage: --prepare-stock-restore /snapshot /stock.img /existing/Journals, or --inspect-stock-restore|--preflight-stock-restore|--write-stock-boot2|--confirm-stock-menu /operation REVIEW_SHA256. No write follows preflight automatically.") }
        func path(_ value: String) -> Bool { value.hasPrefix("/") && !value.contains("\0") }
        if first == names[0] {
            guard arguments.count == 4, arguments.dropFirst().allSatisfy(path) else { throw fail() }
            return .prepare(arguments[1],arguments[2],arguments[3])
        }
        guard arguments.count == 3, path(arguments[1]), arguments[2].count == 64, StockRestoreMaterial.hex(arguments[2]) else { throw fail() }
        switch first {
        case names[1]: return .inspect(arguments[1],arguments[2])
        case names[2]: return .preflight(arguments[1],arguments[2])
        case names[3]: return .write(arguments[1],arguments[2])
        default: return .confirm(arguments[1],arguments[2])
        }
    }
}
enum StockRestoreDiagnostic {
    static func run(mode: StockRestoreDiagnosticOptions,
                    loadInputs: @Sendable () async throws -> RecoveryBootInputs,
                    makeIO: @Sendable () -> any StockRestoreIO, progress: @escaping RecoveryProgressSink = { _ in }) async throws -> String {
        await progress(.checkingMaterial)
        if case .prepare(let snapshot, let stock, let root) = mode {
            try RecoveryFirmwareJournalPolicy.require(URL(fileURLWithPath: root))
            let journalRoot = try RecoveryFirmwareJournalPolicy.ensureRoot()
            let material = try StockRestoreMaterial.load(snapshot: URL(fileURLWithPath:snapshot), stock:URL(fileURLWithPath:stock))
            let prepared = try StockRestoreJournal.prepare(material:material,root:journalRoot)
            return try output(operation:prepared.operation.path,review:prepared.reviewSHA256,phase:.prepared,material:material,USBOpened:false)
        }
        let path: String, review: String
        switch mode {
        case .inspect(let p,let s),.preflight(let p,let s),.write(let p,let s),.confirm(let p,let s): path=p;review=s
        case .prepare: throw RestoreDirectory.failure()
        }
        let journal = try StockRestoreJournal(operation:URL(fileURLWithPath:path),reviewSHA256:review)
        do {
            let material = try await journal.verifiedMaterial()
            var USBOpened = false
            switch mode {
            case .inspect: break
            case .confirm: try await journal.append(.menuAccepted)
            case .preflight,.write:
                try RecoveryFirmwareJournalPolicy.require(URL(fileURLWithPath:path).deletingLastPathComponent())
                let transactionMode: StockKernelRestore.Mode
                if case .write = mode { transactionMode = .write } else { transactionMode = .preflight }
                let expected: StockRestoreJournal.Phase = transactionMode == .write ? .preflightVerified : .prepared
                guard try await journal.phase() == expected else { throw RecoveryProbeError.refused("Journal phase does not allow this hardware operation. No retry was dispatched.") }
                // Freeze/verify all host state before constructing any native transport.
                let inputs = try await loadInputs()
                _ = try inputs.prepare()
                try await RecoveryProbeUSBRegistry.requireOrdinaryAppClosed()
                try await StockKernelRestore().run(journal:journal,inputs:inputs,io:makeIO(),mode:transactionMode,progress:progress)
                USBOpened = true
            case .prepare: throw RestoreDirectory.failure()
            }
            let rendered = try output(operation:path,review:review,phase:await journal.phase(),material:material,USBOpened:USBOpened)
            try await journal.close()
            return rendered
        } catch {
            try? await journal.close()
            throw error
        }
    }
    private static func output(operation: String, review: String, phase: StockRestoreJournal.Phase,
                               material: StockRestoreMaterial, USBOpened: Bool) throws -> String {
        let data: [String:Any] = ["operationDirectory":operation,"reviewSHA256":review,"phase":phase.rawValue,
            "scope":material.plan.scope,"stockBytes":material.stock.count,"stockSHA256":material.plan.stockSHA256,
            "preimageBytes":material.preimage.count,"preimageSHA256":material.plan.preimageSHA256,
            "USBOpened":USBOpened,"boot2ReadbackVerified":[StockRestoreJournal.Phase.readbackVerified,.menuAccepted].contains(phase),
            "humanMenuAccepted":phase == .menuAccepted,"fullFactoryResetPerformed":false]
        return String(decoding:try JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self)
    }
    static func failureMessage(writeRequested: Bool, error: any Error) -> String {
        if writeRequested {
            return "Stock restore stopped: \(error.localizedDescription)\nA write may have been dispatched. Preserve power, cables and the operation journal; do not retry or reboot. Inspect the journal before any further action.\n"
        }
        return "Recovery diagnostic stopped: \(error.localizedDescription)\nIf a RAM boot request was sent, its outcome may be uncertain. It was not retried. No flash or reset command was invoked.\n"
    }
}
