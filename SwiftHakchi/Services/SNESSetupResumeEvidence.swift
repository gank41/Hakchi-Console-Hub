import Foundation
import SwiftHakchiCore

struct SNESSetupRecordReceipt: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case backup, startup, menuSupport, components, runtime, candidate, preflight, trialStarted, trialPlayed, activeBoot2 }
    let kind: Kind
    let directory: URL
    let manifestSHA256: String
}

struct SNESSetupRecordChain: Sendable {
    let startup: SNESSetupRecordReceipt
    let support: SNESSetupRecordReceipt
    let components: SNESSetupRecordReceipt

    func load(setup: SNESOfflineSource) throws -> SNESOriginalComponentMaterial {
        guard startup.kind == .startup, support.kind == .menuSupport, components.kind == .components else { throw SNESRuntimeBinding.failure() }
        let preparation = try SNESMenuSupportSource.load(setup: setup, preparation: startup.directory)
        guard preparation.manifestSHA256 == startup.manifestSHA256 else { throw SNESRuntimeBinding.failure() }
        let menu = try SNESMenuSupportMaterial.load(source: preparation, directory: support.directory)
        guard menu.manifestSHA256 == support.manifestSHA256 else { throw SNESRuntimeBinding.failure() }
        let component = try SNESOriginalComponentMaterial.load(source: SNESOriginalComponentSource(material: menu), directory: components.directory)
        guard component.manifestSHA256 == components.manifestSHA256 else { throw SNESRuntimeBinding.failure() }
        return component
    }
}

/// Reopens a single saved setup chain. This is local evidence only: it never
/// opens USB, accepts a console write, or remembers a user's boot confirmation.
struct SNESSetupResumeEvidence: Sendable {
    enum Stage: Int, Sendable { case backup, startup, menuSupport, components }
    let root: URL, backup: URL, recovery: URL, helpers: URL
    let startup: URL?, support: URL?, components: URL?
    let stage: Stage
    private let manifests: [String: String]
    func requireBackupManifest(_ expected: String) throws {
        guard manifests[backup.lastPathComponent] == expected else { throw SNESOfflineSource.failure() }
    }
    func requireSources(backup source: SNESOfflineSource, startup startupSource: SNESMenuSupportSource? = nil,
                        support supportSource: SNESMenuSupportMaterial? = nil) throws {
        guard source.directoryURL.path == backup.path, manifests[backup.lastPathComponent] == source.manifestSHA256 else { throw SNESOfflineSource.failure() }
        if let startup, let startupSource {
            guard startupSource.directoryURL.path == startup.path, manifests[startup.lastPathComponent] == startupSource.manifestSHA256 else { throw SNESOfflineSource.failure() }
        }
        if let support, let supportSource {
            guard supportSource.directoryURL.path == support.path, manifests[support.lastPathComponent] == supportSource.manifestSHA256 else { throw SNESOfflineSource.failure() }
        }
    }

    static func load(root: URL, backup: URL, recovery: URL, helpers: URL,
                     startup: URL? = nil, support: URL? = nil, components: URL? = nil) throws -> Self {
        guard (support == nil || startup != nil), (components == nil || support != nil) else { throw SNESRuntimeBinding.failure() }
        let base = root.standardizedFileURL
        let urls = [backup, recovery, helpers] + [startup, support, components].compactMap { $0 }
        guard root.isFileURL, base.path == root.path, base == base.resolvingSymlinksInPath(),
              urls.allSatisfy({ $0.isFileURL && $0.path == $0.standardizedFileURL.path && $0.deletingLastPathComponent().path == base.path }),
              Set(urls.map(\.path)).count == urls.count else { throw SNESRuntimeBinding.failure() }
        let directory = try RestoreDirectory(base)
        let source = try SNESOfflineSource.load(snapshot: backup)
        let prepared = try SNESPreparationSource.load(source)
        let original = try SNESRecoveryMaterial.loadPackage(directory: recovery)
        let originalBackup = try SNESRecoveryMaterial.load(setup: backup)
        let tools = try SNESPortableHelperPackage.load(directory: helpers)
        try original.requireHardwareID(source.expectedHWID)
        try original.requireExactSource(originalBackup)
        guard original.stock == source.stock, original.partitions == prepared.partitions else { throw SNESRuntimeBinding.failure() }
        var stage: Stage = .backup
        if let startup {
            let startupSource = try SNESMenuSupportSource.load(setup: source, preparation: startup)
            stage = .startup
            if let support {
                let material = try SNESMenuSupportMaterial.load(source: startupSource, directory: support)
                stage = .menuSupport
                if let components {
                    let componentSource = try SNESOriginalComponentSource(material: material)
                    _ = try SNESOriginalComponentMaterial.load(source: componentSource, directory: components)
                    stage = .components
                }
            }
        }
        try source.revalidate(); try original.revalidate(); try tools.revalidate()
        var manifests: [String: String] = [:]
        for url in urls {
            let item = try RestoreDirectory(url)
            manifests[url.lastPathComponent] = BackupManifest.digest(try item.read("manifest.json", maximum: 65536))
            try item.check()
        }
        try directory.check(); try Task.checkCancellation()
        return Self(root: base, backup: backup, recovery: recovery, helpers: helpers, startup: startup,
                    support: support, components: components, stage: stage, manifests: manifests)
    }

    func revalidate() throws {
        let current = try Self.load(root: root, backup: backup, recovery: recovery, helpers: helpers,
                                    startup: startup, support: support, components: components)
        guard current.stage == stage, current.manifests == manifests else { throw SNESRuntimeBinding.failure() }
    }
    func receipt(for kind: SNESSetupRecordReceipt.Kind) -> SNESSetupRecordReceipt? {
        let url: URL?
        switch kind {
        case .startup: url = startup
        case .menuSupport: url = support
        case .components: url = components
        case .backup: url = backup
        case .runtime, .candidate, .preflight, .trialStarted, .trialPlayed, .activeBoot2: url = nil
        }
        guard let url, let hash = manifests[url.lastPathComponent] else { return nil }
        return SNESSetupRecordReceipt(kind: kind, directory: url, manifestSHA256: hash)
    }
    func advancing(_ receipt: SNESSetupRecordReceipt) throws -> Self {
        guard receipt.manifestSHA256.count == 64, SNESRuntimeBinding.hex(receipt.manifestSHA256) else { throw SNESRuntimeBinding.failure() }
        let newStartup: URL?, newSupport: URL?, newComponents: URL?
        switch (stage, receipt.kind) {
        case (.backup, .startup): (newStartup, newSupport, newComponents) = (receipt.directory, nil, nil)
        case (.startup, .menuSupport): (newStartup, newSupport, newComponents) = (startup, receipt.directory, nil)
        case (.menuSupport, .components): (newStartup, newSupport, newComponents) = (startup, support, receipt.directory)
        default: throw SNESRuntimeBinding.failure()
        }
        try revalidate()
        let next = try Self.load(root: root, backup: backup, recovery: recovery, helpers: helpers,
                                 startup: newStartup, support: newSupport, components: newComponents)
        guard manifests.allSatisfy({ next.manifests[$0.key] == $0.value }),
              next.manifests[receipt.directory.lastPathComponent] == receipt.manifestSHA256 else { throw SNESOfflineSource.failure() }
        return next
    }
}

enum SNESSetupSelectedBinding {
    @TaskLocal static var current: SNESSetupResumeEvidence?
}
