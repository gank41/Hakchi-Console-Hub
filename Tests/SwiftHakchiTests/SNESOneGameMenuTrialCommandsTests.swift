import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESOneGameMenuTrialCommandsTests {
 @Test(arguments:["none","shutdown","hard-limit","foreign-bind","existing","init","game","tree","ui-exe","ui-parent","ui-framebuffer","ui-multiple","mcp-exe","compatibility-game","compatibility-supervisor"])
 func temporaryMenuUsesOnlyRAMAndRejectsUnsafeState(_ fault:String)throws {
  let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
  let originals=try SNESOriginalGamesFrame(originalGamesFrameFixture(),binding:originalGamesBinding(),challenge:originalGamesChallenge)
  let menu=try SNESOneGameMenu.prepare(originals:originals,code:"CLV-U-ABCDE",metadata:oneGameMetadata,rom:oneGameSyntheticROM(),artwork:oneGameSyntheticArt(),id:originalGamesChallenge)
  func path(_ s:String)->URL {root.appendingPathComponent(s)}
  func put(_ name:String,_ bytes:Data)throws {try FileManager.default.createDirectory(at:path(name).deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);try bytes.write(to:path(name))}
  let namespace="var/lib/swifthakchi/snes-v1",target=namespace+"/menus/"+menu.id.uuidString
  for (name,data) in menu.files {try put(target+"/"+name,data)};try put(target+"/menu.manifest",menu.manifest)
  for e in originals.entries {for f in e.files where f.name.hasSuffix(".desktop") {try put("usr/share/games/"+e.code+"/"+f.name,f.data)}}
  try put("usr/bin/clover-canoe-shvc",originals.launcher)
  try put("etc/clover/boardtype",Data("dp-shvc\n".utf8));try put("etc/clover/REGION",Data("USA\n".utf8))
  let template=Data("[Application]\nGamesFolder = \(path("usr/share/games").path)\nOther = keep\n".utf8);try put("usr/share/applications/clover-mcp.desktop",template)
  try put("proc/mounts",Data(("/dev/nandc \(path("var/lib").path) ext4 rw 0 0\ntmpfs \(path("run").path) tmpfs rw 0 0\n"+(fault=="foreign-bind" ? "tmpfs \(path("usr/share/applications/clover-mcp.desktop").path) tmpfs rw 0 0\n":"")).utf8))
  try FileManager.default.createDirectory(at:path("run"),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);try put("mcp",Data("100\n".utf8));try put("daemon",Data("42\n".utf8));try put("mnt/swifthakchi/daemon.pid",Data("42\n".utf8));try put("game",Data((fault=="game" ? "900":"").utf8))
  func process(_ pid:Int,_ name:String,_ parent:Int,_ birth:Int)throws {
   try put("proc/\(pid)/stat",Data(("\(pid) (\(name.prefix(15))) S \(parent) "+Array(repeating:"0",count:17).joined(separator:" ")+" \(birth)\n").utf8))
   try FileManager.default.createSymbolicLink(atPath:path("proc/\(pid)/exe").path,withDestinationPath:"/usr/bin/"+name)
  }
  try process(100,fault=="mcp-exe" ? "foreign":"clover-mcp",1,10)
  try process(200,fault=="ui-exe" ? "foreign":"ReedPlayer-Clover",fault=="ui-parent" ? 999:100,20)
  try put("ui",Data((fault=="ui-multiple" ? "200 201":"200").utf8))
  try FileManager.default.createDirectory(at:path("proc/200/fd"),withIntermediateDirectories:true)
  if fault != "ui-framebuffer" {try FileManager.default.createSymbolicLink(atPath:path("proc/200/fd/3").path,withDestinationPath:"/dev/fb0")}
  let stopAction=fault=="shutdown" ? "echo ShuttingDown > '\(path("shutdown").path)'; exit 73":": > '\(path("mcp").path)'"
  let initScript="#!/bin/sh\ncase \"$1\" in stop) \(stopAction);; start) echo 101 > '\(path("mcp").path)'; ulimit -f > '\(path("child-limit").path)';; *) exit 99;; esac\n".replacingOccurrences(of:"\\\"",with:"\"")
  let initData=Data(initScript.utf8);try put("etc/init.d/S81clover-mcp",initData)
  let ram=path("run/swifthakchi-snes-menu-"+menu.id.uuidString)
  if fault=="existing" {try FileManager.default.createDirectory(at:ram,withIntermediateDirectories:false)}
  if fault=="init" {try put("etc/init.d/S81clover-mcp",Data("changed".utf8))}
  if fault=="tree" {try put(target+"/games/"+menu.code+"/"+menu.code+".sfrom",Data("bad".utf8))}
  let shim="""
  #!/bin/sh
  case "$1" in
   uname) echo 3.4.113;; devmem) echo 0x11111111;;
   df) printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev/nandc 300000 100000 200000 33%% %s\\n' '\(path("var/lib").path)';;
   pidof) case "$2" in clover-mcp) cat '\(path("mcp").path)';; ReedPlayer-Clover) cat '\(path("ui").path)';; clovershell) echo 42;; retroarch) \(fault=="compatibility-game" ? "echo 201":"exit 1");; hc-snes-superv) \(fault=="compatibility-supervisor" ? "echo 202":"exit 1");; *) cat '\(path("game").path)';; esac;;
   stat) case "$3" in '%h') echo 1;; '%u') echo 0;; '%a') /usr/bin/stat -f '%Lp' "$4";; '%d:%i') echo 1:5;; *) exit 97;; esac;;
   readlink) /usr/bin/readlink "$3";;
   kill) case "$2:$3" in -KILL:100) : > '\(path("mcp").path)'; rm -rf '\(path("proc/100").path)';; -TERM:200) test ! -s '\(path("mcp").path)' || exit 96; : > '\(path("ui").path)'; rm -rf '\(path("proc/200").path)';; *) exit 95;; esac;;
   mount) cp "$3" "$4"; printf 'tmpfs %s tmpfs rw 0 0\\n' "$4" >> '\(path("proc/mounts").path)';;
   sync) exit 0;;
   *) exec "$@";;
  esac
  """
  let bb=path("busybox"),shimData=Data(shim.utf8);try shimData.write(to:bb);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:bb.path)
  // A hosted runner can impose a finite hard limit which a child cannot raise.
  // Exercise the happy path at that ceiling, while retaining the real console
  // script's unlimited requirement and testing its refusal separately below.
  let limitProcess=Process(),limitOutput=Pipe()
  limitProcess.executableURL=URL(fileURLWithPath:"/bin/sh")
  limitProcess.arguments=["-c","ulimit -H -f"]
  limitProcess.standardOutput=limitOutput
  try limitProcess.run()
  let hardLimit=String(decoding:limitOutput.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
  limitProcess.waitUntilExit()
  guard limitProcess.terminationStatus == 0, hardLimit == "unlimited" || UInt64(hardLimit) != nil else {throw SNESOneGameMenu.failure()}
  let executionLimit = fault == "hard-limit" ? "unlimited" : hardLimit
  func rewrite(_ source:String)->String {
   source.replacingOccurrences(of:"ulimit -f unlimited",with:"ulimit -f " + executionLimit)
    .replacingOccurrences(of:"/mnt/swifthakchi/busybox",with:bb.path).replacingOccurrences(of:SNESRAMProbeScripts.busyboxSHA256,with:BackupManifest.digest(shimData))
    .replacingOccurrences(of:SNESOneGameMenuTrialCommands.originalInitSHA256,with:BackupManifest.digest(initData))
    .replacingOccurrences(of:SNESMenuAdapterScripts.mcpDesktopSHA256,with:BackupManifest.digest(template))
    .replacingOccurrences(of:"/var/lib",with:path("var/lib").path).replacingOccurrences(of:"/usr/share",with:path("usr/share").path)
    .replacingOccurrences(of:"/usr/bin/clover-canoe-shvc",with:path("usr/bin/clover-canoe-shvc").path).replacingOccurrences(of:"/etc/",with:path("etc").path+"/").replacingOccurrences(of:"/proc/",with:path("proc").path+"/").replacingOccurrences(of:"/run",with:path("run").path).replacingOccurrences(of:"/mnt/swifthakchi/daemon.pid",with:path("mnt/swifthakchi/daemon.pid").path)
  }
  func execute(_ script:String)throws->(Int32,Data,Data) {
   let errorFile=path("stderr-"+UUID().uuidString);FileManager.default.createFile(atPath:errorFile.path,contents:nil);let errorHandle=try FileHandle(forWritingTo:errorFile);defer{try? errorHandle.close()};let p=Process(),out=Pipe();p.executableURL=URL(fileURLWithPath:"/bin/sh");p.arguments=["-c",(fault == "hard-limit" ? "ulimit -S -f 1; ulimit -H -f 1\n" : "") + rewrite(script)];p.standardOutput=out;p.standardError=errorHandle;try p.run();let o=out.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit();let e=try Data(contentsOf:errorFile);return(p.terminationStatus,o,Data(e.suffix(6000)))
  }
  let command=try SNESOneGameMenuTrialCommands.start(menu:menu,originals:originals,binding:originalGamesBinding(),challenge:originalGamesChallenge),result=try execute(command)
  #expect(command.contains("ulimit -f unlimited"))
  #expect(!FileManager.default.fileExists(atPath:path(namespace+"/active-menu").path))
  if ["none","shutdown"].contains(fault) {
   #expect(!FileManager.default.fileExists(atPath:path("shutdown").path))
   #expect(result.0==0,"stderr: \(String(decoding:result.2,as:UTF8.self))")
   #expect(String(decoding:result.1,as:UTF8.self).contains("STATE=ram-menu"))
   #expect(try String(contentsOf:path("usr/share/applications/clover-mcp.desktop")).contains("GamesFolder = "+path(target+"/games").path))
   #expect(try String(contentsOf:path("child-limit")).trimmingCharacters(in:.whitespacesAndNewlines)==hardLimit)
   #expect(try execute(command).0 != 0)
   let state=try execute(SNESOneGameMenuTrialCommands.state(menu:menu,originals:originals,binding:originalGamesBinding(),challenge:UUID()));#expect(state.0==0)
   if fault=="none",let export=ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_MENU_TRIAL_EXPORT"] {let d=URL(fileURLWithPath:export);try Data(command.utf8).write(to:d.appendingPathComponent("start.sh"));try SNESOneGameMaterial.encodeBundle(menu).write(to:d.appendingPathComponent("input.bundle"));try Data(try SNESOneGameMenuTrialCommands.state(menu:menu,originals:originals,binding:originalGamesBinding(),challenge:originalGamesChallenge,original:true).utf8).write(to:d.appendingPathComponent("returned.sh"));try Data(try SNESOneGameMenuTrialCommands.state(menu:menu,originals:originals,binding:originalGamesBinding(),challenge:originalGamesChallenge).utf8).write(to:d.appendingPathComponent("state.sh"))}
  } else {
   #expect(result.0 != 0)
   #expect(try String(contentsOf:path("mcp")).trimmingCharacters(in:.whitespacesAndNewlines)=="100")
   if fault == "hard-limit" {
    #expect(!FileManager.default.fileExists(atPath:ram.path))
    #expect(try Data(contentsOf:path("usr/share/applications/clover-mcp.desktop")) == template)
   }
  }
 }
}
