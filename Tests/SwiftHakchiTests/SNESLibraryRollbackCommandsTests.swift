import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryRollbackCommandsTests {
    @Test(arguments:[false,true], ["empty","builtin","legacy","library"].flatMap {kind in ["valid","game","changed-current","linked-current","pending","old-broken","resume-prefix","resume-foreign"].map {(kind,$0)}})
    func rollbackChangesOnlyTheOwnedSelector(_ native:Bool,_ sample:(String,String)) async throws {
        let (kind,fault)=sample
        if fault.hasPrefix("resume-") && (kind == "empty" || kind == "legacy") {return}
        if fault == "old-broken" && (kind == "empty" || kind == "builtin") {return}
        let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let helper=SNESLibraryMaterialTests(),(review,originals)=try helper.fixture(root)
        let legacyMenu=try helper.menu(review,originals),legacyOld=try helper.menu(review,originals)
        let menu=try native ? legacyMenu.withNativeArtwork():legacyMenu,old=try native ? legacyOld.withNativeArtwork():legacyOld
        let legacy=try SNESOneGameMenu.prepare(originals:originals,code:"CLV-U-ABCDE",metadata:oneGameMetadata,rom:oneGameSyntheticROM(),artwork:oneGameSyntheticArt())
        let oldBytes:Data
        let previous:SNESLibraryInventory.Selection
        switch kind {
        case "empty":oldBytes=Data();previous = .init(kind:.builtin,id:nil,treeSHA256:nil,selectorSHA256:BackupManifest.digest(oldBytes))
        case "builtin":oldBytes=Data("SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1\nBUILTIN\n".utf8);previous = .init(kind:.builtin,id:nil,treeSHA256:nil,selectorSHA256:BackupManifest.digest(oldBytes))
        case "legacy":oldBytes=Data("SWIFTHAKCHI_SNES_MENU_SELECTOR_V1\n\(legacy.id.uuidString)\n\(legacy.treeSHA256)\n".utf8);previous = .init(kind:.legacy,id:legacy.id,treeSHA256:legacy.treeSHA256,selectorSHA256:BackupManifest.digest(oldBytes))
        default:
            let wire=try SNESLibraryStartupScripts.manifest(for:old),hash=BackupManifest.digest(wire)
            oldBytes=Data("SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1\nMENU\n\(old.id.uuidString)\n\(hash)\n".utf8);previous = .init(kind:.library,id:old.id,treeSHA256:hash,selectorSHA256:BackupManifest.digest(oldBytes))
        }
        let fixture=SNESLibraryInventoryTests(),nonce=UUID()
        let current=try fixture.parse(fixture.frame(challenge:nonce,menu:menu),challenge:nonce)
        let runtimeHash=String(repeating:"b",count:64)
        let request=try SNESLibraryRollbackCommands.prepare(menu:menu,previous:previous,current:current,runtimeSHA256:runtimeHash,challenge:UUID(),recoverPending:fault.hasPrefix("resume-"))
        let data=root.appendingPathComponent("data"),runtime=root.appendingPathComponent("runtime")
        let n=data.appendingPathComponent("swifthakchi/snes-v2"),l=data.appendingPathComponent("swifthakchi/snes-v1")
        let stage=n.appendingPathComponent("menus/"+menu.id.uuidString)
        for p in [data,runtime,data.appendingPathComponent("clover"),stage.appendingPathComponent("pages/000"),n.appendingPathComponent("objects"),n.appendingPathComponent("descriptions")] {try FileManager.default.createDirectory(at:p,withIntermediateDirectories:true)}
        let pin=try SNESLibraryCopyCommandsTests().makeRuntime(root:root,data:data,runtime:runtime,fault:fault)
        try (try SNESLibraryStartupScripts.manifest(for:menu)).write(to:stage.appendingPathComponent("menu.manifest"))
        try menu.manifest.write(to:n.appendingPathComponent("descriptions/"+menu.id.uuidString+".json"))
        let selector=try current.selection.bytes(),sentinel=Data("preserve".utf8)
        let active=n.appendingPathComponent("active-menu")
        try selector.write(to:active)
        try sentinel.write(to:data.appendingPathComponent("clover/settings.json"))
        try sentinel.write(to:n.appendingPathComponent("objects/protected"))
        if kind == "legacy" {
            try FileManager.default.createDirectory(at:l.appendingPathComponent("menus/"+legacy.id.uuidString+"/games"),withIntermediateDirectories:true)
            try oldBytes.write(to:l.appendingPathComponent("active-menu"))
            try Data((fault == "old-broken" ? "exit 1\n":"printf '%s\\n' '"+l.path+"/menus/'\"$1\"'/games'\n").utf8).write(to:runtime.appendingPathComponent("menu-selector"))
        }
        if kind == "library" {
            try FileManager.default.createDirectory(at:n.appendingPathComponent("menus/"+old.id.uuidString+"/pages/000"),withIntermediateDirectories:true)
            if fault == "old-broken" {try Data("exit 1\n".utf8).write(to:runtime.appendingPathComponent("library-selector"))}
        }
        if fault == "changed-current" {try sentinel.write(to:active)}
        if fault == "linked-current" {try FileManager.default.removeItem(at:active);try FileManager.default.createSymbolicLink(at:active,withDestinationURL:data.appendingPathComponent("clover/settings.json"))}
        if fault == "pending" {try sentinel.write(to:n.appendingPathComponent("descriptions/"+menu.id.uuidString+".rollback"))}
        if fault.hasPrefix("resume-") {try (fault == "resume-prefix" ? Data(oldBytes.prefix(oldBytes.count/2)):Data([255])).write(to:n.appendingPathComponent("descriptions/"+menu.id.uuidString+".rollback"))}
        let source=request.script.replacingOccurrences(of:"/mnt/swifthakchi",with:runtime.path).replacingOccurrences(of:"/var/lib",with:data.path)
            .replacingOccurrences(of:"/etc/clover",with:root.path).replacingOccurrences(of:"/proc/mounts",with:root.appendingPathComponent("mounts").path)
            .replacingOccurrences(of:SNESRAMProbeScripts.busyboxSHA256,with:pin)
            .replacingOccurrences(of:runtimeHash,with:BackupManifest.digest(try Data(contentsOf:runtime.appendingPathComponent("runtime-files.sha256"))))
        let command=root.appendingPathComponent("rollback.sh");try Data(source.utf8).write(to:command)
        let (status,raw,error)=try await Self.runScript(command)
        #expect(try Data(contentsOf:data.appendingPathComponent("clover/settings.json"))==sentinel)
        #expect(try Data(contentsOf:n.appendingPathComponent("objects/protected"))==sentinel)
        #expect(try Data(contentsOf:stage.appendingPathComponent("menu.manifest"))==SNESLibraryStartupScripts.manifest(for:menu))
        if fault == "valid" || fault == "resume-prefix" {
            #expect(status==0,"\(String(decoding:error,as:UTF8.self))")
            _=try SNESLibraryRollbackReceipt(raw,request:request)
            if kind == "empty" || kind == "legacy" {#expect(!FileManager.default.fileExists(atPath:active.path))}
            else {#expect(try Data(contentsOf:active)==oldBytes)}
            if kind == "legacy" {#expect(try Data(contentsOf:l.appendingPathComponent("active-menu"))==oldBytes)}
            #expect(!FileManager.default.fileExists(atPath:n.appendingPathComponent("descriptions/"+menu.id.uuidString+".rollback").path))
            #expect(throws:(any Error).self) {try SNESLibraryRollbackReceipt(raw+Data([10]),request:request)}
        } else {
            #expect(status != 0)
            #expect(throws:(any Error).self) {try SNESLibraryRollbackReceipt(raw,request:request)}
            #expect(try Data(contentsOf:active)==(fault == "linked-current" || fault == "changed-current" ? sentinel:selector))
        }
        if let export=ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ROLLBACK_ARM_EXPORT"],fault == "valid" {
            let target=(native ? URL(fileURLWithPath:export).appendingPathComponent("native"):URL(fileURLWithPath:export)).appendingPathComponent(kind)
            try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
            try Data(request.script.utf8).write(to:target.appendingPathComponent("rollback.sh"),options:.withoutOverwriting)
            let resume=try SNESLibraryRollbackCommands.prepare(menu:menu,previous:previous,current:current,runtimeSHA256:runtimeHash,challenge:UUID(),recoverPending:true)
            try Data(resume.script.utf8).write(to:target.appendingPathComponent("resume.sh"),options:.withoutOverwriting)
            let pending=try SNESLibraryRollbackPendingCommands.prepare(id:menu.id,context:current.contextSHA256,hwid:current.hwid,runtime:runtimeHash,challenge:UUID())
            try Data(pending.script.utf8).write(to:target.appendingPathComponent("pending.sh"),options:.withoutOverwriting)
            let values:[String:Any] = ["kind":kind,"resumeExpected":resume.receipt.base64EncodedString(),"pendingExpected":pending.receipt.base64EncodedString(),"id":menu.id.uuidString,"oldID":kind == "legacy" ? legacy.id.uuidString:old.id.uuidString,
                "oldSelector":oldBytes.base64EncodedString(),"selector":selector.base64EncodedString(),"expected":request.receipt.base64EncodedString(),
                "files":menu.files.mapValues {$0.base64EncodedString()},"objects":menu.objects.mapValues {$0.base64EncodedString()},
                "manifest":try SNESLibraryStartupScripts.manifest(for:menu).base64EncodedString(),"description":menu.manifest.base64EncodedString(),
                "oldFiles":old.files.mapValues {$0.base64EncodedString()},"oldManifest":try SNESLibraryStartupScripts.manifest(for:old).base64EncodedString(),"oldDescription":old.manifest.base64EncodedString(),
                "legacyFiles":legacy.files.mapValues {$0.base64EncodedString()},"legacyManifest":legacy.manifest.base64EncodedString(),
                "stock":Dictionary(uniqueKeysWithValues:originals.entries.flatMap {e in e.files.filter {$0.name.hasSuffix(".desktop")}.map {(e.code+"/"+$0.name,$0.data.base64EncodedString())}})]
            try JSONSerialization.data(withJSONObject:values,options:[.sortedKeys]).write(to:target.appendingPathComponent("fixture.json"),options:.withoutOverwriting)
            try Data(SNESLibraryStartupScripts.verifier.utf8).write(to:target.appendingPathComponent("library-selector"),options:.withoutOverwriting)
            try Data(SNESMenuAdapterScripts.verifier.utf8).write(to:target.appendingPathComponent("menu-selector"),options:.withoutOverwriting)
        }
    }
    /// Process/pipe calls block; keep the host fixture off the shared UI actor.
    nonisolated static func runScript(_ command:URL) async throws->(Int32,Data,Data) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos:.userInitiated).async {
                do {
                    let process=Process(),out=Pipe(),err=Pipe()
                    process.executableURL=URL(fileURLWithPath:"/bin/sh");process.arguments=[command.path]
                    process.standardOutput=out;process.standardError=err
                    try process.run()
                    let raw=out.fileHandleForReading.readDataToEndOfFile(),error=err.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning:(process.terminationStatus,raw,error))
                } catch {continuation.resume(throwing:error)}
            }
        }
    }

}
