import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESOneGameStageCommandsTests {
 @Test(arguments:["none","space","target","parent-link","source","identity","partial","corrupt","header","subset","extra-stock"])
 func copiesOnlyTheReviewedInactiveTreeAndNeverChangesMenuSelector(_ fault:String)throws {
  let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
  let actualOriginals=try SNESOriginalGamesFrame(originalGamesFrameFixture(),binding:originalGamesBinding(),challenge:originalGamesChallenge)
  var frame=actualOriginals.raw
  if fault=="subset" {
   let start=try #require(frame.range(of:Data("GAME CLV-P-BBBBB\n".utf8))),end=try #require(frame.range(of:Data("END_GAME\n".utf8),in:start.lowerBound..<frame.endIndex))
   frame.removeSubrange(start.lowerBound..<end.upperBound)
   let trailer=try #require(frame.range(of:Data("END 2\n".utf8)));frame.replaceSubrange(trailer,with:Data("END 1\n".utf8))
  }
  let originals=try SNESOriginalGamesFrame(frame,binding:originalGamesBinding(),challenge:originalGamesChallenge),menu=try SNESOneGameMenu.prepare(originals:originals,code:"CLV-U-ABCDE",metadata:oneGameMetadata,rom:oneGameSyntheticROM(byteCount:524288),artwork:oneGameSyntheticArt(),id:originalGamesChallenge)
  let dataRoot=root.appendingPathComponent("var/lib"),namespace=dataRoot.appendingPathComponent("swifthakchi/snes-v1"),target=namespace.appendingPathComponent("menus/"+menu.id.uuidString)
  try FileManager.default.createDirectory(at:namespace.appendingPathComponent("menus"),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  let selector=namespace.appendingPathComponent("active-menu"),before=Data("keep-current-menu\n".utf8);try before.write(to:selector)
  let games=root.appendingPathComponent("usr/share/games"),launcher=root.appendingPathComponent("usr/bin/clover-canoe-shvc")
  try FileManager.default.createDirectory(at:launcher.deletingLastPathComponent(),withIntermediateDirectories:true);try originals.launcher.write(to:launcher)
  for e in actualOriginals.entries {let d=games.appendingPathComponent(e.code);try FileManager.default.createDirectory(at:d,withIntermediateDirectories:true);try e.files[0].data.write(to:d.appendingPathComponent(e.code+".desktop"))}
  if fault=="extra-stock" {try FileManager.default.createDirectory(at:games.appendingPathComponent("CLV-P-CCCCC"),withIntermediateDirectories:false)}
  let etc=root.appendingPathComponent("etc/clover");try FileManager.default.createDirectory(at:etc,withIntermediateDirectories:true);try Data("dp-shvc\n".utf8).write(to:etc.appendingPathComponent("boardtype"));try Data("USA\n".utf8).write(to:etc.appendingPathComponent("REGION"))
  let limits=root.appendingPathComponent("limits");try Data("Max file size 524288 524288 bytes\n".utf8).write(to:limits)
  let mounts=root.appendingPathComponent("mounts");try Data(("/dev/nandc "+dataRoot.path+" ext4 rw,nosuid 0 0\n").utf8).write(to:mounts)
  let bb=root.appendingPathComponent("busybox"),shim="""
  #!/bin/sh
  case "$1" in
    uname) echo 3.4.113;;
    devmem) echo \(fault=="identity" ? "0x22222222":"0x11111111");;
    df) printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev/nandc 300000 100000 \(fault=="space" ? "0":"200000") 33%% %s\\n' '\(dataRoot.path)';;
    stat) case "$3" in '%h') exec /usr/bin/stat -f '%l' "$4";; '%u') echo 0;; '%a') exec /usr/bin/stat -f '%Lp' "$4";; *) exit 97;; esac;;
    sync) exit 0;;
    *) exec "$@";;
  esac
  """
  let shimData=Data(shim.utf8);try shimData.write(to:bb);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:bb.path)
  if fault=="target" {try FileManager.default.createDirectory(at:target,withIntermediateDirectories:false);try Data("untouched".utf8).write(to:target.appendingPathComponent("old"))}
  if fault=="parent-link" {let out=root.appendingPathComponent("outside");try FileManager.default.createDirectory(at:out,withIntermediateDirectories:false);try FileManager.default.moveItem(at:namespace,to:out.appendingPathComponent("old"));try FileManager.default.createSymbolicLink(at:namespace,withDestinationURL:out.appendingPathComponent("old"))}
  if fault=="source" {try Data("changed".utf8).write(to:launcher)}
  var bundle=try SNESOneGameMaterial.encodeBundle(menu)
  if fault=="partial" {bundle=Data(bundle.prefix(bundle.count/2))}
  if fault=="corrupt" {let p=try #require(bundle.range(of:Data("SYNTHETIC TEST GAME".utf8)));bundle[p.lowerBound]^=1}
  if fault=="header" {bundle[0]^=1}
  func rewrite(_ script:String)->String {
   script.replacingOccurrences(of:"/mnt/swifthakchi/busybox",with:bb.path).replacingOccurrences(of:SNESRAMProbeScripts.busyboxSHA256,with:BackupManifest.digest(shimData))
    .replacingOccurrences(of:"/var/lib",with:dataRoot.path).replacingOccurrences(of:"/usr/share/games",with:games.path)
    .replacingOccurrences(of:"/usr/bin/clover-canoe-shvc",with:launcher.path).replacingOccurrences(of:"/etc/clover",with:etc.path).replacingOccurrences(of:"/proc/mounts",with:mounts.path).replacingOccurrences(of:"/proc/self/limits",with:limits.path)
  }
  func execute(_ script:String,_ input:Data=Data())throws->(Int32,Data,Data) {
   let inputURL=root.appendingPathComponent("input-"+UUID().uuidString)
   let stream=try SNESOneGameStream(script:rewrite(script),body:input)
   try stream.input.write(to:inputURL)
   let handle=try FileHandle(forReadingFrom:inputURL);defer {try? handle.close()}
   let p=Process(),out=Pipe(),err=Pipe();p.executableURL=URL(fileURLWithPath:"/usr/bin/python3");p.arguments=["-c","import os,resource,sys; resource.setrlimit(resource.RLIMIT_FSIZE,(524288,resource.getrlimit(resource.RLIMIT_FSIZE)[1])); os.execv('/bin/sh',['sh','-c',sys.argv[1]])",stream.command.replacingOccurrences(of:"/mnt/swifthakchi/busybox",with:bb.path)];p.standardInput=handle;p.standardOutput=out;p.standardError=err
   try p.run();let stdout=out.fileHandleForReading.readDataToEndOfFile(),stderr=err.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit();return(p.terminationStatus,stdout,stderr)
  }
  let command=try SNESOneGameStageCommands.copy(menu:menu,originals:originals,binding:originalGamesBinding(),challenge:originalGamesChallenge),result=try execute(command,bundle)
  #expect(try Data(contentsOf:selector)==before)
  if ["none","partial","corrupt","header"].contains(fault) {
   let challenge=UUID(),checked=try execute(SNESOneGameStageCommands.inspect(menu:menu,originals:originals,binding:originalGamesBinding(),challenge:challenge))
   #expect(checked.0==0,"Inspection stderr: \(String(decoding:checked.2,as:UTF8.self))")
   let receipt=try SNESOneGameInspectionReceipt(checked.1,menu:menu,binding:originalGamesBinding(),challenge:challenge)
   #expect(receipt.matchesMenu==(fault=="none"))
   #expect(receipt.copyLimitReady)
   if fault=="none" {
    let diagnostic=try execute(SNESOneGameStageCommands.inspect(menu:menu,originals:originals,binding:originalGamesBinding(),challenge:challenge,includeProcesses:true))
    #expect(diagnostic.0==0 && String(decoding:diagnostic.2,as:UTF8.self).contains("SWIFTHAKCHI_SNES_PROCESS_DETAILS_V1"))
    #expect(try SNESOneGameInspectionReceipt(diagnostic.1,menu:menu,binding:originalGamesBinding(),challenge:challenge).matchesMenu)
   }
   #expect(try Data(contentsOf:selector)==before)
  }
  if fault=="none" {
   #expect(result.0==0,"Copy stderr: \(String(decoding:result.2,as:UTF8.self))")
   #expect(String(decoding:result.1,as:UTF8.self).contains("CHALLENGE="+originalGamesChallenge.uuidString))
   for (name,data) in menu.files {#expect(try Data(contentsOf:target.appendingPathComponent(name))==data)}
   #expect(try Data(contentsOf:target.appendingPathComponent("menu.manifest"))==menu.manifest)
   let verified=try execute(SNESOneGameStageCommands.verify(menu:menu,binding:originalGamesBinding(),challenge:UUID()))
   #expect(verified.0==0)
   let repeated=try execute(command,bundle);#expect(repeated.0 != 0)
   if let path=ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_GAME_COPY_EXPORT"] {
    let export=URL(fileURLWithPath:path)
    let stream=try SNESOneGameStream(script:command,body:bundle)
    for (name,data) in [("inspect.sh",Data(try SNESOneGameStageCommands.inspect(menu:menu,originals:originals,binding:originalGamesBinding(),challenge:originalGamesChallenge).utf8)),("bootstrap.sh",Data(stream.command.utf8)),("stream.input",stream.input),("copy.sh",Data(command.utf8)),("verify.sh",Data(try SNESOneGameStageCommands.verify(menu:menu,binding:originalGamesBinding(),challenge:originalGamesChallenge).utf8)),("input.bundle",bundle)] {try data.write(to:export.appendingPathComponent(name))}
   }
  } else {
   #expect(result.0 != 0)
   if !["partial","corrupt","target"].contains(fault) {#expect(!FileManager.default.fileExists(atPath:target.path))}
  }
 }
}
