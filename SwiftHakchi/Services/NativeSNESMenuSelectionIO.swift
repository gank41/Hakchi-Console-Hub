import Foundation

actor NativeSNESMenuSelectionIO:SNESMenuSelectionIO {
 private let material:SNESMenuSelectionMaterial
 private var client:LegacyInspectionClient?
 init(material:SNESMenuSelectionMaterial){self.material=material}
 func inventory()throws->[RecoveryProbeUSBDevice] {try material.validate();return try RecoveryProbeUSBRegistry.inventory()}
 func connect(expected:RecoveryProbeUSBDevice) async throws {
  try material.validate();guard client==nil,expected.deviceVersion==0x6a05 else {throw SNESOneGameMenu.failure()}
  _=try SNESStartupTrialUSBPolicy.nativeIdentity(expected)
  let next=LegacyInspectionClient(transport:SNESStartupTrialUSBTransport(expected:expected),maximumOutputBytes:16384,retainIncompleteOutput:true);client=next
  try await next.connect(timeoutMilliseconds:10000);try material.validate()
 }
 private func output(_ r:SSHResult,stage:String)throws->Data {
  try material.validate();guard r.succeeded,r.stdoutData.count<=16384 else {
   FileHandle.standardError.write(Data(("The saved menu operation did not complete at \(stage) (exit \(r.exitCode), \(r.stdoutData.count) output bytes).\n"+String(r.stderr.prefix(2048))+"\n").utf8));throw SNESOneGameMenu.failure()
  };return r.stdoutData
 }
 func report(challenge:UUID) async throws->Data {
  try material.validate();guard let client else {throw LegacyInspectionError.disconnected}
  return try output(await client.readSNESStartupTrial(material.installed.material.trial,challenge:challenge),stage:"startup report")
 }
 func inspect(challenge:UUID) async throws->Data {
  try material.validate();guard let client else {throw LegacyInspectionError.disconnected}
  return try output(await client.inspectSNESMenuSelection(material,challenge:challenge),stage:"menu inspection")
 }
 func publish(permit:SNESMenuSelectionPermit) async throws->Data {
  try permit.require(material);guard let client else {throw LegacyInspectionError.disconnected}
  return try output(await client.publishSNESMenuSelection(material,permit:permit),stage:"menu selection save")
 }
 func disconnect() async {await client?.disconnect();client=nil}
}
