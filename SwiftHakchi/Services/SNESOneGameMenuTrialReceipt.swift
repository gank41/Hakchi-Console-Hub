import Foundation
struct SNESOneGameMenuTrialReceipt:Sendable {
 let raw:Data,challenge:UUID,mcpPID:Int,daemonPID:Int,original:Bool
 init(_ raw:Data,id:UUID,tree:String,binding:SNESRuntimeBinding,challenge:UUID,original:Bool)throws {
  try binding.validate()
  guard raw.count<=4096,let text=String(data:raw,encoding:.ascii) else {throw SNESOneGameMenu.failure()}
  let rows=text.components(separatedBy:"\n")
  guard rows.count==11,rows[0]=="SWIFTHAKCHI_SNES_GAME_MENU_TRIAL_V1",rows[1]=="CHALLENGE="+challenge.uuidString,
        rows[2]=="HWID="+binding.expectedHWID,rows[3]=="ID="+id.uuidString,rows[4]=="TREE="+tree,
        rows[5]=="STATE="+(original ? "original":"ram-menu"),rows[6].hasPrefix("MCP_PID="),rows[7].hasPrefix("DAEMON_PID="),
        rows[8]=="SELECTOR_CHANGED=0",rows[9]=="END",rows[10]=="" else {throw SNESOneGameMenu.failure()}
  func pid(_ row:String,_ prefix:Int)throws->Int {let value=String(row.dropFirst(prefix));guard let n=Int(value),String(n)==value,(2...4194304).contains(n) else {throw SNESOneGameMenu.failure()};return n}
  let m=try pid(rows[6],8),d=try pid(rows[7],11);guard m != d else {throw SNESOneGameMenu.failure()}
  self.raw=raw;self.challenge=challenge;mcpPID=m;daemonPID=d;self.original=original
 }
}
