import Foundation

struct SNESMenuFirmwareRequest:Codable,Sendable {
    let parentOperation:String,parentReviewSHA256:String,paths:SNESFirmwarePaths
}
/// Offline-only preparation. Existing reviewed transaction commands perform I/O.
enum SNESMenuFirmwareDiagnostic {
    static func runIfPresent(_ args:[String],
        loadInputs:@Sendable () async throws->RecoveryBootInputs={try PayloadService.shared.pinnedRecoveryInputs()},
        root:@Sendable ()throws->URL={try SNESFirmwareJournalPolicy.ensureRoot()},
        requireOperation:@Sendable (URL)throws->Void={try SNESFirmwareJournalPolicy.requireOperation($0)}) async throws->String? {
        guard args.first=="--prepare-snes-menu-firmware" || args.first=="--prepare-snes-library-firmware" else {return nil}
        let libraryUpdate=args.first=="--prepare-snes-library-firmware"
        func path(_ s:String)->Bool {s.hasPrefix("/") && !s.contains("\0") && s.utf8.count<=4096}
        guard args.count==2,path(args[1]) else {throw SNESRuntimeBinding.failure()}
        let file=URL(fileURLWithPath:args[1]),directory=try RestoreDirectory(file.deletingLastPathComponent()),raw=try directory.read(file.lastPathComponent,maximum:65536)
        let request=try JSONDecoder().decode(SNESMenuFirmwareRequest.self,from:raw)
        guard path(request.parentOperation),SNESDataSnapshotChunk.isDigest(request.parentReviewSHA256),
              let canonical=try JSONSerialization.jsonObject(with:JSONEncoder().encode(request)) as? NSDictionary,
              let actual=try JSONSerialization.jsonObject(with:raw) as? [String:Any],canonical.isEqual(to:actual) else {throw SNESRuntimeBinding.failure()}
        try request.paths.validate();try directory.check()
        let operation=URL(fileURLWithPath:request.parentOperation);try requireOperation(operation)
        let inputs=try await loadInputs();_=try inputs.prepare()
        let journal=try await SNESFirmwareJournal.reopen(operation:operation,reviewSHA256:request.parentReviewSHA256,recovery:inputs)
        let parent:SNESMenuStartupParent
        do {
            parent=try await libraryUpdate ? journal.libraryStartupParent() : journal.menuStartupParent()
            try await journal.close()
        }
        catch {try? await journal.close();throw error}
        let material=try SNESFirmwareMaterial.upgrade(parent:parent,paths:request.paths,recovery:inputs)
        try SNESColdBootPolicy.require(boot1:material.source.boot1,image:material.trial.image)
        let checked=try SNESFirmwareGuard.prepare(material),prepared=try SNESFirmwareJournal.prepare(material:material,root:root(),guard:checked)
        return String(decoding:try JSONSerialization.data(withJSONObject:["operation":prepared.operation.path,"reviewSHA256":prepared.reviewSHA256,"phase":"prepared",
            "firmwareWritten":false,"USBOpened":false,"dataBackupCreated":false,"changedUnits":material.changedUnits.count,
            "status":"The startup update is prepared on this Mac. The next step checks the console without installing anything."],options:[.prettyPrinted,.sortedKeys]),as:UTF8.self)
    }
}
