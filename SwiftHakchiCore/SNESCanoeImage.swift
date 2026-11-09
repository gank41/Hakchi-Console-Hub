import Foundation

/// General offline preparation. Historical trial bytes and eligibility are unchanged.
/// Pinned format/preset evidence: docs/SNES-LIBRARY-CONVERSION-2026-10-23.md.
public enum SNESCanoeImage {
 public enum PreparationError:String,Error,LocalizedError,Sendable {
  case unsupportedSize,invalidHeader,ambiguousHeader,unsupportedCartridge,unsupportedRegion,checksumNeedsReview,knownCompatibilityReview,adapterSoftware
  public var errorDescription:String? {
   switch self {
   case .adapterSoftware:return "Super Game Boy is adapter software, not a standalone SNES game."
   case .unsupportedSize:return "This cartridge size needs conversion support."
   case .invalidHeader:return "The cartridge header or mapping needs review before native conversion."
   case .ambiguousHeader:return "More than one cartridge mapping matches. Choose a verified ROM revision."
   case .unsupportedCartridge:return "This cartridge or save-memory layout needs additional compatibility support."
   case .unsupportedRegion:return "This ROM's region needs a tested conversion profile."
   case .checksumNeedsReview:return "The game's internal checksum doesn't match the file. It may be modified or incomplete; check the source or try another verified copy. The original file hasn't been changed."
   case .knownCompatibilityReview:return "The reference lists this game for compatibility review. A tested game profile is needed."
   }
  }
 }
 public struct Result:Sendable {
  public let data:Data,sourcePayloadSHA256:String,internalTitle:String
  public let sourcePrefixBytes:Int,isHiROM:Bool,sramBytes:Int,batteryBacked:Bool,saveCount:Int,presetID:UInt16
  public var requiresHardwareTrial:Bool {true}
 }
 public static func prepare(rom:Data)throws->Result {
  guard (32768...4*1024*1024+512).contains(rom.count) else {throw PreparationError.unsupportedSize}
  let prefix=rom.count%32768==512 ? 512:0,length=rom.count-prefix
  guard length<=4*1024*1024,length%32768==0 else {throw PreparationError.unsupportedSize}
  var addressSpan=32768
  while addressSpan<length {addressSpan *= 2}
  let payload=Array(rom.dropFirst(prefix))
  func word(_ at:Int)->Int {Int(payload[at])|Int(payload[at+1])<<8}
  let headers=[(0x7fc0,false),(0xffc0,true)].filter {h,hi in
   guard h+64<=length else{return false}
   let map=payload[h+0x15],size=Int(payload[h+0x17])
   let contra = !hi && length == 1024*1024 && map == 0x53 && payload[h+0x16] == 0 && size == 10 && payload[h+0x18] == 0 && payload[h+0x19] == 1 &&
    Array(payload[h..<h+22]) == Array("CONTRA3 THE ALIEN WARS".utf8)
   return (contra || (hi ? [0x21,0x31]:[0x20,0x30]).contains(Int(map))) && size<=12 && 1<<(size+10)==addressSpan &&
    word(h+0x1c)^word(h+0x1e)==0xffff && (0x8000..<0xffff).contains(word(h+0x3c)) &&
    cartridgeTitle(payload,h) != nil
  }
  guard !headers.isEmpty else {throw PreparationError.invalidHeader}
  guard headers.count==1,let (h,hi)=headers.first else {throw PreparationError.ambiguousHeader}
  guard mirroredSum(payload,start:0,count:length).sum==word(h+0x1e) else {throw PreparationError.checksumNeedsReview}
  let type=payload[h+0x16],ram=payload[h+0x18]
  guard let title=cartridgeTitle(payload,h) else {throw PreparationError.invalidHeader}
  if type==0xe3 && title=="Super GAMEBOY" {throw PreparationError.adapterSoftware}
  guard (type==0 && ram==0) || ([1,2].contains(type) && (1...7).contains(ram)) else {throw PreparationError.unsupportedCartridge}
  guard [0,1].contains(payload[h+0x19]) else {throw PreparationError.unsupportedRegion}
  guard !problemTitles.contains(title) else {throw PreparationError.knownCompatibilityReview}
  let preset=presets[title] ?? 0,footer=48+length,total=length+96
  var output=[UInt8](repeating:0,count:total)
  func set32(_ at:Int,_ value:Int){for i in 0..<4 {output[at+i]=UInt8((value>>(8*i))&255)}}
  set32(0,0x100);set32(4,total);set32(8,48);set32(12,footer);set32(16,total);set32(20,footer);set32(24,total);set32(32,footer+27)
  output.replaceSubrange(36..<44,with:Array("WUP-XXXX".utf8));output.replaceSubrange(48..<footer,with:payload)
  output[footer]=60;set32(footer+1,length);output[footer+13]=UInt8(preset&255);output[footer+14]=UInt8(preset>>8)
  output[footer+15]=2;output[footer+16]=0x5a;output[footer+17]=hi ? 0x15:0x14;set32(footer+27,1);set32(footer+31,1)
  return .init(data:Data(output),sourcePayloadSHA256:BackupManifest.digest(Data(payload)),internalTitle:title,
   sourcePrefixBytes:prefix,isHiROM:hi,sramBytes:ram==0 ? 0:1<<(Int(ram)+10),batteryBacked:type==2,saveCount:ram==0 ? 0:3,presetID:preset)
 }
 // Cartridge checksum covers the mirrored address space, not only stored bytes.
 // Recursion consumes successively smaller blocks and never modifies the ROM.
 private static func mirroredSum(_ bytes:[UInt8],start:Int,count:Int)->(sum:Int,span:Int) {
  let block=1<<(Int.bitWidth-1-count.leadingZeroBitCount)
  let first=bytes[start..<start+block].reduce(0){$0+Int($1)}&0xffff
  guard count>block else {return (first,block)}
  let tail=mirroredSum(bytes,start:start+block,count:count-block)
  return ((first+tail.sum*(block/tail.span))&0xffff,block*2)
 }
 private static func cartridgeTitle(_ bytes:[UInt8],_ offset:Int)->String? {
  guard bytes[offset] != 32 else {return nil}
  let raw=Data(bytes[offset..<offset+21])
  let encoding:String.Encoding=raw.allSatisfy{(32...126).contains($0)} ? .ascii:.shiftJIS
  guard let decoded=String(data:raw,encoding:encoding),decoded.rangeOfCharacter(from:.controlCharacters)==nil else {return nil}
  let title=decoded.trimmingCharacters(in:.whitespaces)
  return title.isEmpty ? nil:title
 }
 // Numeric title/preset facts from the pinned primary reference; no special-chip fallback.
 private static let presets:[String:UInt16]=[
  "SUPER MARIOWORLD":0x1011,
  "F-ZERO":0x1018,
  "SUPER MARIO KART":0x10BD,
  "Super Metroid":0x1040,
  "EARTH BOUND":0x1070,
  "Kirby's Dream Course":0x1058,
  "DONKEY KONG COUNTRY":0x1077,
  "KIRBY SUPER DELUXE":0x109F,
  "Super Punch-Out!!":0x10A9,
  "MEGAMAN X":0x1109,
  "SUPER GHOULS'N GHOST":0x1003,
  "Street Fighter2 Turb":0x1065,
  "SUPER MARIO RPG":0x109E,
  "FINAL FANTASY 3":0x10DC,
  "SUPER CASTLEVANIA 4":0x1030,
  "CONTRA3 THE ALIEN WA":0x1036,
  "CONTRA3 THE ALIEN WAR":0x1036,
  "STAR FOX":0x1242,
  "STARFOX2":0x123C,
  "SHVC FIREEMBLEM":0x102B,
  "SUPER DONKEY KONG":0x1023,
  "ROCKMAN X":0x110A,
  "CHOHMAKAIMURA":0x1004,
  "SeikenDensetsu 2":0x10B2,
  "FINAL FANTASY 6":0x10DD,
  "CONTRA SPIRITS":0x1037,
  "ganbare goemon":0x1048,
  "SUPER FORMATION SOCC":0x1240,
  "YOSSY'S ISLAND":0x1243,
  "FINAL FIGHT":0x100E,
  "DIDDY'S KONG QUEST":0x105D,
  "BREATH OF FIRE 2":0x1068,
  "FINAL FIGHT 2":0x10E1,
  "MEGAMAN X2":0x1117,
  "FINAL FIGHT 3":0x10E3,
  "GENGHIS KHAN 2":0x10C4,
  "CASTLEVANIA DRACULA":0x1131,
  "STREET FIGHTER ALPHA":0x10DF,
  "MEGAMAN 7":0x113A,
  "MEGAMAN X3":0x113D,
  "Breath of Fire":0x1144,
 ]
 private static let problemTitles:Set<String>=[
  "ActRaiser-2 USA",
  "ALIEN vs. PREDATOR",
  "ASTERIX",
  "BATMAN--REVENGE JOKER",
  "???????S???????????",
  "CHAMPIONSHIP POOL",
  "ClayFighter 2",
  "CLOCK TOWER SFX",
  "COOL WORLD",
  "CRYSTAL BEANS",
  "CYBER KNIGHT 2",
  "ASCII DARK LAW",
  "DIRT TRAX FX",
  "DBZ HYPER DIMENSION",
  "DRAGON BALL Z HD",
  "DRAGONBALL Z 2",
  "SFX DRAGONBALLZ2",
  "SFX SUPERBUTOUDEN2",
  "DUNGEON MASTER",
  "EARTHWORM JIM 2",
  "F1 WORLD CHAMP EDTION",
  "FACEBALL 2000",
  "THE FIREMEN     PAL",
  "HAMMERIN' HARRY (JPN)",
  "HARMELUNNOBAIOLINHIKI",
  "HOME ALONE",
  "HUMAN GRANDPRIX",
  "HUMAN GRANDPRIX 3",
  "ILLUSION OF GAIA USA",
  "ILLUSION OF TIME ENG",
  "JumpinDerby",
  "KRUSTYS SUPERFUNHOUSE",
  "Mario's Time Machine",
  "MARKOS MAGIC FOOTBALL",
  "POWER RANGERS FIGHT",
  "MOMOTETSU HAPPY",
  "NHL HOCKEY 1998",
  "RENDERING RANGER R2",
  "ROBOTREK 1 USA",
  "ROMANCING SAGA3",
  "SD??????GX",
  "SECRET OF EVERMORE",
  "SIM CITY 2000",
  "SMASH TENNIS",
  "Star Ocean",
  "STREET FIGHTER ALPHA2",
  "SUPER BASES LOADED 2",
  "PANIC BOMBER WORLD",
  "TALES OF PHANTASIA",
  "TERRANIGMA P",
  "TOP GEAR 3000",
  "UNIRACERS",
  "WARIO'S WOODS",
  "WORLD CLASS RUGBY",
  "WORLD CUP STRIKER",
  "WORLD MASTERS GOLF",
  "WWF SUPER WRESTLEMANI",
  "WRESTLEMANIA",
  "SENSIBLE SOCCER",
 ]
}
