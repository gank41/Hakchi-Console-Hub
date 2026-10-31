import Foundation
protocol SNESOneGameMenuTrialIO:SNESInstalledStartupIO {
 func inspect(_ material:SNESOneGameMaterial,challenge:UUID) async throws->Data
 func menuState(_ material:SNESOneGameMaterial,challenge:UUID,original:Bool) async throws->Data
 func start(_ material:SNESOneGameMaterial,permit:SNESOneGameMenuTrialPermit) async throws->Data
 func trialStartupReport(_ material:SNESOneGameMaterial,challenge:UUID) async throws->Data
}
actor SNESOneGameMenuTrialService {
 private var busy=false
 private func attachment(_ m:SNESOneGameMaterial,_ io:any SNESOneGameMenuTrialIO,_ device:RecoveryProbeUSBDevice) async throws {
  try m.validate();guard try await io.inventory()==[device] else {throw SNESOneGameMenu.failure()};try m.validate()
 }
 private func connect(_ m:SNESOneGameMaterial,_ io:any SNESOneGameMenuTrialIO) async throws->RecoveryProbeUSBDevice {
  try m.validate();guard !m.accepted.material.trial.candidate.hasMenuSupport else {throw SNESOneGameMenu.failure()}
  let devices=try await io.inventory();try m.validate();guard devices.count==1,let d=devices.first,d.deviceVersion==0x6a04 else {throw SNESOneGameMenu.failure()}
  _=try SNESStartupTrialUSBPolicy.nativeIdentity(d);try await io.connect(expected:d);try await attachment(m,io,d);return d
 }
 private func startup(_ m:SNESOneGameMaterial,_ io:any SNESOneGameMenuTrialIO,_ device:RecoveryProbeUSBDevice,original:Bool) async throws->SNESStartupTrialReport {
  try await attachment(m,io,device);let c=UUID(),raw:Data
  if original {raw=try await io.report(challenge:c)} else {raw=try await io.trialStartupReport(m,challenge:c)}
  try m.validate();let report=try SNESStartupTrialReport(raw,expected:SNESStartupTrialExpectation.checked(m.accepted.material.trial),challenge:c,temporaryMenu:!original)
  try await attachment(m,io,device);return report
 }
 private func state(_ m:SNESOneGameMaterial,_ io:any SNESOneGameMenuTrialIO,_ device:RecoveryProbeUSBDevice,original:Bool) async throws->SNESOneGameMenuTrialReceipt {
  try await attachment(m,io,device);let c=UUID(),raw=try await io.menuState(m,challenge:c,original:original);try m.validate()
  let receipt=try SNESOneGameMenuTrialReceipt(raw,id:m.menu.id,tree:m.menu.treeSHA256,binding:m.accepted.material.trial.candidate.material.binding,challenge:c,original:original)
  try await attachment(m,io,device);return receipt
 }
 func start(material m:SNESOneGameMaterial,journal:SNESOneGameStageJournal,io:any SNESOneGameMenuTrialIO) async throws->SNESOneGameMenuTrialReceipt {
  guard !busy else {throw LegacyInspectionError.busy};busy=true;defer{busy=false}
  var closed=false,intent=false
  do {
   try m.validate();guard [.inactiveVerified,.menuTrialReturned].contains(try await journal.phase()) else {throw SNESOneGameMenu.failure()}
   let d=try await connect(m,io),before=try await startup(m,io,d,original:true),c=UUID(),raw=try await io.inspect(m,challenge:c)
   try m.validate();let inspection=try SNESOneGameInspectionReceipt(raw,menu:m.menu,binding:m.accepted.material.trial.candidate.material.binding,challenge:c)
   guard inspection.matchesMenu,inspection.selectorMissing else {throw SNESOneGameMenu.failure()}
   let ready=try await state(m,io,d,original:true);guard ready.mcpPID==before.mcpPID,ready.daemonPID==before.daemonPID else {throw SNESOneGameMenu.failure()}
   let permit=try await journal.beginMenuTrial();intent=true;try permit.require(m);try await attachment(m,io,d)
   let result=try await io.start(m,permit:permit);try m.validate()
   let shown=try SNESOneGameMenuTrialReceipt(result,id:m.menu.id,tree:m.menu.treeSHA256,binding:m.accepted.material.trial.candidate.material.binding,challenge:permit.challenge,original:false)
   guard shown.mcpPID != before.mcpPID,shown.daemonPID==before.daemonPID else {throw SNESOneGameMenu.failure()}
   let report=try await startup(m,io,d,original:false),checked=try await state(m,io,d,original:false)
   guard checked.mcpPID==shown.mcpPID,checked.daemonPID==shown.daemonPID,report.mcpPID==shown.mcpPID,report.daemonPID==shown.daemonPID else {throw SNESOneGameMenu.failure()}
   closed=true;await io.disconnect();try m.validate();try await journal.menuTrialShown(checked);return checked
  } catch {
   if intent {try? await journal.menuTrialFailed()}
   if !closed {closed=true;await io.disconnect()};throw error
  }
 }
 func check(material m:SNESOneGameMaterial,journal:SNESOneGameStageJournal,io:any SNESOneGameMenuTrialIO,original:Bool) async throws->SNESOneGameMenuTrialReceipt {
  guard !busy else {throw LegacyInspectionError.busy};busy=true;defer{busy=false}
  var closed=false
  do {
   try m.validate();let phase=try await journal.phase();guard phase == .menuTrialShown || original && [.menuTrialUncertain,.menuTrialIntent].contains(phase) else {throw SNESOneGameMenu.failure()}
   let d=try await connect(m,io),first=try await startup(m,io,d,original:original),receipt=try await state(m,io,d,original:original),last=try await startup(m,io,d,original:original)
   guard first.mcpPID==receipt.mcpPID,last.mcpPID==receipt.mcpPID,first.daemonPID==receipt.daemonPID,last.daemonPID==receipt.daemonPID else {throw SNESOneGameMenu.failure()}
   closed=true;await io.disconnect();try m.validate();if original {try await journal.menuTrialReturned(receipt)};return receipt
  } catch {if !closed {closed=true;await io.disconnect()};throw error}
 }
}
