import Foundation
import SwiftHakchiCore

struct SNESAlienTrialDiagnosticOptions: Equatable, Sendable {
    let paths: [String], nonce: UUID, approvedImageSHA256: String?, powerTrial: Bool, resetTrial: Bool, sramTrial: Bool
    static func parse(_ args: [String]) throws -> Self? {
        guard let action = args.first, ["--preview-alien3-trial", "--test-alien3-trial", "--preview-alien3-power-trial", "--test-alien3-power-trial", "--preview-alien3-reset-trial", "--test-alien3-reset-trial", "--preview-simcity-sram-trial", "--test-simcity-sram-trial"].contains(action) else { return nil }
        let test = action.hasPrefix("--test-")
        let powerTrial = action.contains("-power-trial")
        let resetTrial = action.contains("-reset-trial")
        let sramTrial = action.contains("-sram-trial")
        guard args.count == (test ? 12 : 11),
              args[1...9].allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4096 }),
              let nonce = UUID(uuidString: args[10]), nonce.uuidString == args[10] else { throw SNESRuntimeBinding.failure() }
        if test {
            let hash = args[11]
            guard hash.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw SNESRuntimeBinding.failure() }
        }
        return .init(paths: Array(args[1...9]), nonce: nonce, approvedImageSHA256: test ? args[11] : nil, powerTrial: powerTrial, resetTrial: resetTrial, sramTrial: sramTrial)
    }
}

enum SNESAlienTrialDiagnostic {
    static func runIfPresent(_ args: [String],
        loadInputs: @Sendable () async throws -> RecoveryBootInputs = { try PayloadService.shared.pinnedRecoveryInputs() },
        checkHost: @Sendable () async throws -> Void = { try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed() },
        makeIO: @Sendable (PreparedSNESAlienTrial) -> any SNESAlienTrialIO = { NativeSNESAlienTrialIO(trial: $0) }) async throws -> String? {
        guard let options = try SNESAlienTrialDiagnosticOptions.parse(args) else { return nil }
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
        let game = options.sramTrial ? "simcity.smc" : "alien3.smc"
        let owner = options.sramTrial ? ["trial-sram-owner"] : (options.resetTrial ? ["trial-reset-owner"] : (options.powerTrial ? ["trial-owner"] : []))
        let names = ["retroarch", "snes9x2010_libretro.so", game, "retroarch.cfg", "trial-start"] + owner
        var payload: [String: Data] = [:]
        for name in names { payload[name] = try root.read(name, maximum: 8 * 1024 * 1024) }
        payload["autoconfig/Nintendo Clovercon - controller1.cfg"] = try controller.read("Nintendo Clovercon - controller1.cfg", maximum: 65536)
        let report = try read(p[7], maximum: 65536)
        let store = try RecoveryBootSnapshotStore(root: p[8])
        let base = try SNESOriginalMenuRecipe.prepare(material: material, archivedImage: archive, recovery: await loadInputs(), nonce: options.nonce)
        let trial = try PreparedSNESAlienTrial(base: base, payload: payload, report: report)
        let hash = BackupManifest.digest(trial.image)
        var response: [String: Any] = ["imageSHA256": hash, "imageBytes": trial.image.count, "nonce": options.nonce.uuidString,
            "firmwareWritten": false, "gameplayConfirmed": false, "saveMode": "temporary RAM only"]
        if let approved = options.approvedImageSHA256 {
            guard approved == hash else { throw RecoveryProbeError.refused("The temporary test files changed since the preview. No test was started.") }
            try await checkHost()
            let result: SNESAlienTrialResult
            do { result = try await SNESAlienTrialService().start(trial: trial, store: store, io: makeIO(trial)) }
            catch let failure as SNESAlienTrialFailure {
                let directory = try await store.saveSNESAlienTrialFailure(failure, trial: trial)
                throw SNESPreparationDiagnosticSavedError(directory: directory)
            }
            response["checkpointDirectory"] = result.checkpointDirectory.path
            response["status"] = "emulator process running; gameplay is not yet verified"
        } else {
            response["status"] = "prepared on Mac only; no console was started"
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }
}
