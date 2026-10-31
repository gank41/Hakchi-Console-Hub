import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESMenuSelectionCommandsTests {
 @Test(arguments:["none","existing","directory","symlink","pending","tree","game","race","race-directory","stat-failure","compatibility-game","compatibility-supervisor"])
 func publishesOnlyAbsentSelectorAndNeverRestartsOrChangesGames(_ fault:String)throws {
  let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let originals=try SNESOriginalGamesFrame(originalGamesFrameFixture(),binding:originalGamesBinding(),challenge:originalGamesChallenge)
  let menu=try SNESOneGameMenu.prepare(originals:originals,code:"CLV-U-ABCDE",metadata:oneGameMetadata,rom:oneGameSyntheticROM(),artwork:oneGameSyntheticArt(),id:originalGamesChallenge)
  let operation=UUID(uuidString:"99999999-2222-3333-4444-555555555555")!
  func p(_ s:String)->URL {root.appendingPathComponent(s)}
  func put(_ name:String,_ data:Data)throws {try FileManager.default.createDirectory(at:p(name).deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);try data.write(to:p(name))}
  let n="var/lib/swifthakchi/snes-v1",target=n+"/menus/"+menu.id.uuidString
  for (name,data) in menu.files {try put(target+"/"+name,data)};try put(target+"/menu.manifest",menu.manifest)
  for e in originals.entries {for f in e.files where f.name.hasSuffix(".desktop") {try put("usr/share/games/"+e.code+"/"+f.name,f.data)}}
  try put("usr/bin/clover-canoe-shvc",originals.launcher)
  try put("etc/clover/boardtype",Data("dp-shvc\n".utf8));try put("etc/clover/REGION",Data("USA\n".utf8))
  let template=Data("[Application]\nGamesFolder = \(p("usr/share/games").path)\n".utf8)
  try put("usr/share/applications/clover-mcp.desktop",template)
  try put("proc/mounts",Data("/dev/nandc \(p("var/lib").path) ext4 rw 0 0\n".utf8))
  let selector=p(n+"/active-menu"),pending=p(n+"/selection-"+operation.uuidString+".pending")
  switch fault {
  case "existing":try Data("keep".utf8).write(to:selector)
  case "directory":try FileManager.default.createDirectory(at:selector,withIntermediateDirectories:false)
  case "symlink":try put("outside",Data("keep".utf8));try FileManager.default.createSymbolicLink(at:selector,withDestinationURL:p("outside"))
  case "pending":try Data("keep".utf8).write(to:pending)
  case "tree":try Data([0]).write(to:p(target+"/games/"+menu.code+"/"+menu.code+".sfrom"))
  default:break
  }
  let shim="""
  #!/bin/sh
  case "$1" in
   uname) echo 3.4.113;; devmem) echo 0x11111111;;
   df) printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev/nandc 300000 100000 200000 33%% %s\\n' '\(p("var/lib").path)';;
   pidof) case "$2" in clover-mcp) echo 100;; retroarch) \(fault=="compatibility-game" ? "echo 201":"exit 1");; hc-snes-superv) \(fault=="compatibility-supervisor" ? "echo 202":"exit 1");; *) \(fault=="game" ? "echo 200":"exit 1");; esac;;
   stat) case "$3" in '%h') /usr/bin/stat -f '%l' "$4";; '%u') echo 0;; '%a') /usr/bin/stat -f '%Lp' "$4";; '%d:%i') \(fault=="stat-failure" ? "exit 97":"/usr/bin/stat -f '%d:%i' \"$4\"");; *) exit 97;; esac;;
   sync) exit 0;;
   ln)
    \(fault=="race" ? "printf keep > '\(selector.path)'":"\(fault=="race-directory" ? "mkdir '\(selector.path)'":"true")")
    test ! -d "$4" || exit 98
    exec /bin/ln "$3" "$4";;
   *) exec "$@";;
  esac
  """
  let bb=p("busybox");try Data(shim.utf8).write(to:bb);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:bb.path)
  let command=try SNESMenuSelectionCommands.publish(menu:menu,originals:originals,binding:originalGamesBinding(),operation:operation,challenge:UUID())
  let script=command.replacingOccurrences(of:"/mnt/swifthakchi/busybox",with:bb.path)
   .replacingOccurrences(of:SNESRAMProbeScripts.busyboxSHA256,with:BackupManifest.digest(Data(shim.utf8)))
   .replacingOccurrences(of:SNESMenuAdapterScripts.mcpDesktopSHA256,with:BackupManifest.digest(template))
   .replacingOccurrences(of:"/var/lib",with:p("var/lib").path).replacingOccurrences(of:"/usr/share",with:p("usr/share").path)
   .replacingOccurrences(of:"/usr/bin/clover-canoe-shvc",with:p("usr/bin/clover-canoe-shvc").path)
   .replacingOccurrences(of:"/etc/clover/",with:p("etc/clover").path+"/").replacingOccurrences(of:"/proc/",with:p("proc").path+"/")
  let source=p("publish.sh");try Data(script.utf8).write(to:source)
  let process=Process(),out=Pipe(),err=Pipe();process.executableURL=URL(fileURLWithPath:"/bin/sh");process.arguments=[source.path];process.standardOutput=out;process.standardError=err
  try process.run();let output=out.fileHandleForReading.readDataToEndOfFile(),errors=err.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
  #expect(try Data(contentsOf:p("usr/share/applications/clover-mcp.desktop"))==template)
  if fault=="none" {
   #expect(process.terminationStatus==0,"\(String(decoding:errors,as:UTF8.self))")
   #expect(try Data(contentsOf:selector)==SNESMenuSelectionCommands.selector(menu:menu))
   #expect(!FileManager.default.fileExists(atPath:pending.path))
   #expect(String(decoding:output,as:UTF8.self).contains("DISPLAY=original"))
   if let export=ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_SELECTION_EXPORT"] {
    let d=URL(fileURLWithPath:export)
    try Data(command.utf8).write(to:d.appendingPathComponent("publish.sh"))
    try Data(try SNESMenuSelectionCommands.inspect(menu:menu,originals:originals,binding:originalGamesBinding(),operation:operation,challenge:operation).utf8).write(to:d.appendingPathComponent("inspect.sh"))
    let files=menu.files.merging(["menu.manifest":menu.manifest]){a,_ in a}
    let stock=originals.entries.flatMap{e in e.files.filter{$0.name.hasSuffix(".desktop")}.map{("usr/share/games/"+e.code+"/"+$0.name,$0.data)}}
    let fixture:[String:Any]=["id":menu.id.uuidString,"operation":operation.uuidString,"tree":menu.treeSHA256,
     "files":files.mapValues{$0.base64EncodedString()},"stock":Dictionary(uniqueKeysWithValues:stock).mapValues{$0.base64EncodedString()},"launcher":originals.launcher.base64EncodedString(),"selector":SNESMenuSelectionCommands.selector(menu:menu).base64EncodedString()]
    try JSONSerialization.data(withJSONObject:fixture,options:[.sortedKeys]).write(to:d.appendingPathComponent("fixture.json"))
   }
  } else {
   #expect(process.terminationStatus != 0)
   if fault=="existing" || fault=="race" {#expect(try Data(contentsOf:selector)==Data("keep".utf8))}
   if ["existing","directory","symlink"].contains(fault) {#expect(!FileManager.default.fileExists(atPath:pending.path))}
   if fault=="directory" || fault=="race-directory" {#expect(try FileManager.default.contentsOfDirectory(atPath:selector.path).isEmpty)}
  }
  if fault != "tree" {for (name,data) in menu.files {#expect(try Data(contentsOf:p(target+"/"+name))==data)}}
 }
}
