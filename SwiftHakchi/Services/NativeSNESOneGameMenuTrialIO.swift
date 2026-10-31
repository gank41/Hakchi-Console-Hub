import Foundation
actor NativeSNESOneGameMenuTrialIO:SNESOneGameMenuTrialIO {
 private let material:SNESOneGameMaterial
 private var client:LegacyInspectionClient?
 init(material:SNESOneGameMaterial){self.material=material}
 func inventory()throws->[RecoveryProbeUSBDevice] {try material.validate();return try RecoveryProbeUSBRegistry.inventory()}
 func connect(expected:RecoveryProbeUSBDevice) async throws {
  try material.validate();guard client==nil,expected.deviceVersion==0x6a04,!material.accepted.material.trial.candidate.hasMenuSupport else {throw SNESOneGameMenu.failure()}
  _=try SNESStartupTrialUSBPolicy.nativeIdentity(expected)
  let next=LegacyInspectionClient(transport:SNESStartupTrialUSBTransport(expected:expected),maximumOutputBytes:16384,retainIncompleteOutput:true);client=next
  try await next.connect(timeoutMilliseconds:10000);try material.validate()
 }
 private func require(_ m:SNESOneGameMaterial)throws {try material.validate();try m.validate();guard m.reviewSHA256==material.reviewSHA256 else {throw SNESOneGameMenu.failure()}}
 private func output(_ result:SSHResult,maximum:Int=4096)throws->Data {
  try material.validate();guard result.succeeded,result.stdoutData.count<=maximum else {
   FileHandle.standardError.write(Data(("Temporary SNES menu command did not complete.\n"+String(result.stderr.prefix(2048))+"\n").utf8));throw SNESOneGameMenu.failure()
  };return result.stdoutData
 }
 func report(challenge:UUID) async throws->Data {
  try material.validate();guard let client else {throw LegacyInspectionError.disconnected}
  return try output(await client.readSNESStartupTrial(material.accepted.material.trial,challenge:challenge),maximum:16384)
 }
 func inspect(_ m:SNESOneGameMaterial,challenge:UUID) async throws->Data {
  try require(m);guard let client else {throw LegacyInspectionError.disconnected};return try output(await client.inspectSNESOneGame(m,challenge:challenge),maximum:16384)
 }
 func menuState(_ m:SNESOneGameMaterial,challenge:UUID,original:Bool) async throws->Data {
  try require(m);guard let client else {throw LegacyInspectionError.disconnected};return try output(await client.readSNESOneGameMenuState(m,challenge:challenge,original:original))
 }
 func start(_ m:SNESOneGameMaterial,permit:SNESOneGameMenuTrialPermit) async throws->Data {
  try require(m);try permit.require(m);guard let client else {throw LegacyInspectionError.disconnected};return try output(await client.startSNESOneGameMenuTrial(m,permit:permit))
 }
 func trialStartupReport(_ m:SNESOneGameMaterial,challenge:UUID) async throws->Data {
  try require(m);guard let client else {throw LegacyInspectionError.disconnected};return try output(await client.readSNESOneGameMenuTrialStartup(m,challenge:challenge),maximum:16384)
 }
 func disconnect() async {await client?.disconnect();client=nil}
}
