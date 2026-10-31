import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

func oneGameMaterialFixture(_ root:URL) async throws -> (SNESFirmwareAcceptedInstall,SNESOneGamePaths) {
 let m=try await SNESFirmwareFixtureCache.shared.value(),g=try await SNESFirmwareGuardFixtureCache.shared.value()
 let journals=root.appendingPathComponent("firmware"),backups=root.appendingPathComponent("Backups"),game=root.appendingPathComponent("CLV-U-ABCDE")
 for d in [journals,backups,game] {try FileManager.default.createDirectory(at:d,withIntermediateDirectories:false)}
 let p=try SNESFirmwareJournal.prepare(material:m,root:journals,guard:g),j=try SNESFirmwareJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,guard:g)
 try await j.preflightVerified();_=try await j.beginWrite();try await j.readbackVerified();try await j.startupVerified();try await j.acceptMenu()
 let accepted=try await j.acceptedInstall();try await j.close()
 let launcher=try #require(m.trial.candidate.material.support.frame.records.first(where:{$0.path=="usr/bin/clover-canoe-shvc"})?.data)
 let io=OriginalCatalogPackageFake(expected:try .checked(m.trial),launcher:launcher),result=try await SNESOriginalGamesCapture().capture(accepted:accepted,guard:g,io:io),store=try RecoveryBootSnapshotStore(root:backups)
 let catalog=try await store.saveSNESOriginalGames(result)
 try oneGameMetadata.write(to:game.appendingPathComponent("CLV-U-ABCDE.desktop"));try oneGameSyntheticROM().write(to:game.appendingPathComponent("My Game.smc"));try oneGameSyntheticArt().write(to:game.appendingPathComponent("CLV-U-ABCDE.png"))
 return (accepted,.init(firmwareOperation:p.operation.path,firmwareReviewSHA256:p.reviewSHA256,catalogDirectory:catalog.path,gameDirectory:game.path,romFilename:"My Game.smc",backupsDirectory:backups.path))
}
@Suite(.serialized)
struct SNESOneGameMaterialTests {
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
 func freezesOnlyNewGameFilesAndSourceChangesInvalidateReview() async throws {
  let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
  let (accepted,paths)=try await oneGameMaterialFixture(root),m=try SNESOneGameMaterial.prepare(paths:paths,accepted:accepted)
  try m.validate();#expect(m.menu.gameCount==3 && m.bundle.count<1024*1024)
  let plan=try m.planData(),row=try #require(JSONSerialization.jsonObject(with:plan) as? [String:Any])
  #expect(row["scope"] as? String=="snes-one-game-inactive-copy" && row["selectorWillChange"] as? Bool==false && row["firmwareWriteRequested"] as? Bool==false)
  #expect(m.reviewSHA256==BackupManifest.digest(plan))
  #expect(m.bundle.starts(with:Data(("SWIFTHAKCHI_SNES_MENU_FILES_V1 "+m.menu.id.uuidString+"\n").utf8)))
  #expect(String(decoding:m.bundle.suffix(64),as:UTF8.self).contains("END 7\n"))
  #expect(try Data(contentsOf:URL(fileURLWithPath:paths.gameDirectory).appendingPathComponent("My Game.smc"))==oneGameSyntheticROM())
  try Data("Name=Changed\n".utf8).write(to:URL(fileURLWithPath:paths.gameDirectory).appendingPathComponent("CLV-U-ABCDE.desktop"))
  #expect(throws:(any Error).self) {try m.validate()}
 }
}
