import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESMenuAdapterScriptsTests {
 @Test(arguments:["none","inactive","selector","hash","file","symlink","hardlink","extra","nested","missing","manifest-length","uuid","unsafe-path"])
 func onlyAnEntireVerifiedOwnedMenuCanBeSelected(_ fault:String)throws {
  let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
  let namespace=root.appendingPathComponent("snes-v1"),menus=namespace.appendingPathComponent("menus"),id=UUID(uuidString:"11111111-2222-3333-4444-555555555555")!
  let originals=try SNESOriginalGamesFrame(originalGamesFrameFixture(),binding:originalGamesBinding(),challenge:originalGamesChallenge)
  let menu=try SNESOneGameMenu.prepare(originals:originals,code:"CLV-U-ABCDE",metadata:oneGameMetadata,rom:oneGameSyntheticROM(),artwork:oneGameSyntheticArt(),id:id)
  let target=menus.appendingPathComponent(id.uuidString)
  try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
  for (name,data) in menu.files {let url=target.appendingPathComponent(name);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try data.write(to:url)}
  let manifest=target.appendingPathComponent("menu.manifest"),selector=namespace.appendingPathComponent("active-menu")
  try menu.manifest.write(to:manifest)
  try Data(("SWIFTHAKCHI_SNES_MENU_SELECTOR_V1\n"+id.uuidString+"\n"+menu.treeSHA256+"\n").utf8).write(to:selector)
  let file=target.appendingPathComponent("games/CLV-U-ABCDE/CLV-U-ABCDE.sfrom")
  switch fault {
   case "inactive":try Data("not-the-selected-menu\n".utf8).write(to:selector)
   case "selector":try Data("invalid\n".utf8).write(to:selector)
   case "hash":var b=menu.manifest;b.append(32);try b.write(to:manifest)
   case "file":try Data([0]).write(to:file)
   case "symlink":try FileManager.default.removeItem(at:file);try FileManager.default.createSymbolicLink(at:file,withDestinationURL:root.appendingPathComponent("outside"))
   case "hardlink":try FileManager.default.linkItem(at:file,to:root.appendingPathComponent("outside"))
   case "extra":try Data([0]).write(to:target.appendingPathComponent("games/CLV-U-ABCDE/extra"))
   case "nested":try FileManager.default.createDirectory(at:target.appendingPathComponent("games/CLV-U-ABCDE/nested"),withIntermediateDirectories:false)
   case "missing":try FileManager.default.removeItem(at:file)
   case "manifest-length":try Data(repeating:65,count:32769).write(to:manifest)
   case "uuid":try Data(("SWIFTHAKCHI_SNES_MENU_SELECTOR_V1\n../escape\n"+menu.treeSHA256+"\n").utf8).write(to:selector)
   case "unsafe-path":let bad=Data(("SWIFTHAKCHI_SNES_MENU_V1\n"+String(repeating:"a",count:64)+" 1 games/$(touch_marker)/x\n").utf8);try bad.write(to:manifest);try Data(("SWIFTHAKCHI_SNES_MENU_SELECTOR_V1\n"+id.uuidString+"\n"+BackupManifest.digest(bad)+"\n").utf8).write(to:selector)
   default:break
  }
  let b=root.appendingPathComponent("busybox"),shim="""
  #!/bin/sh
  case "$1" in
    stat) case "$3" in '%h') exec /usr/bin/stat -f '%l' "$4";; '%u') echo 0;; *) exit 97;; esac;;
    *) exec "$@";;
  esac
  """
  try Data(shim.utf8).write(to:b);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:b.path)
  let script=SNESMenuAdapterScripts.verifier.replacingOccurrences(of:"/mnt/swifthakchi/busybox",with:b.path).replacingOccurrences(of:SNESOneGameMenu.namespace,with:namespace.path)
  let source=root.appendingPathComponent("verify");try Data(script.utf8).write(to:source)
  let before=try Data(contentsOf:selector),manifestBefore=try Data(contentsOf:manifest),process=Process(),out=Pipe(),err=Pipe()
  process.executableURL=URL(fileURLWithPath:"/bin/sh");process.arguments=[source.path]+(fault=="inactive" ? [id.uuidString,menu.treeSHA256]:[]);process.standardOutput=out;process.standardError=err
  try process.run();let bytes=out.fileHandleForReading.readDataToEndOfFile();let errors=err.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
  #expect(try Data(contentsOf:selector)==before && Data(contentsOf:manifest)==manifestBefore)
  if fault=="none" || fault=="inactive" {
   #expect(process.terminationStatus==0,"Verifier stderr: \(String(decoding:errors,as:UTF8.self))")
   #expect(String(decoding:bytes,as:UTF8.self)==target.path+"/games\n")
   if fault=="none",let p=ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_MENU_SCRIPT_EXPORT"] {
    let folder=URL(fileURLWithPath:p)
    for (name,value) in [("verify.sh",SNESMenuAdapterScripts.verifier),("configure.sh",SNESMenuAdapterScripts.configure),("wrapper.sh",SNESMenuAdapterScripts.wrapper)] {try Data(value.utf8).write(to:folder.appendingPathComponent(name))}
    try JSONSerialization.data(withJSONObject:["id":id.uuidString,"files":menu.files.mapValues{$0.base64EncodedString()},"manifest":menu.manifest.base64EncodedString(),"treeSHA256":menu.treeSHA256]).write(to:folder.appendingPathComponent("fixture.json"))
   }
  } else {#expect(process.terminationStatus != 0)}
 }
}
