import Foundation
import Testing
@testable import SwiftHakchiCore

struct SNESCanoeImageTests {
 static func rom(hi: Bool = false, type: UInt8 = 0, ram: UInt8 = 0, title: String = "ORDINARY TEST") -> Data {
  var b=Data(repeating:0,count:65536);let h=hi ? 0xffc0:0x7fc0
  let name=Array(title.utf8);b.replaceSubrange(h..<h+21,with:name+Array(repeating:32,count:21-name.count))
  b[h+0x15]=hi ? 0x21:0x20;b[h+0x16]=type;b[h+0x17]=6;b[h+0x18]=ram;b[h+0x19]=1;b[h+0x3d]=0x80
  checksum(&b,headers:[h]);return b
 }
 static func checksum(_ b:inout Data,headers:[Int]) {
  for h in headers {b[h+0x1c]=255;b[h+0x1d]=255;b[h+0x1e]=0;b[h+0x1f]=0}
  let sum=b.reduce(0){$0+Int($1)}&0xffff
  for h in headers {b[h+0x1c]=UInt8((sum^0xffff)&255);b[h+0x1d]=UInt8((sum^0xffff)>>8);b[h+0x1e]=UInt8(sum&255);b[h+0x1f]=UInt8(sum>>8)}
 }
 private func word(_ b:Data,_ i:Int)->Int {Int(b[i])|Int(b[i+1])<<8}
 @Test(arguments:[false,true]) func ordinaryContainerMatchesFrozenTrial(hi:Bool)throws {
  let source=Self.rom(hi:hi),r=try SNESCanoeImage.prepare(rom:source)
  #expect(r.data == (try SNESCanoeTrialImage(rom:source)).data)
  #expect(r.sourcePayloadSHA256==BackupManifest.digest(source))
  #expect(r.sramBytes==0 && r.saveCount==0 && r.batteryBacked==false)
  #expect(r.requiresHardwareTrial && r.isHiROM==hi)
 }
 @Test(arguments:[false,true]) func batteryCartridgePreservesPayloadAndRecommendsSaveFiles(hi:Bool)throws {
  let source=Self.rom(hi:hi,type:2,ram:5),r=try SNESCanoeImage.prepare(rom:source),end=48+source.count
  #expect(r.data[48..<end]==source)
  #expect(r.sramBytes==32768 && r.saveCount==3 && r.batteryBacked)
  #expect(r.data[end]==60 && r.data[end+17]==(hi ? 0x15:0x14))
  #expect(r.data[end+18..<end+27].allSatisfy{$0==0})
  #expect(throws:SNESCanoeTrialImage.PreparationError.self){try SNESCanoeTrialImage(rom:source)}
 }
 @Test func copierPrefixAndFastRAMOnlyImageHaveTheSameNormalizedIdentity()throws {
  var source=Self.rom(type:1,ram:3);source[0x7fd5]=0x30;Self.checksum(&source,headers:[0x7fc0])
  let r=try SNESCanoeImage.prepare(rom:source),prefixed=Data(repeating:0x91,count:512)+source
  let other=try SNESCanoeImage.prepare(rom:prefixed)
  #expect(r.data==other.data && r.sourcePayloadSHA256==other.sourcePayloadSHA256)
  #expect(other.sourcePrefixBytes==512 && other.batteryBacked==false && other.sramBytes==8192)
  #expect(prefixed.prefix(512).allSatisfy{$0==0x91})
 }
 @Test func knownPresetUsesInternalTitleWithoutEditingCartridgeData()throws {
  let source=Self.rom(title:"MEGAMAN 7"),r=try SNESCanoeImage.prepare(rom:source)
  #expect(r.presetID==0x113a && word(r.data,48+source.count+13)==0x113a)
  #expect(r.data[48..<48+source.count]==source)
 }
 @Test(arguments:["region","chip","mapping","ram","size","checksum","title","known-problem"])
 func unsupportedAndAmbiguousInputsStayReviewOnly(_ fault:String) {
  var source=Self.rom();let h=0x7fc0
  switch fault {
  case "region":source[h+0x19]=2
  case "chip":source[h+0x16]=5
  case "mapping":source[h+0x15]=0x23
  case "ram":source[h+0x18]=3
  case "size":source[h+0x17]=7
  case "title":source[h]=0
  case "known-problem":source=Self.rom(title:"HOME ALONE")
  default:break
  }
  if fault != "known-problem" {Self.checksum(&source,headers:[h])}
  if fault=="checksum" {source[10]^=1}
  #expect(throws:SNESCanoeImage.PreparationError.self){try SNESCanoeImage.prepare(rom:source)}
 }
 @Test func competingHeadersAndUnboundedSizesAreRejected() {
  var b=Self.rom();let hi=Self.rom(hi:true);b.replaceSubrange(0xffc0..<0x10000,with:hi[0xffc0..<0x10000]);Self.checksum(&b,headers:[0x7fc0,0xffc0])
  for invalid in [b,Data(),Data(repeating:0,count:4*1024*1024+513),Self.rom().dropLast()] {
   #expect(throws:SNESCanoeImage.PreparationError.self){try SNESCanoeImage.prepare(rom:Data(invalid))}
  }
 }
}
