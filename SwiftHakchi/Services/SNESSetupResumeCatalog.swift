import Foundation
import SwiftHakchiCore

/// Reconstructs a saved chain on the Mac. Manifest references are only search
/// hints; each candidate must pass the same checks as a newly captured result.
enum SNESSetupResumeCatalog {
    struct Resolution: Sendable {
        let evidence: SNESSetupResumeEvidence
        let unverifiedCount: Int
    }
    struct Choice: Identifiable, Sendable {
        let backup: URL
        let savedDate: Date?
        let consoleFingerprint: String
        let manifestSHA256: String
        var id: String { backup.lastPathComponent }
    }

    private static func candidates(_ root: RestoreDirectory, prefix: String) throws -> [URL] {
        let names = try root.names().filter {
            $0.hasPrefix(prefix) && UUID(uuidString: String($0.dropFirst(prefix.count))) != nil
        }.sorted()
        return names.map { root.url.appendingPathComponent($0, isDirectory: true) }
    }

    static func list(root: URL) throws -> [Choice] {
        let dir = try RestoreDirectory(root)
        var result: [Choice] = []
        for url in try candidates(dir, prefix: "SNES-US-Setup-") {
            try Task.checkCancellation()
            do {
                let source = try SNESOfflineSource.load(snapshot: url)
                _ = try SNESPreparationSource.load(source)
                let date = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
                let fingerprint = String(BackupManifest.digest(Data(source.expectedHWID.lowercased().utf8)).prefix(8)).uppercased()
                result.append(Choice(backup: url, savedDate: date, consoleFingerprint: fingerprint, manifestSHA256: source.manifestSHA256))
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
            }
        }
        try dir.check()
        return result
    }

    static func resolve(root: URL, backup: URL, expectedManifest: String? = nil) async throws -> Resolution {
        let dir = try RestoreDirectory(root)
        guard dir.url.path == root.path, backup.deletingLastPathComponent().path == dir.url.path,
              backup.path == backup.standardizedFileURL.path else { throw SNESOfflineSource.failure() }
        let source = try SNESOfflineSource.load(snapshot: backup)
        if let expectedManifest, source.manifestSHA256 != expectedManifest { throw SNESOfflineSource.failure() }
        let preparation = try SNESPreparationSource.load(source)
        let originalBackup = try SNESRecoveryMaterial.load(setup: backup)
        let store = try RecoveryBootSnapshotStore(root: dir.url)
        var failures = 0
        func manifest(_ url: URL) throws -> [String: Any] {
            let candidate = try RestoreDirectory(url)
            let raw = try candidate.read("manifest.json", maximum: 65536)
            guard let value = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw SNESOfflineSource.failure() }
            try candidate.check()
            return value
        }
        func belongs(_ object: [String: Any]) -> Bool {
            guard let binding = object["binding"] as? [String: Any] else { return false }
            return binding["sourceSnapshot"] as? String == source.snapshotName && binding["setupManifestSHA256"] as? String == source.manifestSHA256
        }
        func failed(_ error: Error) throws {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            failures += 1
        }
        var recovery: URL?
        for url in try candidates(dir, prefix: "SNES-Recovery-Material-") {
            try Task.checkCancellation()
            do {
                let item = try SNESRecoveryMaterial.loadPackage(directory: url)
                guard item.expectedHWID == source.expectedHWID.lowercased(), item.stock == source.stock,
                      item.partitions == preparation.partitions else { continue }
                guard try item.matchesExactSource(originalBackup) else { continue }
                recovery = url; break
            } catch { try failed(error) }
        }
        var helpers: URL?
        for url in try candidates(dir, prefix: "SNES-Setup-Helpers-") {
            try Task.checkCancellation()
            do { _ = try SNESPortableHelperPackage.load(directory: url); helpers = url; break }
            catch { try failed(error) }
        }
        var startups: [SNESMenuSupportSource] = []
        for url in try candidates(dir, prefix: "SNES-Recovery-Preparation-") {
            try Task.checkCancellation()
            do {
                guard belongs(try manifest(url)) else { continue }
                startups.append(try SNESMenuSupportSource.load(setup: source, preparation: url))
            } catch { try failed(error) }
        }
        var supports: [SNESMenuSupportMaterial] = []
        for url in try candidates(dir, prefix: "SNES-Menu-Support-") {
            try Task.checkCancellation()
            do {
                let object = try manifest(url)
                guard belongs(object), let name = object["preparation"] as? String,
                      let startup = startups.first(where: { $0.directoryURL.lastPathComponent == name }) else { continue }
                supports.append(try SNESMenuSupportMaterial.load(source: startup, directory: url))
            } catch { try failed(error) }
        }
        var component: SNESOriginalComponentMaterial?
        for url in try candidates(dir, prefix: "SNES-Original-Components-") {
            try Task.checkCancellation()
            do {
                let object = try manifest(url)
                guard belongs(object), let name = object["support"] as? String,
                      let support = supports.first(where: { $0.directoryURL.lastPathComponent == name }) else { continue }
                component = try SNESOriginalComponentMaterial.load(source: SNESOriginalComponentSource(material: support), directory: url)
                break
            } catch { try failed(error) }
        }
        try dir.check(); try Task.checkCancellation()
        try source.revalidate()
        if recovery == nil { recovery = try await store.saveSNESRecoveryMaterial(originalBackup) }
        try source.revalidate()
        if helpers == nil { helpers = try await store.saveSNESPortableHelpers() }
        try source.revalidate()
        guard let recovery, let helpers else { throw SNESOfflineSource.failure() }
        let selectedSupport = component?.source.material ?? supports.first
        let selectedStartup = selectedSupport?.source ?? startups.first
        let evidence = try SNESSetupResumeEvidence.load(root: dir.url, backup: backup, recovery: recovery, helpers: helpers,
            startup: selectedStartup?.directoryURL, support: selectedSupport?.directoryURL, components: component?.directoryURL)
        try evidence.revalidate(); try dir.check()
        return Resolution(evidence: evidence, unverifiedCount: failures)
    }
}
