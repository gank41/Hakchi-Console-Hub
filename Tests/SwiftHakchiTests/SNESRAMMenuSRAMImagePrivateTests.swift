import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESRAMMenuSRAMImagePrivateTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HC_SRAM_MENU_PREVIEW"] != nil, "Requires private local trial files"))
    func imageContainsTheVerifiedSaveOwnerAndCorrectGame() async throws {
        let env = ProcessInfo.processInfo.environment
        let preview = try Data(contentsOf: URL(fileURLWithPath: try #require(env["HC_SRAM_MENU_PREVIEW"])))
        let json = try #require(JSONSerialization.jsonObject(with: preview) as? [String: Any])
        let paths = try #require(json["paths"] as? [String]).map { URL(fileURLWithPath: $0) }
        #expect(paths.count == 15 || paths.count == 19)
        let nonceText = try #require(json["nonce"] as? String)
        let nonce = try #require(UUID(uuidString: nonceText))
        func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }
        func payload(_ root: URL, names: [String]) throws -> [String: Data] {
            var values: [String: Data] = [:]
            for name in names { values[name] = try read(root.appendingPathComponent(name)) }
            values["autoconfig/Nintendo Clovercon - controller1.cfg"] = try read(root.appendingPathComponent("autoconfig/Nintendo Clovercon - controller1.cfg"))
            return values
        }
        let setup = try SNESOfflineSource.load(snapshot: paths[0])
        let source = try SNESMenuSupportSource.load(setup: setup, preparation: paths[1])
        let support = try SNESMenuSupportMaterial.load(source: source, directory: paths[2])
        let components = try SNESOriginalComponentMaterial.load(source: SNESOriginalComponentSource(material: support), directory: paths[3])
        let runtime = try SNESRuntimeMaterial.load(directory: paths[4], source: setup)
        let material = try SNESOriginalMenuMaterial(components: components, runtime: runtime)
        let base = try SNESOriginalMenuRecipe.prepare(material: material, archivedImage: read(paths[5]), recovery: await PayloadService.shared.pinnedRecoveryInputs(), nonce: nonce)
        let alien = try payload(paths[6], names: ["retroarch", "snes9x2010_libretro.so", "alien3.smc", "retroarch.cfg", "trial-start", "trial-owner"])
        let save = try payload(paths[12], names: ["retroarch", "snes9x2010_libretro.so", "simcity.smc", "retroarch.cfg", "trial-start", "trial-sram-owner"])
        let simOwner = try read(paths[14])
        let zelda = paths.count == 19 && paths[15].lastPathComponent == "zelda.smc"
        let owner: Data, image: SNESRAMCompatibilityMenuBuilder.Result
        if zelda {
            owner = try read(paths[17])
            image = try SNESRAMMenuZeldaTrialBuilder.build(source: base.image, alienPayload: alien, alienReport: read(paths[7]), artwork: read(paths[9]), resetOwner: read(paths[10]), signalOwner: read(paths[11]), savePayload: save, saveReport: read(paths[13]), saveMenuOwner: simOwner, rom: read(paths[15]), config: read(paths[16]), owner: owner, reentry: read(paths[18]))
        } else if paths.count == 19 {
            owner = try read(paths[17])
            image = try SNESRAMMenuDKC3TrialBuilder.build(source: base.image, alienPayload: alien, alienReport: read(paths[7]), artwork: read(paths[9]), resetOwner: read(paths[10]), signalOwner: read(paths[11]), savePayload: save, saveReport: read(paths[13]), saveMenuOwner: simOwner, rom: read(paths[15]), config: read(paths[16]), owner: owner, reentry: read(paths[18]))
        } else {
            owner = simOwner
            image = try SNESRAMMenuSRAMTrialBuilder.build(source: base.image, alienPayload: alien, alienReport: read(paths[7]), artwork: read(paths[9]), resetOwner: read(paths[10]), signalOwner: read(paths[11]), savePayload: save, saveReport: read(paths[13]), saveMenuOwner: owner)
        }
        #expect(BackupManifest.digest(image.image) == (json["imageSHA256"] as? String))
        let archive = try LegacyBootImageBuilder.inspect(image.image).archive
        let files = Dictionary(uniqueKeysWithValues: archive.entries.map { ($0.name, $0.data) })
        if paths.count == 19 {
            let expectedROM = try read(paths[15]), expectedConfig = try read(paths[16])
            #expect(files[zelda ? "probe/compat/zelda.smc" : "probe/compat/dkc3.smc"] == expectedROM)
            #expect(files["probe/compat/simcity.smc"] == nil)
            #expect(files["probe/compat/retroarch.cfg"] == expectedConfig)
        } else {
            #expect(files["probe/compat/simcity.smc"] == save["simcity.smc"])
        }
        #expect(files["probe/compat/alien3.smc"] == nil)
        #expect(files["probe/compat/trial-menu-owner"] == owner)
        #expect(files["probe/compat/retroarch"] == save["retroarch"])
        let script = try #require(files["probe/compat/trial-start"].flatMap { String(data: $0, encoding: .utf8) })
        #expect(script.contains(zelda ? "/tmp/hc-zelda-trial" : (paths.count == 19 ? "/tmp/hc-dkc3-trial" : "/tmp/hc-simcity-trial")))
        #expect(script.contains(zelda ? SNESRAMMenuZeldaTrialBuilder.ownerSHA256 : (paths.count == 19 ? SNESRAMMenuDKC3TrialBuilder.ownerSHA256 : SNESRAMMenuSRAMTrialBuilder.ownerSHA256)))
        if paths.count == 19 { #expect(script.contains("trial-owner-lifecycle.first") || script.contains("$name.first")) }
        #expect(script.contains("\"$R/trial-menu-owner\" \"$waitfd\" \"$startfd\" \"$finishfd\""))
        let desktop = try #require(files["probe/menu/CLV-U-ZZZZZ/CLV-U-ZZZZZ.desktop"].flatMap { String(data: $0, encoding: .utf8) })
        #expect(desktop.contains(zelda ? "Name=Zelda (Temporary Test)" : (paths.count == 19 ? "Name=Donkey Kong Country 3 (Temporary Test)" : "Name=Sim City 2000 (Temporary Test)")))
        if zelda {
            #expect(throws: (any Error).self) { try SNESRAMMenuZeldaTrialBuilder.build(source: base.image, alienPayload: alien, alienReport: read(paths[7]), artwork: read(paths[9]), resetOwner: read(paths[10]), signalOwner: read(paths[11]), savePayload: save, saveReport: read(paths[13]), saveMenuOwner: simOwner, rom: read(paths[15]), config: read(paths[16]), owner: Data([0]), reentry: read(paths[18])) }
        } else if paths.count == 19 {
            #expect(throws: (any Error).self) { try SNESRAMMenuDKC3TrialBuilder.build(source: base.image, alienPayload: alien, alienReport: read(paths[7]), artwork: read(paths[9]), resetOwner: read(paths[10]), signalOwner: read(paths[11]), savePayload: save, saveReport: read(paths[13]), saveMenuOwner: simOwner, rom: read(paths[15]), config: read(paths[16]), owner: Data([0]), reentry: read(paths[18])) }
        } else {
            #expect(throws: (any Error).self) { try SNESRAMMenuSRAMTrialBuilder.build(source: base.image, alienPayload: alien, alienReport: read(paths[7]), artwork: read(paths[9]), resetOwner: read(paths[10]), signalOwner: read(paths[11]), savePayload: save, saveReport: read(paths[13]), saveMenuOwner: Data([0])) }
        }
    }
}
