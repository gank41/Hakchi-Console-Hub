import Foundation
import SwiftHakchiCore

/// Bound to one fully byte-validated immutable firmware operation.
struct SNESFirmwareGuard:Sendable {
    let id:UUID,reviewSHA256:String
    private let seal:SNESFirmwareSourceSeal
    private let parent:SNESMenuStartupParent?
    private let restorationHistory:SNESFirmwareSourceSeal?
    private init(id:UUID,reviewSHA256:String,seal:SNESFirmwareSourceSeal,parent:SNESMenuStartupParent?,restorationHistory:SNESFirmwareSourceSeal?){self.id=id;self.reviewSHA256=reviewSHA256;self.seal=seal;self.parent=parent;self.restorationHistory=restorationHistory}
    static func prepare(_ material:SNESFirmwareMaterial)throws->Self {
        let p=material.paths,c=material.trial.candidate,m=c.material
        guard let runtime=m.runtime.directoryURL else {throw SNESRuntimeBinding.failure()}
        let folders=[p.candidate,p.preflight,p.started,p.played,p.original].map {URL(fileURLWithPath:$0)} +
            [material.source.source.directoryURL,c.backup.directory,m.support.source.directoryURL,m.support.directoryURL,m.components.directoryURL,runtime] + m.components.source.evidenceDirectories
        let seal=try SNESFirmwareSourceSeal.capture(directories:folders,files:[material.reader.location,material.writer.location])
        // Full hashes/recipes checked while the metadata seal must remain unchanged.
        try material.validateCurrent();try seal.validate()
        return .init(id:material.id,reviewSHA256:BackupManifest.digest(try material.planData()),seal:seal,parent:material.trial.evidence.parent,restorationHistory:material.restorationParentHistory)
    }
    func validate()throws {try seal.validate();try parent?.validate();try restorationHistory?.validate()}
    func require(_ material:SNESFirmwareMaterial)throws {
        guard material.id==id,BackupManifest.digest(try material.planData())==reviewSHA256 else {throw SNESRuntimeBinding.failure()}
        try validate()
    }
}
