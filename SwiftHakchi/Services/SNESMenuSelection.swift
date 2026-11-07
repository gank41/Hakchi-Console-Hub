import Foundation

/// A durable intent exists even when cancellation/source changes prevent an
/// uncertainty record. Never present an unverified publication as a failed copy.
struct SNESMenuSelectionUnverified:LocalizedError,Sendable {
 let operation:URL,reviewSHA256:String
 var errorDescription:String? {
  "The console’s game menu may already be updated, but the app could not verify completion. The change was attempted at most once. Do not repeat it. Run a read-only check of this operation before another action.\nRecovery record: \(operation.path)\nReview: \(reviewSHA256)"
 }
}

protocol SNESMenuSelectionIO:SNESInstalledStartupIO {
 func inspect(challenge:UUID) async throws->Data
 func publish(permit:SNESMenuSelectionPermit) async throws->Data
}
actor SNESMenuSelectionService {
 private var busy=false
 private func attachment(_ m:SNESMenuSelectionMaterial,_ io:any SNESMenuSelectionIO,_ d:RecoveryProbeUSBDevice) async throws {
  try m.validate();guard try await io.inventory()==[d] else {throw SNESOneGameMenu.failure()};try m.validate()
 }
 private func connect(_ m:SNESMenuSelectionMaterial,_ io:any SNESMenuSelectionIO) async throws->RecoveryProbeUSBDevice {
  try m.validate();let devices=try await io.inventory();try m.validate()
  guard devices.count==1,let d=devices.first,d.deviceVersion==0x6a05 else {throw SNESOneGameMenu.failure()}
  _=try SNESStartupTrialUSBPolicy.nativeIdentity(d);try await io.connect(expected:d);try await attachment(m,io,d);return d
 }
 private func report(_ m:SNESMenuSelectionMaterial,_ io:any SNESMenuSelectionIO,_ d:RecoveryProbeUSBDevice) async throws->SNESStartupTrialReport {
  try await attachment(m,io,d);let c=UUID(),raw=try await io.report(challenge:c);try m.validate()
  let r=try SNESStartupTrialReport(raw,expected:SNESStartupTrialExpectation.checked(m.installed.material.trial),challenge:c);try await attachment(m,io,d);return r
 }
 private func inspect(_ m:SNESMenuSelectionMaterial,_ io:any SNESMenuSelectionIO,_ d:RecoveryProbeUSBDevice) async throws->SNESMenuSelectionReceipt {
  try await attachment(m,io,d);let c=UUID(),raw=try await io.inspect(challenge:c);try m.validate()
  let r=try m.receipt(raw,challenge:c);try await attachment(m,io,d);return r
 }
 func select(material m:SNESMenuSelectionMaterial,journal:SNESMenuSelectionJournal,io:any SNESMenuSelectionIO) async throws->SNESMenuSelectionReceipt {
  guard !busy else {throw LegacyInspectionError.busy};busy=true;defer{busy=false};var intent=false,closed=false
  do {
   try m.validate();guard try await journal.phase() == .prepared else {throw SNESOneGameMenu.failure()}
   let d=try await connect(m,io),before=try await report(m,io,d),ready=try await inspect(m,io,d)
   guard !ready.selected,!ready.displaySelected else {throw SNESOneGameMenu.failure()}
   let permit=try await journal.begin();intent=true;try permit.require(m);try await attachment(m,io,d)
   let raw=try await io.publish(permit:permit);try m.validate()
   let receipt=try m.receipt(raw,challenge:permit.challenge);guard receipt.selected,!receipt.displaySelected else {throw SNESOneGameMenu.failure()}
   let checked=try await inspect(m,io,d),after=try await report(m,io,d)
   guard checked.selected,!checked.displaySelected,before.mcpPID==after.mcpPID,before.daemonPID==after.daemonPID else {throw SNESOneGameMenu.failure()}
   closed=true;await io.disconnect();try m.validate();try await journal.selected(checked);return checked
  } catch {
   if intent {try? await journal.uncertain()}
   if !closed {closed=true;await io.disconnect()}
   if intent {throw SNESMenuSelectionUnverified(operation:journal.operation,reviewSHA256:m.reviewSHA256)}
   throw error
  }
 }
 func inspect(material m:SNESMenuSelectionMaterial,io:any SNESMenuSelectionIO) async throws->SNESMenuSelectionReceipt {
  guard !busy else {throw LegacyInspectionError.busy};busy=true;defer{busy=false};var closed=false
  do {let d=try await connect(m,io);_=try await report(m,io,d);let r=try await inspect(m,io,d);closed=true;await io.disconnect();try m.validate();return r}
  catch {if !closed {closed=true;await io.disconnect()};throw error}
 }
 func checkStartup(material m:SNESMenuSelectionMaterial,journal:SNESMenuSelectionJournal,io:any SNESMenuSelectionIO) async throws->SNESMenuSelectionReceipt {
  guard !busy else {throw LegacyInspectionError.busy};busy=true;defer{busy=false};var closed=false
  do {
   try m.validate();guard try await journal.phase() == .selected else {throw SNESOneGameMenu.failure()}
   let d=try await connect(m,io),first=try await report(m,io,d),r=try await inspect(m,io,d),last=try await report(m,io,d)
   guard r.selected,r.displaySelected,first.mcpPID==last.mcpPID,first.daemonPID==last.daemonPID else {throw SNESOneGameMenu.failure()}
   closed=true;await io.disconnect();try m.validate();try await journal.startupVerified(r);return r
  } catch {if !closed {closed=true;await io.disconnect()};throw error}
 }
}
