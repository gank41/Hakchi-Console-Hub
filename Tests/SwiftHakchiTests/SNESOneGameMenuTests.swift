import Foundation
import Testing
import AppKit
import SwiftHakchiCore
@testable import SwiftHakchi

func oneGameSyntheticROM(byteCount:Int=65536)->Data {
 var b=Data(repeating:0,count:byteCount);let h=0x7fc0
 b.replaceSubrange(h..<h+21,with:Data("SYNTHETIC TEST GAME  ".utf8));b[h+0x15]=0x20;b[h+0x17]=UInt8(Int(log2(Double(byteCount)))-10);b[h+0x19]=1;b[h+0x3d]=0x80;b[h+0x1c]=255;b[h+0x1d]=255
 let c=b.reduce(0){$0+Int($1)}&65535;b[h+0x1c]=UInt8((c^65535)&255);b[h+0x1d]=UInt8((c^65535)>>8);b[h+0x1e]=UInt8(c&255);b[h+0x1f]=UInt8(c>>8);return b
}
func oneGameSyntheticArt()->Data {
 let image=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:512,pixelsHigh:364,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
 image.bitmapData!.initialize(repeating:0,count:image.bytesPerRow*image.pixelsHigh)
 return image.representation(using:.png,properties:[:])!
}
let oneGameMetadata=Data("[Desktop Entry]\nName=My Arkanoid – Édition\nExec=/untrusted/command\nPath=/untrusted/path\nIcon=/untrusted/icon\nX-SwiftHakchi-Publisher=My Publisher\n[X-CLOVER Game]\nPlayers=2\nSimultaneous=0\nReleaseDate=1997-01-01\nSaveCount=0\nSortRawTitle=arkanoid\nSortRawPublisher=MY PUBLISHER\nCopyright=My copyright ©\n".utf8)
struct SNESOneGameMenuTests {
 @Test func keepsEditedFieldsAndOriginalPayloadWhileGeneratingSNESLaunch()throws {
  let originals=try SNESOriginalGamesFrame(originalGamesFrameFixture(),binding:originalGamesBinding(),challenge:originalGamesChallenge),rom=oneGameSyntheticROM(),art=oneGameSyntheticArt(),id=UUID(uuidString:"11111111-2222-3333-4444-555555555555")!
  let menu=try SNESOneGameMenu.prepare(originals:originals,code:"CLV-U-ABCDE",metadata:oneGameMetadata,rom:rom,artwork:art,id:id)
  #expect(menu.gameCount==3 && menu.title=="My Arkanoid – Édition")
  #expect(menu.consoleRoot=="/var/lib/swifthakchi/snes-v1/menus/"+id.uuidString)
  let root="games/CLV-U-ABCDE/",desktop=String(decoding:try #require(menu.files[root+"CLV-U-ABCDE.desktop"]),as:UTF8.self)
  #expect(desktop.contains("Exec=/usr/bin/clover-canoe-shvc -rom "+menu.consoleRoot+"/"+root+"CLV-U-ABCDE.sfrom --volume 100 -rollback-snapshot-period 600"))
  #expect(desktop.contains("Path=/var/lib/clover/profiles/0/CLV-U-ABCDE"))
  for value in ["Name=My Arkanoid – Édition","Players=2","ReleaseDate=1997-01-01","SortRawPublisher=My Publisher","Copyright=My copyright ©"] {#expect(desktop.contains(value))}
  #expect(!desktop.contains("/untrusted/") && !desktop.contains(".smc"))
  let container=try #require(menu.files[root+"CLV-U-ABCDE.sfrom"]);#expect(container[48..<container.count-48]==rom)
  #expect(container == (try SNESCanoeTrialImage(rom:rom).data))
  for entry in originals.entries {#expect(menu.files["games/"+entry.code+"/"+entry.code+".desktop"]==entry.files[0].data)}
  #expect(menu.files.keys.filter{$0.hasSuffix(".sfrom")}.count==1)
  for (suffix,w,h) in [(".png",228,162),("_small.png",40,28)] {
   let png=try #require(menu.files[root+"CLV-U-ABCDE"+suffix]),image=try #require(NSBitmapImageRep(data:png));#expect(image.pixelsWide==w && image.pixelsHigh==h)
  }
  #expect(menu.treeSHA256==BackupManifest.digest(menu.manifest))
  #expect(art==oneGameSyntheticArt() && rom==oneGameSyntheticROM())
 }
 @Test(arguments:["code","duplicate","metadata-size","metadata-utf8","key-injection","players","date","art","art-size","rom"])
 func refusesAmbiguousOrUnsupportedInputs(_ fault:String)throws {
  let originals=try SNESOriginalGamesFrame(originalGamesFrameFixture(),binding:originalGamesBinding(),challenge:originalGamesChallenge)
  var code="CLV-U-ABCDE",metadata=oneGameMetadata,rom=oneGameSyntheticROM(),art=oneGameSyntheticArt()
  switch fault {
   case "code":code="../bad"
   case "duplicate":metadata=Data("Name=Été\n".utf8)
   case "metadata-size":metadata=Data(repeating:65,count:16385)
   case "metadata-utf8":metadata=Data([255])
   case "key-injection":metadata.append(Data("Name=Other\n".utf8))
   case "players":metadata=Data(String(decoding:metadata,as:UTF8.self).replacingOccurrences(of:"Players=2",with:"Players=200").utf8)
   case "date":metadata=Data(String(decoding:metadata,as:UTF8.self).replacingOccurrences(of:"1997-01-01",with:"1997-99-99").utf8)
   case "art":art=Data([0,1])
   case "art-size":art=Data(count:8*1024*1024+1)
   default:rom[256]^=1
  }
  #expect(throws:(any Error).self) {try SNESOneGameMenu.prepare(originals:originals,code:code,metadata:metadata,rom:rom,artwork:art)}
 }
}
