import Foundation
import Testing
import os
@testable import SwiftHakchi

struct SNESMenuFirmwareDiagnosticTests {
 @Test(arguments:[["--prepare-snes-menu-firmware"],["--prepare-snes-menu-firmware","relative"],["--prepare-snes-menu-firmware","/tmp/request","extra"],["--prepare-snes-library-firmware"],["--prepare-snes-library-firmware","relative"],["--prepare-snes-library-firmware","/tmp/request","extra"]])
 func malformedRequestCannotLoadInputs(_ args:[String]) async throws {
  let calls=OSAllocatedUnfairLock(initialState:0)
  await #expect(throws:(any Error).self){try await SNESMenuFirmwareDiagnostic.runIfPresent(args,loadInputs:{calls.withLock{$0+=1};throw SNESRuntimeBinding.failure()})}
  #expect(calls.withLock{$0}==0)
 }
 @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_MENU_PLAYED"] != nil))
 func offlinePreparationCreatesReopenableUpgradeWithoutUSB() async throws {
  let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let (j,op)=try await menuStartupParentFixture(root),accepted=try await j.acceptedInstall();try await j.close()
  let request=SNESMenuFirmwareRequest(parentOperation:op.path,parentReviewSHA256:accepted.reviewSHA256,paths:try menuFirmwarePaths(accepted.material))
  let file=root.appendingPathComponent("request.json");try JSONEncoder().encode(request).write(to:file)
  let inputs=try menuFirmwareInputs(),transactions=op.deletingLastPathComponent()
  let text=try #require(try await SNESMenuFirmwareDiagnostic.runIfPresent(["--prepare-snes-menu-firmware",file.path],loadInputs:{inputs},root:{transactions},requireOperation:{_ in}))
  let result=try #require(JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any])
  #expect(result["USBOpened"] as? Bool==false && result["firmwareWritten"] as? Bool==false)
  let child=try #require(result["operation"] as? String),review=try #require(result["reviewSHA256"] as? String)
  let reopened=try await SNESFirmwareJournal.reopen(operation:URL(fileURLWithPath:child),reviewSHA256:review,recovery:inputs)
  #expect(try await reopened.phase() == .prepared)
  #expect(try await reopened.verifiedMaterial().preimage==accepted.material.target)
  try await reopened.close()
  let checked=try #require(try await SNESFirmwareDiagnostic.runIfPresent(["--preflight-snes-firmware",child,review],loadInputs:{inputs},requireOperation:{_ in},checkHost:{},makeIO:{m,_ in SNESFirmwareFakeIO(material:m,fault:"none")}))
  #expect(checked.contains("preflightVerified"))
 }
}
