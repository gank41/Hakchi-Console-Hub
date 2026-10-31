import Foundation
import Darwin
import SwiftHakchiCore

struct SNESMenuSelectionPermit:Sendable {
 let id:UUID,reviewSHA256:String,challenge:UUID
 fileprivate init(id:UUID,reviewSHA256:String,challenge:UUID){self.id=id;self.reviewSHA256=reviewSHA256;self.challenge=challenge}
 func require(_ m:SNESMenuSelectionMaterial)throws {try m.validate();guard id==m.id,reviewSHA256==m.reviewSHA256 else {throw SNESOneGameMenu.failure()}}
}
enum SNESMenuSelectionPolicy {
 static func root()throws->URL {
  guard let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first else {throw RestoreDirectory.failure()}
  return support.appendingPathComponent("SwiftHakchi/MenuSelectionTransactions/SNES",isDirectory:true).standardizedFileURL
 }
 static func ensureRoot()throws->URL {
  let url=try root();guard url==url.resolvingSymlinksInPath() else {throw RestoreDirectory.failure()}
  try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);return try RestoreDirectory(url).url
 }
 static func requireOperation(_ url:URL)throws {
  let u=url.standardizedFileURL,prefix="SNESMenuSelection-"
  guard u.deletingLastPathComponent().path==(try root()).path,u.lastPathComponent.hasPrefix(prefix),UUID(uuidString:String(u.lastPathComponent.dropFirst(prefix.count))) != nil else {throw RestoreDirectory.failure()}
 }
}
actor SNESMenuSelectionJournal {
 enum Phase:String,Codable,Sendable {case prepared,intent,selected,uncertain,startupVerified,accepted}
 struct Prepared:Sendable {let operation:URL,reviewSHA256:String}
 private struct Record:Codable {let phase:Phase,planSHA256:String,previousSHA256:String?,challenge:UUID?,receipt:Data?}
 private struct State {let phase:Phase,count:Int,lastSHA256:String}
 private let storage:RestoreJournalStorage,material:SNESMenuSelectionMaterial
 let reviewSHA256:String
 let operation:URL
 private static func encode<T:Encodable>(_ value:T)throws->Data {let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];return try e.encode(value)}
 init(operation:URL,reviewSHA256:String,material:SNESMenuSelectionMaterial)throws {
  try material.validate();guard reviewSHA256==material.reviewSHA256 else {throw RestoreDirectory.failure()}
  storage=try RestoreJournalStorage(root:operation.deletingLastPathComponent(),operation:operation);self.material=material;self.reviewSHA256=reviewSHA256;self.operation=operation
  try storage.checkLock()
  guard try storage.operation!.read("plan.json",maximum:32768)==material.planData() else {throw RestoreDirectory.failure()}
  try Self.others(storage,excluding:operation.lastPathComponent,binding:material.binding)
  _=try Self.load(storage.operation!,review:reviewSHA256)
 }
 static func prepare(material m:SNESMenuSelectionMaterial,root:URL)throws->Prepared {
  try m.validate();let s=try RestoreJournalStorage(root:root);try others(s,excluding:nil,binding:m.binding)
  let name="SNESMenuSelection-"+m.id.uuidString;guard mkdirat(s.root.fd,name,0o700)==0 else {throw RestoreDirectory.failure()}
  let d=try RestoreDirectory(s.root.url.appendingPathComponent(name))
  try s.write(m.planData(),name:"plan.json",directory:d)
  try s.write(encode(Record(phase:.prepared,planSHA256:m.reviewSHA256,previousSHA256:nil,challenge:nil,receipt:nil)),name:"0000.json",directory:d)
  try m.validate();try s.sync(d);try s.sync(s.root);try s.closeLease();return .init(operation:d.url,reviewSHA256:m.reviewSHA256)
 }
 static func readPlan(operation:URL,reviewSHA256:String)throws->SNESMenuSelectionMaterial.Plan {
  let d=try RestoreDirectory(operation),raw=try d.read("plan.json",maximum:32768)
  guard SNESDataSnapshotChunk.isDigest(reviewSHA256),BackupManifest.digest(raw)==reviewSHA256 else {throw RestoreDirectory.failure()}
  _=try load(d,review:reviewSHA256)
  return try JSONDecoder().decode(SNESMenuSelectionMaterial.Plan.self,from:raw)
 }
 func phase()throws->Phase {try state().phase}
 func begin()throws->SNESMenuSelectionPermit {
  guard try state().phase == .prepared else {throw SNESOneGameMenu.failure()};let c=UUID()
  try append(.intent,challenge:c,receipt:nil);return .init(id:material.id,reviewSHA256:reviewSHA256,challenge:c)
 }
 func selected(_ r:SNESMenuSelectionReceipt)throws {guard try state().phase == .intent,r.selected,!r.displaySelected else {throw SNESOneGameMenu.failure()};try append(.selected,challenge:r.challenge,receipt:r.raw)}
 func uncertain()throws {guard try state().phase == .intent else {throw SNESOneGameMenu.failure()};try append(.uncertain,challenge:nil,receipt:nil)}
 func startupVerified(_ r:SNESMenuSelectionReceipt)throws {guard try state().phase == .selected,r.selected,r.displaySelected else {throw SNESOneGameMenu.failure()};try append(.startupVerified,challenge:r.challenge,receipt:r.raw)}
 func accept()throws {guard try state().phase == .startupVerified else {throw SNESOneGameMenu.failure()};try append(.accepted,challenge:nil,receipt:nil)}
 func close()throws {try storage.closeLease()}
 private func state()throws->State {
  try material.validate();try storage.checkLock();let d=storage.operation!
  guard try d.read("plan.json",maximum:32768)==material.planData() else {throw RestoreDirectory.failure()}
  try Self.others(storage,excluding:d.url.lastPathComponent,binding:material.binding)
  return try Self.load(d,review:reviewSHA256)
 }
 private func append(_ phase:Phase,challenge:UUID?,receipt:Data?)throws {
  let s=try state();try storage.write(Self.encode(Record(phase:phase,planSHA256:reviewSHA256,previousSHA256:s.lastSHA256,challenge:challenge,receipt:receipt)),name:String(format:"%04d.json",s.count),directory:storage.operation!)
  try storage.sync(storage.operation!);try storage.sync(storage.root);guard try state().phase==phase else {throw RestoreDirectory.failure()}
 }
 private static func load(_ d:RestoreDirectory,review:String)throws->State {
  let raw=try d.read("plan.json",maximum:32768),p=try JSONDecoder().decode(SNESMenuSelectionMaterial.Plan.self,from:raw)
  guard BackupManifest.digest(raw)==review,p.schemaVersion==1,p.scope=="snes-persistent-one-game-menu",d.url.lastPathComponent=="SNESMenuSelection-"+p.id.uuidString,
    [p.treeSHA256,p.selectorSHA256,p.gameMaterialSHA256].allSatisfy(SNESDataSnapshotChunk.isDigest),(1...192).contains(p.selectorBytes),(2...35).contains(p.gameCount) else {throw RestoreDirectory.failure()}
  try p.request.validate();try p.binding.validate()
  let names=try d.names().filter{$0 != "plan.json"};guard (1...6).contains(names.count) else {throw RestoreDirectory.failure()}
  var phase:Phase?,previous:String?,challenges=Set<UUID>()
  for (i,name) in names.enumerated() {
   guard name==String(format:"%04d.json",i) else {throw RestoreDirectory.failure()}
   let bytes=try d.read(name,maximum:8192),r=try JSONDecoder().decode(Record.self,from:bytes)
   guard r.planSHA256==review,r.previousSHA256==previous,try encode(r)==bytes else {throw RestoreDirectory.failure()}
   if let c=r.challenge {guard challenges.insert(c).inserted else {throw RestoreDirectory.failure()}}
   switch (phase,r.phase) {
   case (nil,.prepared),(.intent,.uncertain),(.startupVerified,.accepted):guard r.challenge==nil,r.receipt==nil else {throw RestoreDirectory.failure()}
   case (.prepared,.intent):guard r.challenge != nil,r.receipt==nil else {throw RestoreDirectory.failure()}
   case (.intent,.selected),(.selected,.startupVerified):
    guard let c=r.challenge,let raw=r.receipt,raw.count<=2048,let t=String(data:raw,encoding:.ascii) else {throw RestoreDirectory.failure()}
    let expected="SWIFTHAKCHI_SNES_MENU_SELECTION_V1\nCHALLENGE=\(c.uuidString)\nHWID=\(p.binding.expectedHWID)\nOPERATION=\(p.id.uuidString)\nID=\(p.menuID.uuidString)\nTREE=\(p.treeSHA256)\nSELECTOR=\(p.selectorSHA256)\nDISPLAY=\(r.phase == .selected ? "original":"selected")\nEND\n"
    guard t==expected else {throw RestoreDirectory.failure()}
   default:throw RestoreDirectory.failure()
   }
   phase=r.phase;previous=BackupManifest.digest(bytes)
  }
  try d.check();return .init(phase:phase!,count:names.count,lastSHA256:previous!)
 }
 private static func others(_ s:RestoreJournalStorage,excluding:String?,binding:SNESRuntimeBinding)throws {
  for name in try s.root.names() where name != ".stock-restore.lock" && name != excluding {
   let d=try RestoreDirectory(s.root.url.appendingPathComponent(name)),raw=try d.read("plan.json",maximum:32768),p=try JSONDecoder().decode(SNESMenuSelectionMaterial.Plan.self,from:raw)
   let state=try load(d,review:BackupManifest.digest(raw))
   if p.binding.expectedHWID==binding.expectedHWID,state.phase != .prepared,state.phase != .accepted {throw RecoveryProbeError.refused("A previous menu change needs to be checked. Its recovery record is saved on this Mac; no change was retried.")}
  }
 }
}
