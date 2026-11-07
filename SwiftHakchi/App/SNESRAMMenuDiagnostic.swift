import Foundation
import SwiftHakchiCore

/// Explicitly separate from the shipping sync and firmware workflows.
struct SNESRAMMenuDiagnosticOptions: Equatable, Sendable {
    let paths: [String], nonce: UUID, approvedImageSHA256: String?, resetTrial: Bool, signalTrial: Bool, sramMenuTrial: Bool, dkc3MenuTrial: Bool, zeldaMenuTrial: Bool
    static func parse(_ args: [String]) throws -> Self? {
        guard let action = args.first, ["--preview-alien3-menu-trial", "--test-alien3-menu-trial", "--preview-alien3-menu-reset-trial", "--test-alien3-menu-reset-trial", "--preview-alien3-menu-signal-trial", "--test-alien3-menu-signal-trial", "--preview-simcity-menu-sram-trial", "--test-simcity-menu-sram-trial", "--preview-dkc3-menu-sram-trial", "--test-dkc3-menu-sram-trial", "--preview-zelda-menu-sram-trial", "--test-zelda-menu-sram-trial"].contains(action) else { return nil }
        let test = action.hasPrefix("--test-")
        let resetTrial = action.contains("-reset-trial")
        let signalTrial = action.contains("-signal-trial")
        let sramMenuTrial = action.contains("-sram-trial")
        let dkc3MenuTrial = action.contains("-dkc3-")
        let zeldaMenuTrial = action.contains("-zelda-")
        let pathCount = (dkc3MenuTrial || zeldaMenuTrial) ? 19 : (sramMenuTrial ? 15 : (signalTrial ? 12 : (resetTrial ? 11 : 10)))
        let nonceIndex = pathCount + 1
        guard args.count == nonceIndex + (test ? 2 : 1),
              args[1...pathCount].allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4096 }),
              let nonce = UUID(uuidString: args[nonceIndex]), nonce.uuidString == args[nonceIndex] else { throw SNESRuntimeBinding.failure() }
        if test {
            let hash = args[nonceIndex + 1]
            guard hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw SNESRuntimeBinding.failure() }
        }
        return .init(paths: Array(args[1...pathCount]), nonce: nonce, approvedImageSHA256: test ? args[nonceIndex + 1] : nil, resetTrial: resetTrial, signalTrial: signalTrial, sramMenuTrial: sramMenuTrial, dkc3MenuTrial: dkc3MenuTrial, zeldaMenuTrial: zeldaMenuTrial)
    }
}

enum SNESRAMMenuDiagnostic {
    static func runIfPresent(_ args: [String],
        loadInputs: @Sendable () async throws -> RecoveryBootInputs = { try PayloadService.shared.pinnedRecoveryInputs() },
        checkHost: @Sendable () async throws -> Void = { try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed() },
        makeIO: @Sendable (PreparedSNESOriginalMenu) -> any SNESOriginalMenuIO = { NativeSNESOriginalMenuIO(menu: $0) }) async throws -> String? {
        guard let options = try SNESRAMMenuDiagnosticOptions.parse(args) else { return nil }
        try Task.checkCancellation()
        let p = options.paths.map { URL(fileURLWithPath: $0) }
        let setup = try SNESOfflineSource.load(snapshot: p[0])
        let source = try SNESMenuSupportSource.load(setup: setup, preparation: p[1])
        let support = try SNESMenuSupportMaterial.load(source: source, directory: p[2])
        let components = try SNESOriginalComponentMaterial.load(source: SNESOriginalComponentSource(material: support), directory: p[3])
        let runtime = try SNESRuntimeMaterial.load(directory: p[4], source: setup)
        let material = try SNESOriginalMenuMaterial(components: components, runtime: runtime)
        func read(_ url: URL, maximum: Int) throws -> Data {
            try RestoreDirectory(url.deletingLastPathComponent()).read(url.lastPathComponent, maximum: maximum)
        }
        let archive = try read(p[5], maximum: LegacyAndroidBootImage.maximumSize)
        let root = try RestoreDirectory(p[6]), controller = try RestoreDirectory(p[6].appendingPathComponent("autoconfig"))
        let names = ["retroarch", "snes9x2010_libretro.so", "alien3.smc", "retroarch.cfg", "trial-start", "trial-owner"]
        var payload: [String: Data] = [:]
        for name in names { payload[name] = try root.read(name, maximum: 8 * 1024 * 1024) }
        payload["autoconfig/Nintendo Clovercon - controller1.cfg"] = try controller.read("Nintendo Clovercon - controller1.cfg", maximum: 65536)
        let report = try read(p[7], maximum: 65536), art = try read(p[9], maximum: 262144)
        let store = try RecoveryBootSnapshotStore(root: p[8])
        let base = try SNESOriginalMenuRecipe.prepare(material: material, archivedImage: archive, recovery: await loadInputs(), nonce: options.nonce)
        let candidate: SNESRAMCompatibilityMenuBuilder.Result
        if options.sramMenuTrial {
            let resetOwner = try read(p[10], maximum: 2 * 1024 * 1024)
            let signalOwner = try read(p[11], maximum: 2 * 1024 * 1024)
            let saveRoot = try RestoreDirectory(p[12]), saveController = try RestoreDirectory(p[12].appendingPathComponent("autoconfig"))
            let saveNames = ["retroarch", "snes9x2010_libretro.so", "simcity.smc", "retroarch.cfg", "trial-start", "trial-sram-owner"]
            var savePayload: [String: Data] = [:]
            for name in saveNames { savePayload[name] = try saveRoot.read(name, maximum: 8 * 1024 * 1024) }
            savePayload["autoconfig/Nintendo Clovercon - controller1.cfg"] = try saveController.read("Nintendo Clovercon - controller1.cfg", maximum: 65536)
            let saveReport = try read(p[13], maximum: 65536), saveOwner = try read(p[14], maximum: 2 * 1024 * 1024)
            if options.zeldaMenuTrial {
                candidate = try SNESRAMMenuZeldaTrialBuilder.build(source: base.image, alienPayload: payload, alienReport: report,
                    artwork: art, resetOwner: resetOwner, signalOwner: signalOwner, savePayload: savePayload,
                    saveReport: saveReport, saveMenuOwner: saveOwner, rom: read(p[15], maximum: 8 * 1024 * 1024),
                    config: read(p[16], maximum: 65536), owner: read(p[17], maximum: 2 * 1024 * 1024),
                    reentry: read(p[18], maximum: 65536))
            } else if options.dkc3MenuTrial {
                candidate = try SNESRAMMenuDKC3TrialBuilder.build(source: base.image, alienPayload: payload, alienReport: report,
                    artwork: art, resetOwner: resetOwner, signalOwner: signalOwner, savePayload: savePayload,
                    saveReport: saveReport, saveMenuOwner: saveOwner, rom: read(p[15], maximum: 8 * 1024 * 1024),
                    config: read(p[16], maximum: 65536), owner: read(p[17], maximum: 2 * 1024 * 1024),
                    reentry: read(p[18], maximum: 65536))
            } else {
                candidate = try SNESRAMMenuSRAMTrialBuilder.build(source: base.image, alienPayload: payload, alienReport: report,
                    artwork: art, resetOwner: resetOwner, signalOwner: signalOwner, savePayload: savePayload,
                    saveReport: saveReport, saveMenuOwner: saveOwner)
            }
        } else if options.signalTrial {
            let resetOwner = try read(p[10], maximum: 2 * 1024 * 1024)
            let signalOwner = try read(p[11], maximum: 2 * 1024 * 1024)
            candidate = try SNESRAMMenuSignalTrialBuilder.build(source: base.image, payload: payload, report: report, artwork: art, resetOwner: resetOwner, signalOwner: signalOwner)
        } else if options.resetTrial {
            let owner = try read(p[10], maximum: 2 * 1024 * 1024)
            candidate = try SNESRAMMenuResetTrialBuilder.build(source: base.image, payload: payload, report: report, artwork: art, owner: owner)
        } else {
            candidate = try SNESRAMCompatibilityMenuBuilder.build(source: base.image, payload: payload, report: report, artwork: art)
        }
        let menu = try PreparedSNESOriginalMenu(temporaryCompatibilityTrial: candidate, basedOn: base)
        let hash = BackupManifest.digest(menu.image)
        var response: [String: Any] = ["imageSHA256": hash, "imageBytes": menu.image.count, "nonce": options.nonce.uuidString,
            "firmwareWritten": false, "gameplayConfirmed": false, "saveMode": "temporary RAM only",
            "transitionSupport": options.sramMenuTrial ? "experimental RAM save verification and RESET handoff; in-game power-off is unverified" : ((options.resetTrial || options.signalTrial) ? "experimental RESET handoff; power-off during gameplay is unverified" : "unverified; do not use RESET during the game")]
        if let approved = options.approvedImageSHA256 {
            guard approved == hash else { throw RecoveryProbeError.refused("The temporary test files changed since the preview. No test was started.") }
            try await checkHost(); try menu.validateCurrent()
            do {
                let result = try await SNESOriginalMenuService().start(menu: menu, store: store, io: makeIO(menu), progress: { _ in })
                let directory = try await store.saveSNESOriginalMenuResult(result, menu: menu)
                response["checkpointDirectory"] = result.checkpointDirectory.path
                response["resultDirectory"] = directory.path
                response["status"] = "Temporary menu started; the menu entry and gameplay are not yet verified."
            } catch let failure as SNESOriginalMenuFailure {
                let directory = try await store.saveSNESOriginalMenuFailure(failure, menu: menu)
                throw SNESPreparationDiagnosticSavedError(directory: directory)
            }
        } else {
            response["status"] = "Prepared on this Mac only; no console was started."
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }
}
