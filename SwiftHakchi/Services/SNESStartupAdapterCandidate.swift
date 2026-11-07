import Foundation
import SwiftHakchiCore
import SWCompression

/// File-only original-profile candidate. Neither recovery boot nor flash APIs accept this type.
struct SNESStartupAdapterCandidate: Sendable {
    let image: Data
    private let recipeVersion: Int
    let material: SNESOriginalMenuMaterial
    let backup: SNESDataSnapshotPackage
    private init(image: Data, material: SNESOriginalMenuMaterial, backup: SNESDataSnapshotPackage, recipeVersion:Int) {
        self.recipeVersion=recipeVersion; self.image=image; self.material=material; self.backup=backup
    }
    var hasMenuSupport:Bool {recipeVersion>=4}
    var hasLibrarySupport:Bool {recipeVersion>=5}
    var hasCorrectedLibrarySupport:Bool {recipeVersion>=6}
    var hasNavigationLaunchSupport:Bool {recipeVersion>=7}
    var hasEfficientNavigation:Bool {recipeVersion>=8}
    var hasCleanMenuLaunch:Bool {recipeVersion>=9}
    var hasNativeArtworkSupport:Bool {recipeVersion>=10}
    var libraryRecipeVersion:Int {recipeVersion}
    var managementVersion:UInt16 {recipeVersion>=10 ? 0x6a0b:recipeVersion>=9 ? 0x6a0a:recipeVersion>=8 ? 0x6a09:recipeVersion>=7 ? 0x6a08:recipeVersion>=6 ? 0x6a07:recipeVersion==5 ? 0x6a06:recipeVersion==4 ? 0x6a05:0x6a04}
    /// Bind the same startup image to a newer verified snapshot from this setup.
    static func withCurrentBackup(_ candidate:Self,receipt:SNESDataSnapshotReceipt)throws->Self {
        let source=try SNESPreparationSource.load(candidate.material.support.setup)
        let backup=try SNESDataSnapshotPackage.load(receipt:receipt,source:source)
        let rebound=Self(image:candidate.image,material:candidate.material,backup:backup,recipeVersion:candidate.recipeVersion)
        _=try rebound.checkedExport();try backup.revalidate();return rebound
    }
    static func withMenuSupport(_ candidate:Self) throws -> Self {
        _=try candidate.checkedExport()
        let source=try LegacyBootImageBuilder.inspect(candidate.image)
        func member(_ name:String)throws->Data {
            guard let entry=source.archive.entries.first(where:{$0.name=="swifthakchi/"+name}),entry.fields[1]&0xf000==0x8000 else {throw SNESRuntimeBinding.failure()};return entry.data
        }
        return try assemble(material:candidate.material,daemon:member("clovershell"),busybox:member("busybox"),backup:candidate.backup,recipeVersion:4)
    }
    static func withLibrarySupport(_ candidate:Self, legacy:Bool=false, targetRecipe:Int=10) throws -> Self {
        let version=legacy ? 5:targetRecipe
        guard [5,6,7,8,9,10].contains(version),candidate.recipeVersion>=4,candidate.recipeVersion<version else {throw SNESRuntimeBinding.failure()}
        _=try candidate.checkedExport()
        let source=try LegacyBootImageBuilder.inspect(candidate.image)
        func member(_ name:String)throws->Data {
            guard let entry=source.archive.entries.first(where:{$0.name=="swifthakchi/"+name}),entry.fields[1]&0xf000==0x8000 else {throw SNESRuntimeBinding.failure()};return entry.data
        }
        return try assemble(material:candidate.material,daemon:member("clovershell"),busybox:member("busybox"),backup:candidate.backup,recipeVersion:version)
    }
    static func prepare(material: SNESOriginalMenuMaterial, daemonHmod: Data, busybox: Data, backup: SNESDataSnapshotPackage) throws -> Self {
        guard daemonHmod.count <= 1024*1024, BackupManifest.digest(daemonHmod)=="04029161cb7e14b625de3f16edf5485d72e3cc80f9936c38b5a98d7414f4e0fd" else { throw SNESRuntimeBinding.failure() }
        let tar=daemonHmod.starts(with:[31,139]) ? try GzipArchive.unarchive(archive:daemonHmod) : daemonHmod
        let daemon=try RecoveryPayloadValidator.member("bin/clovershell",entries:TarContainer.open(container:tar))
        return try assemble(material:material,daemon:daemon,busybox:busybox,backup:backup,recipeVersion:3)
    }
    private static func assemble(material: SNESOriginalMenuMaterial, daemon: Data, busybox: Data, backup: SNESDataSnapshotPackage, recipeVersion:Int, validatingImage:Data? = nil) throws -> Self {
        guard [1,2,3,4,5,6,7,8,9,10].contains(recipeVersion) else { throw SNESRuntimeBinding.failure() }
        try Task.checkCancellation();try material.revalidate();try backup.revalidate()
        let matched=try SNESDataSnapshotPackage.load(directory:backup.directory,expectedHWID:material.binding.expectedHWID)
        guard matched.sha256==backup.sha256, matched.byteCount==backup.byteCount,
              busybox.count==1427376,BackupManifest.digest(busybox)==SNESRAMProbeScripts.busyboxSHA256,
              daemon.count==23740,BackupManifest.digest(daemon)==SNESRAMProbeRecipe.daemonSHA256 else { throw SNESRuntimeBinding.failure() }
        let bb=try ARMRuntimeELF(data:busybox),de=try ARMRuntimeELF(data:daemon,allowedRPath:"-nostartfiles")
        guard bb.interpreter==nil,bb.dependencies.isEmpty,de.interpreter=="/lib/ld-linux-armhf.so.3",
              Set(de.dependencies)==Set(["libc.so.6","ld-linux-armhf.so.3"]) else { throw SNESRuntimeBinding.failure() }
        let source=material.support.setup,original=try LegacyBootImageBuilder.inspect(source.stock)
        let audit=try SNESStartupAdapterSource(stock:source.stock,startup:material.support.source.preparation.startup)
        let scripts=try SNESStartupAdapterScripts(binding:material.binding,rootRuntime:recipeVersion>=3 ? material.runtime.frame:nil)
        var assets:[String:Data]=[
            "busybox":busybox,"clovershell":daemon,"ld-linux-armhf.so.3":material.runtime.frame.loader,"libc.so.6":material.runtime.frame.libc,
            "original-usb":audit.originalUSB,"service":Data(scripts.service.utf8),"usb-wrapper":Data(scripts.usbWrapper.utf8)]
        if recipeVersion>=4 {
            assets["original-menu-init"]=audit.originalMenu
            assets["menu-wrapper"]=Data(SNESMenuAdapterScripts.wrapper.utf8)
            assets["menu-selector"]=Data(SNESMenuAdapterScripts.verifier.utf8)
            assets["menu-configure"]=Data(SNESMenuAdapterScripts.configure.utf8)
            assets["service"]=Data(scripts.service.replacingOccurrences(of:"6a04",with:recipeVersion>=10 ? "6a0b":recipeVersion>=9 ? "6a0a":recipeVersion>=8 ? "6a09":recipeVersion>=7 ? "6a08":recipeVersion>=6 ? "6a07":recipeVersion==5 ? "6a06":"6a05").utf8)
        }
        if recipeVersion>=5 {
            assets["library-selector"]=Data((recipeVersion==5 ? SNESLibraryStartupScripts.legacyVerifier:recipeVersion>=10 ? SNESLibraryStartupScripts.verifier:SNESLibraryStartupScripts.legacyArtworkVerifier).utf8)
            assets["menu-route"]=Data((recipeVersion>=8 ? SNESLibraryStartupScripts.route:SNESLibraryStartupScripts.legacyRoute).utf8)
            assets["menu-change"]=Data((recipeVersion>=9 ? SNESLibraryStartupScripts.changePage:recipeVersion>=8 ? SNESLibraryStartupScripts.efficientChangePage:recipeVersion>=7 ? SNESLibraryStartupScripts.launchCompatibleChangePage:SNESLibraryStartupScripts.legacyChangePage).utf8)
            assets["menu-configure"]=Data(try SNESLibraryStartupScripts.configuration().utf8)
        }
        if recipeVersion>=9 {assets["menu-launch"]=try SNESMenuLaunchHelper.load()}
        var runtimeChecks=Data(assets.keys.sorted().map { BackupManifest.digest(assets[$0]!) + "  /mnt/swifthakchi/" + $0 + "\n" }.joined().utf8)
        if recipeVersion>=4 {runtimeChecks.append(Data((SNESMenuAdapterScripts.mcpDesktopSHA256+"  /mnt/swifthakchi/mcp-template\n").utf8))}
        if recipeVersion>=3 {
            assets.removeValue(forKey:"ld-linux-armhf.so.3")
            assets.removeValue(forKey:"libc.so.6")
        }
        assets["runtime-files.sha256"]=runtimeChecks
        assets["prepare"]=Data((recipeVersion>=4 ? try SNESMenuAdapterScripts.extendPreparation(scripts.prepare):scripts.prepare).utf8)
        if recipeVersion>=5 {
            guard let bytes=assets["prepare"],let preparation=String(data:bytes,encoding:.utf8) else {throw SNESRuntimeBinding.failure()}
            let marker="menu-configure runtime-files.sha256; do"
            guard preparation.components(separatedBy:marker).count==2 else {throw SNESRuntimeBinding.failure()}
            assets["prepare"]=Data(preparation.replacingOccurrences(of:marker,with:recipeVersion>=9 ? "menu-configure library-selector menu-route menu-change menu-launch runtime-files.sha256; do":"menu-configure library-selector menu-route menu-change runtime-files.sha256; do").utf8)
        }
        assets["root-files.sha256"]=audit.rootChecks
        if recipeVersion>=4 {assets["root-files.sha256"]!.append(Data((SNESMenuAdapterScripts.mcpDesktopSHA256+"  /newroot/usr/share/applications/clover-mcp.desktop\n").utf8))}
        let changedInit=try audit.hookedInit()
        var allChecks=Dictionary(uniqueKeysWithValues:original.archive.entries.filter { $0.fields[1]&0xf000==0x8000 }.map { ($0.name,$0.data) })
        allChecks["sbin/init"]=changedInit
        for (name,bytes) in assets { allChecks["swifthakchi/"+name]=bytes }
        assets["files.sha256"]=Data(allChecks.keys.sorted().map { BackupManifest.digest(allChecks[$0]!) + "  /" + $0 + "\n" }.joined().utf8)
        guard assets.values.reduce(0, { $0+$1.count }) < 8*1024*1024,
              !original.archive.entries.contains(where: { $0.name=="swifthakchi" || $0.name.hasPrefix("swifthakchi/") }) else { throw SNESRuntimeBinding.failure() }
        var additions:[NewcEntry]=[]
        func add(_ name:String,_ mode:UInt32,_ bytes:Data) {
            additions.append(.init(name:name,fields:[UInt32(31000+additions.count),mode,0,0,mode&0xf000==0x4000 ? 2:1,0,UInt32(bytes.count),0,0,0,0,UInt32(name.utf8.count+1),0],data:bytes))
        }
        add("swifthakchi",0o40700,Data())
        let executable=Set(["busybox","ld-linux-armhf.so.3","clovershell","prepare","service","usb-wrapper","original-usb","original-menu-init","menu-wrapper","menu-selector","menu-configure","library-selector","menu-route","menu-change","menu-launch"])
        for name in assets.keys.sorted() { add("swifthakchi/"+name,executable.contains(name) ? 0o100700:0o100600,assets[name]!) }
        let archive=try original.archive.updating(replacements:["sbin/init":changedInit],additions:additions)
        let encoding:LegacyBootImageBuilder.RamdiskEncoding=recipeVersion==1 ? .lzopStored:recipeVersion==2 ? .xz:.lzopCompressed
        let image:Data
        if let existing = validatingImage, recipeVersion >= 2 {
            guard try LegacyBootImageBuilder.matchesRebuild(existing,source:source.stock,kernel:original.kernel,archive:archive) else { throw SNESRuntimeBinding.failure() }
            image=existing
        } else {
            image=try LegacyBootImageBuilder.build(source:source.stock,kernel:original.kernel,archive:archive,ramdiskEncoding:encoding)
        }
        let checked=try LegacyBootImageBuilder.inspect(image)
        guard checked.kernel==original.kernel,checked.archive==archive,checked.header[64..<576]==original.header[64..<576] else { throw SNESRuntimeBinding.failure() }
        for entry in original.archive.entries where entry.name != "sbin/init" {
            var expected=entry;if entry.name=="." { expected.fields[4]+=1 }
            guard checked.archive.entries.first(where: { $0.name==entry.name })==expected else { throw SNESRuntimeBinding.failure() }
        }
        _=try SNESBoot2Bounds(partitions:material.support.source.preparation.source.partitions).checkedExtent(byteCount:image.count)
        if recipeVersion==2 { try SNESColdBootPolicy.require(boot1:material.support.source.preparation.source.boot1,imageByteCount:image.count) }
        if recipeVersion>=3 {try SNESColdBootPolicy.require(boot1:material.support.source.preparation.source.boot1,image:image)}
        try Task.checkCancellation();try material.revalidate();try backup.revalidate()
        return .init(image:image,material:material,backup:backup,recipeVersion:recipeVersion)
    }
    private static func sameImage(_ image:Data,rebuilt:Self) throws -> Bool {
        if rebuilt.recipeVersion==1 { return image==rebuilt.image }
        try SNESColdBootPolicy.require(boot1:rebuilt.material.support.source.preparation.source.boot1,imageByteCount:image.count)
        let layout=try LegacyAndroidBootImage(data:image)
        if rebuilt.recipeVersion==2 {
            guard image.subdata(in:layout.ramdiskRange).starts(with:[0xfd,0x37,0x7a,0x58,0x5a,0]) else {return false}
        } else {
            try SNESColdBootPolicy.require(boot1:rebuilt.material.support.source.preparation.source.boot1,image:image)
        }
        let actual=try LegacyBootImageBuilder.inspect(image),expected=try LegacyBootImageBuilder.inspect(rebuilt.image)
        // Encoder revisions may change compressed bytes; the decoded recipe and all source header fields must still match.
        return actual.archive==expected.archive && actual.kernel==expected.kernel &&
            actual.header[0..<16]==expected.header[0..<16] && actual.header[20..<576]==expected.header[20..<576] &&
            actual.header[596..<608]==expected.header[596..<608]
    }
    private struct Manifest:Codable {
        let schemaVersion:Int,complete:Bool,bootEligible:Bool,firmwareInstallEligible:Bool,firmwareWritten:Bool,firmwareRestoreEligible:Bool
        let scope:String,profilePolicy:String,managementStorage:String
        let setupPath:String,preparationPath:String,supportPath:String,componentsPath:String,runtimePath:String,currentDataPath:String
        let binding:SNESRuntimeBinding,imageSHA256:String,dataSHA256:String
    }
    func checkedExport() throws -> (files:[String:Data],manifest:Data) {
        let parsed=try LegacyBootImageBuilder.inspect(image)
        func member(_ name:String) throws -> Data {
            guard let entry=parsed.archive.entries.first(where: { $0.name=="swifthakchi/"+name }),entry.fields[1]&0xf000==0x8000 else { throw SNESRuntimeBinding.failure() };return entry.data
        }
        let rebuilt=try Self.assemble(material:material,daemon:member("clovershell"),busybox:member("busybox"),backup:backup,recipeVersion:recipeVersion,validatingImage:image)
        guard try Self.sameImage(image,rebuilt:rebuilt),let runtime=material.runtime.directoryURL else { throw SNESRuntimeBinding.failure() }
        let support=material.support
        let m=Manifest(schemaVersion:recipeVersion,complete:true,bootEligible:false,firmwareInstallEligible:false,firmwareWritten:false,firmwareRestoreEligible:false,
            scope:"snes-original-profile-startup",profilePolicy:"original-existing-data",managementStorage:"ram-tmpfs-8MiB",
            setupPath:support.setup.directoryURL.path,preparationPath:support.source.directoryURL.path,supportPath:support.directoryURL.path,
            componentsPath:material.components.directoryURL.path,runtimePath:runtime.path,currentDataPath:backup.directory.path,
            binding:material.binding,imageSHA256:BackupManifest.digest(image),dataSHA256:backup.sha256)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        return (["startup.img":image],try encoder.encode(m))
    }
    static func load(directory:URL,expectedManifestSHA256:String?=nil) throws -> Self {
        let dir=try RestoreDirectory(directory),prefix="SNES-Startup-Candidate-"
        guard dir.url.lastPathComponent.hasPrefix(prefix),UUID(uuidString:String(dir.url.lastPathComponent.dropFirst(prefix.count))) != nil,
              Set(try dir.names())==Set(["startup.img","manifest.json"]) else { throw SNESRuntimeBinding.failure() }
        let raw=try dir.read("manifest.json",maximum:65536),m=try JSONDecoder().decode(Manifest.self,from:raw)
        if let expectedManifestSHA256, BackupManifest.digest(raw) != expectedManifestSHA256 { throw SNESRuntimeBinding.failure() }
        guard [1,2,3,4,5,6,7,8,9,10].contains(m.schemaVersion),m.complete,!m.bootEligible,!m.firmwareInstallEligible,!m.firmwareWritten,!m.firmwareRestoreEligible,
              m.scope=="snes-original-profile-startup",m.profilePolicy=="original-existing-data",m.managementStorage=="ram-tmpfs-8MiB",
              [m.setupPath,m.preparationPath,m.supportPath,m.componentsPath,m.runtimePath,m.currentDataPath].allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count<=4096 }) else { throw SNESRuntimeBinding.failure() }
        let source=try SNESOfflineSource.load(snapshot:URL(fileURLWithPath:m.setupPath))
        let supportSource=try SNESMenuSupportSource.load(setup:source,preparation:URL(fileURLWithPath:m.preparationPath))
        let support=try SNESMenuSupportMaterial.load(source:supportSource,directory:URL(fileURLWithPath:m.supportPath))
        let components=try SNESOriginalComponentMaterial.load(source:SNESOriginalComponentSource(material:support),directory:URL(fileURLWithPath:m.componentsPath))
        let runtime=try SNESRuntimeMaterial.load(directory:URL(fileURLWithPath:m.runtimePath),source:source)
        let material=try SNESOriginalMenuMaterial(components:components,runtime:runtime)
        guard material.binding==m.binding else { throw SNESRuntimeBinding.failure() }
        let backup=try SNESDataSnapshotPackage.load(directory:URL(fileURLWithPath:m.currentDataPath),expectedHWID:material.binding.expectedHWID)
        guard backup.sha256==m.dataSHA256 else { throw SNESRuntimeBinding.failure() }
        let image=try dir.read("startup.img"),parsed=try LegacyBootImageBuilder.inspect(image)
        func member(_ name:String) throws -> Data {
            guard let entry=parsed.archive.entries.first(where: { $0.name=="swifthakchi/"+name }),entry.fields[1]&0xf000==0x8000 else { throw SNESRuntimeBinding.failure() };return entry.data
        }
        let rebuilt=try Self.assemble(material:material,daemon:member("clovershell"),busybox:member("busybox"),backup:backup,recipeVersion:m.schemaVersion,validatingImage:image)
        guard try Self.sameImage(image,rebuilt:rebuilt),BackupManifest.digest(image)==m.imageSHA256 else { throw SNESRuntimeBinding.failure() }
        let restored=Self(image:image,material:material,backup:backup,recipeVersion:m.schemaVersion)
        let export=try restored.checkedExport()
        guard let expected=try JSONSerialization.jsonObject(with:raw) as? [String:Any],
              let actual=try JSONSerialization.jsonObject(with:export.manifest) as? NSDictionary,actual.isEqual(to:expected) else { throw SNESRuntimeBinding.failure() }
        try dir.check();return restored
    }
}
