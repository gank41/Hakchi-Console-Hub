import Foundation
import SwiftHakchiCore

enum SNESStartupPreparationDiagnostic {
    /// File-only command; invoked before any payload loading or hardware handler.
    static func runIfPresent(_ args:[String]) async throws -> String? {
        guard args.first=="--prepare-snes-startup" else { return nil }
        guard args.count==10,args.dropFirst().allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count<=4096 }) else {
            throw RecoveryProbeError.refused("Startup preparation needs saved setup, preparation, support, components, runtime and current-data folders, the checked utilities, and an existing Mac Backups folder. This command works on Mac files only.")
        }
        try Task.checkCancellation()
        let source=try SNESOfflineSource.load(snapshot:URL(fileURLWithPath:args[1]))
        let supportSource=try SNESMenuSupportSource.load(setup:source,preparation:URL(fileURLWithPath:args[2]))
        let support=try SNESMenuSupportMaterial.load(source:supportSource,directory:URL(fileURLWithPath:args[3]))
        let components=try SNESOriginalComponentMaterial.load(source:SNESOriginalComponentSource(material:support),directory:URL(fileURLWithPath:args[4]))
        let runtime=try SNESRuntimeMaterial.load(directory:URL(fileURLWithPath:args[5]),source:source)
        let material=try SNESOriginalMenuMaterial(components:components,runtime:runtime)
        let backup=try SNESDataSnapshotPackage.load(directory:URL(fileURLWithPath:args[6]),expectedHWID:source.expectedHWID)
        func file(_ path:String,maximum:Int) throws -> Data {
            let url=URL(fileURLWithPath:path),dir=try RestoreDirectory(url.deletingLastPathComponent())
            let bytes=try dir.read(url.lastPathComponent,maximum:maximum);try dir.check();return bytes
        }
        let store=try RecoveryBootSnapshotStore(root:URL(fileURLWithPath:args[9]))
        let candidate=try SNESStartupAdapterCandidate.prepare(material:material,daemonHmod:file(args[7],maximum:1024*1024),busybox:file(args[8],maximum:2*1024*1024),backup:backup)
        let destination=try await store.saveSNESStartupCandidate(candidate)
        let checked=try SNESStartupAdapterCandidate.load(directory:destination)
        return String(decoding:try JSONSerialization.data(withJSONObject:["directory":destination.path,"imageBytes":checked.image.count,
            "imageSHA256":BackupManifest.digest(checked.image),"USBOpened":false,"bootEligible":false,"firmwareInstallEligible":false,
            "firmwareWritten":false,"firmwareRestoreEligible":false,"status":"Startup files prepared and checked on this Mac. The console was not changed."],options:[.prettyPrinted,.sortedKeys]),as:UTF8.self)
    }
}
