import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESNativeThumbnailTests {
    @MainActor @Test func everyImportedGameAndFolderProvidesTheThumbnailTheOriginalMenuRequests() throws {
        let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let helper=SNESLibraryMaterialTests(),(review,originals)=try helper.fixture(root,count:2)
        let legacy=try helper.menu(review,originals)
        let menu=try legacy.withNativeArtwork()
        #expect(legacy.description.version==1 && menu.description.version==2)
        var images=0
        for placement in menu.description.placements where placement.kind != "stock" {
            let desktop=String(format:"pages/%03d/%@/%@.desktop",placement.page,placement.code,placement.code)
            let fields=try SNESOneGameMenu.fields(#require(menu.files[desktop]))
            let icon=try #require(fields["icon"])
            let folder=String(icon.prefix(through:try #require(icon.lastIndex(of:"/"))))
            let requested=folder+placement.code+"_small.png"
            #expect(icon.hasPrefix(menu.consoleRoot+"/"),"Large icon must be in this menu's immutable directory")
            #expect(requested.hasPrefix(menu.consoleRoot+"/"))
            if requested.hasPrefix(menu.consoleRoot+"/") {
                let relative=String(requested.dropFirst(menu.consoleRoot.count+1))
                let data=try #require(menu.files[relative],"Original menu requested a missing small image: \(requested)")
                #expect(!data.isEmpty)
            }
            images+=2
        }
        #expect(menu.objects.keys.allSatisfy {$0.hasSuffix(".sfrom")},"Artwork must not also remain in shared objects")
        #expect(menu.files.keys.filter {$0.hasSuffix(".png")}.count==images)
        try menu.validate()
        if let folder=ProcessInfo.processInfo.environment["SWIFTHAKCHI_NATIVE_ART_EXPORT"] {
            let root=URL(fileURLWithPath:folder)
            let stock=Dictionary(uniqueKeysWithValues:originals.entries.flatMap { e in e.files.filter {$0.name.hasSuffix(".desktop")}.map {(e.code+"/"+$0.name,$0.data.base64EncodedString())} })
            let value:[String:Any]=["id":menu.id.uuidString,"manifest":try SNESLibraryStartupScripts.manifest(for:menu).base64EncodedString(),
                "files":menu.files.mapValues {$0.base64EncodedString()},"objects":menu.objects.mapValues {$0.base64EncodedString()},"stock":stock]
            try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:root.appendingPathComponent("fixture.json"),options:.withoutOverwriting)
            try Data(SNESLibraryStartupScripts.verifier.utf8).write(to:root.appendingPathComponent("verify.sh"),options:.withoutOverwriting)
        }
    }
    @MainActor @Test func nativeCapacityCountsGameDirectoriesOnceAndFitsAtItsExactBoundary() throws {
        let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let helper=SNESLibraryMaterialTests(),(review,originals)=try helper.fixture(root,count:2)
        let menu=try helper.menu(review,originals).withNativeArtwork()
        let now=Date(),context=String(repeating:"a",count:64),block:Int64=4096
        func allocated(_ bytes:Int)->Int64 {((Int64(bytes)+block-1)/block)*block}
        // Count actual parent directories, independently of how many PNGs a game has.
        let gameDirectories=Set(menu.files.keys.map {String($0.prefix(upTo:$0.lastIndex(of:"/")!))})
        let directories=Int64(7+menu.graph.screens.count+gameDirectories.count)*block
        let payload=menu.description.files.reduce(Int64(0)) {$0+allocated($1.byteCount)}
            + menu.objectRecords.reduce(Int64(0)) {$0+allocated($1.byteCount)}
            + allocated(menu.manifest.count)+allocated(try SNESLibraryStartupScripts.manifest(for:menu).count)
        let expected=payload+directories
        let inventory=SNESLibraryCapacity.Inventory(measuredAt:now,contextSHA256:context,freeBytes:expected+2359296,blockSize:block,objects:[:])
        let result=try SNESLibraryCapacity.project(menu:menu,inventory:inventory,expectedContext:context,now:now)
        #expect(result.newAllocatedBytes==expected)
        #expect(result.canFit)
    }

    @MainActor @Test func frozenNativeAndHistoricalMenusReopenWithoutChangingTheirBytes() throws {
        let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let helper=SNESLibraryMaterialTests(),(review,originals)=try helper.fixture(root,count:2)
        let legacy=try helper.menu(review,originals),native=try legacy.withNativeArtwork()
        let old=root.appendingPathComponent("old"),new=root.appendingPathComponent("new")
        for path in [old,new] {try FileManager.default.createDirectory(at:path,withIntermediateDirectories:false)}
        let savedOld=try SNESLibraryMaterial.freeze(menu:legacy,in:old)
        let savedNew=try SNESLibraryMaterial.freeze(menu:native,in:new)
        #expect(try SNESLibraryMaterial.load(directory:savedOld.directory,expectedReviewSHA256:savedOld.reviewSHA256).menu.manifest==legacy.manifest)
        #expect(try SNESLibraryMaterial.load(directory:savedNew.directory,expectedReviewSHA256:savedNew.reviewSHA256).menu.manifest==native.manifest)
        #expect(String(decoding:try SNESLibraryStartupScripts.manifest(for:legacy),as:UTF8.self).hasPrefix("SWIFTHAKCHI_SNES_LIBRARY_V1\n"))
        #expect(String(decoding:try SNESLibraryStartupScripts.manifest(for:native),as:UTF8.self).hasPrefix("SWIFTHAKCHI_SNES_LIBRARY_V2\n"))
        for entry in native.description.files where entry.path.hasSuffix(".png") {
            #expect(try SNESLibraryInventory.limit(for:"menus/"+native.id.uuidString+"/"+entry.path)==262144)
        }
    }

    @MainActor @Test func nativeSnapshotRestoresMenuLocalArtUnderANewMenuIdentity() async throws {
        let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let helper=SNESLibraryMaterialTests(),(review,originals)=try helper.fixture(root,count:2)
        let menu=try helper.menu(review,originals).withNativeArtwork()
        let backup=try await SNESLibraryRestoreTests().backup(root,originals:originals,menu:menu)
        let nextID=UUID(),restored=try SNESLibraryRestore.prepare(backup:backup,originals:originals,expectedHWID:SNESLibraryInventoryTests().hwid,id:nextID)
        let next=try #require(restored.menu);try next.validate()
        #expect(next.id==nextID && next.description.version==2)
        #expect(next.objects==menu.objects && next.graph==menu.graph)
        for placement in next.description.placements where placement.kind != "stock" {
            let path=String(format:"pages/%03d/%@/%@.desktop",placement.page,placement.code,placement.code)
            let fields=try SNESOneGameMenu.fields(#require(next.files[path]))
            #expect(fields["icon"]?.hasPrefix(next.consoleRoot+"/")==true)
        }
    }

    @MainActor @Test func nativeReviewRequiresTheArtworkAwareStartupAndKeepsROMReuse() async throws {
        let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let helper=SNESLibraryMaterialTests(),(review,originals)=try helper.fixture(root,count:2)
        let menu=try helper.menu(review,originals).withNativeArtwork()
        let material=try SNESLibraryMaterial.freeze(menu:menu,in:root)
        let backup=try await SNESLibraryRestoreTests().backup(root,originals:originals)
        let reference=SNESLibraryInstallationReference(hwid:backup.inventory.hwid,operationID:UUID(),reviewSHA256:String(repeating:"c",count:64),
            catalog:root.appendingPathComponent("SNES-Original-Games-"+UUID().uuidString),catalogSHA256:String(repeating:"d",count:64))
        let plan=try SNESLibrarySyncPlan.prepare(material:material,backup:backup,before:backup.inventory,capacity:backup.inventory.capacity,installation:reference,originals:originals)
        #expect(plan.requiredUSBVersion==0x6a0b)
        #expect(try SNESLibrarySyncPlan.load(data:plan.data,expectedReviewSHA256:plan.reviewSHA256,originals:originals).requiredUSBVersion==0x6a0b)
        let request=try SNESLibraryCopyCommands.prepare(menu:menu,before:backup.inventory,runtimeSHA256:String(repeating:"a",count:64),challenge:UUID())
        #expect(request.objectNames==Set(menu.objectRecords.map(\.name)))
        #expect(request.objectNames.allSatisfy {$0.hasSuffix(".sfrom")})
        #expect(request.body.range(of:Data("SWIFTHAKCHI_SNES_LIBRARY_V2\n".utf8)) != nil)
    }

    @MainActor @Test(arguments:["wrong-icon","misnamed-small","extra-image","altered-image"])
    func rehashingDoesNotAuthorizeMissingOrForeignArtwork(_ fault:String) throws {
        let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let helper=SNESLibraryMaterialTests(),(review,originals)=try helper.fixture(root,count:2)
        let menu=try helper.menu(review,originals).withNativeArtwork()
        let item=try #require(menu.description.placements.first {$0.kind=="import"})
        let prefix=String(format:"pages/%03d/%@/%@",item.page,item.code,item.code)
        var files=menu.files
        switch fault {
        case "wrong-icon":
            let raw=String(decoding:try #require(files[prefix+".desktop"]),as:UTF8.self)
            files[prefix+".desktop"]=Data(raw.replacingOccurrences(of:"Icon="+menu.consoleRoot+"/"+prefix+".png",with:"Icon=/outside/cover.png").utf8)
        case "misnamed-small":
            files[String(prefix.dropLast(item.code.count))+"wrong_small.png"]=files.removeValue(forKey:prefix+"_small.png")
        case "extra-image":
            files["pages/000/CLV-U-ZZZZZ/CLV-U-ZZZZZ_small.png"]=try #require(files[prefix+"_small.png"])
        default:
            var raw=try #require(files[prefix+"_small.png"]);raw[raw.count-1]^=1;files[prefix+"_small.png"]=raw
        }
        let m=menu.description,next=SNESLibraryMenu.Manifest(version:2,id:m.id,catalogSHA256:m.catalogSHA256,graph:m.graph,structure:m.structure,order:m.order,
            objects:m.objects,files:files.keys.sorted().map {.init(path:$0,byteCount:files[$0]!.count,sha256:BackupManifest.digest(files[$0]!))},stock:m.stock,placements:m.placements)
        let invalid=SNESLibraryMenu(description:next,files:files,objects:menu.objects,sources:menu.sources,manifest:try SNESLibraryMenu.encode(next),sourceSHA256:menu.sourceSHA256)
        #expect(throws:(any Error).self) {try invalid.validate()}
    }

}
