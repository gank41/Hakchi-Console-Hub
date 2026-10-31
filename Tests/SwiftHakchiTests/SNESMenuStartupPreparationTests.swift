import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

func menuStartupParentFixture(_ root:URL,accepted:Bool=true) async throws -> (SNESFirmwareJournal,URL) {
 let path=try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_MENU_PARENT"]),source=URL(fileURLWithPath:path),transactions=root.appendingPathComponent("transactions"),operation=transactions.appendingPathComponent(source.lastPathComponent)
 try FileManager.default.createDirectory(at:transactions,withIntermediateDirectories:false)
 try FileManager.default.copyItem(at:source,to:operation)
 if !accepted {let records=try FileManager.default.contentsOfDirectory(at:operation,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("0")}.sorted{$0.lastPathComponent<$1.lastPathComponent};try FileManager.default.removeItem(at:try #require(records.last))}
 let review=BackupManifest.digest(try Data(contentsOf:operation.appendingPathComponent("plan.json"))),pins=try PinnedFELInputs.load()
 return (try await SNESFirmwareJournal.reopen(operation:operation,reviewSHA256:review,recovery:.init(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage)),operation)
}
@Suite(.serialized)
struct SNESMenuStartupPreparationTests {
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_MENU_PARENT"] != nil))
 func acceptedParentProducesOnlyMatchedMenuCandidateAndDetectsHistoryChange() async throws {
  let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let (journal,operation)=try await menuStartupParentFixture(root),accepted=try await journal.acceptedInstall(),parent=try await journal.menuStartupParent();try await journal.close()
  let candidate=parent.candidate;try parent.require(candidate)
  #expect(candidate.hasMenuSupport && candidate.image.count<=4194304)
  let original=try LegacyBootImageBuilder.inspect(accepted.material.trial.image),new=try LegacyBootImageBuilder.inspect(candidate.image)
  #expect(original.kernel==new.kernel && original.header[64..<576]==new.header[64..<576])
  #expect(candidate.backup.directory==accepted.material.trial.candidate.backup.directory)
  #expect(parent.activeImage==accepted.material.trial.image && parent.record.operationID==accepted.material.id)
  #expect(throws:(any Error).self) {try parent.require(accepted.material.trial.candidate)}
  let file=operation.appendingPathComponent("plan.json"),handle=try FileHandle(forWritingTo:file);try handle.seekToEnd();try handle.write(contentsOf:Data([32]));try handle.close()
  #expect(throws:(any Error).self) {try parent.validate()}
 }
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_MENU_PARENT"] != nil))
 func unacceptedStartupCannotIssueMenuPreparation() async throws {
  let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let (journal,_)=try await menuStartupParentFixture(root,accepted:false)
  await #expect(throws:(any Error).self) {try await journal.menuStartupParent()};try await journal.close()
 }
}
