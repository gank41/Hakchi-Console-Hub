import Foundation

/// Offline RAM-only experiment for the menu's SIGTERM-to-RESET handoff.
/// It neither enables production sync nor authorizes a console boot.
public enum SNESRAMMenuSignalTrialBuilder {
    public static let ownerSHA256 = "ee131b2e5ab594cdd750b03109f4a6cb5dd220b0c976d70603c5a356e658fb66"
    public static func build(source:Data,payload:[String:Data],report:Data,artwork:Data,
                             resetOwner:Data,signalOwner:Data) throws -> SNESRAMCompatibilityMenuBuilder.Result {
        func bad() -> RecoveryImageError { .invalid("The temporary signal trial owner or image differs from the reviewed candidate.") }
        guard BackupManifest.digest(signalOwner)==ownerSHA256 else { throw bad() }
        let base=try SNESRAMMenuResetTrialBuilder.build(source:source,payload:payload,report:report,artwork:artwork,owner:resetOwner)
        let image=try LegacyBootImageBuilder.inspect(base.image)
        guard let bytes=image.archive.entries.first(where:{$0.name=="probe/compat/trial-start"})?.data,
              var script=String(data:bytes,encoding:.utf8),
              script.components(separatedBy:SNESRAMMenuResetTrialBuilder.ownerSHA256).count==2 else { throw bad() }
        script=script.replacingOccurrences(of:SNESRAMMenuResetTrialBuilder.ownerSHA256,with:ownerSHA256)
        var files=Dictionary(uniqueKeysWithValues:image.archive.entries.filter { $0.fields[1] & 0xf000 == 0x8000 && $0.name != "probe/files.sha256" }.map { ($0.name,$0.data) })
        files["probe/compat/trial-start"]=Data(script.utf8);files["probe/compat/trial-menu-owner"]=signalOwner
        let manifest=Data(files.keys.sorted().map {BackupManifest.digest(files[$0]!) + "  /" + $0 + "\n"}.joined().utf8)
        let archive=try image.archive.updating(replacements:["probe/compat/trial-start":Data(script.utf8),"probe/compat/trial-menu-owner":signalOwner,"probe/files.sha256":manifest])
        let size=archive.entries.filter {$0.name=="probe" || $0.name.hasPrefix("probe/")}.reduce(0){$0+$1.data.count}
        guard size < 16*1024*1024 else { throw bad() }
        let result=try LegacyBootImageBuilder.build(source:source,kernel:image.kernel,archive:archive,ramdiskEncoding:.lzopCompressed)
        let checked=try LegacyBootImageBuilder.inspect(result)
        guard checked.kernel==image.kernel,checked.archive==archive else { throw bad() }
        return .init(image:result,filesSHA256:BackupManifest.digest(manifest))
    }
}
