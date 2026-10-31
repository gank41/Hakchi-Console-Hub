import Foundation
import SwiftHakchiCore

/// One owned selector only. No firmware, game copy, process signal or restart.
struct SNESMenuSelectionCommands {
 static func selector(menu:SNESOneGameMenu)->Data {
  Data(("SWIFTHAKCHI_SNES_MENU_SELECTOR_V1\n"+menu.id.uuidString+"\n"+menu.treeSHA256+"\n").utf8)
 }
 private static func context(menu:SNESOneGameMenu,originals:SNESOriginalGamesFrame,binding:SNESRuntimeBinding,operation:UUID)throws->String {
  let data=selector(menu:menu)
  guard data.count<=192 else {throw SNESOneGameMenu.failure()}
  return try SNESOneGameStageCommands.context(menu:menu,binding:binding)+SNESOneGameStageCommands.originalChecks(originals)+"""
  S="$N/active-menu"
  P="$N/selection-\(operation.uuidString).pending"
  T=/usr/share/applications/clover-mcp.desktop
  R=/mnt/swifthakchi
  regular() {
    test -f "$1" && test ! -L "$1" || return 1
    test "$("$B" stat -c '%h' "$1")" = 1 && test "$("$B" stat -c '%u' "$1")" = 0 || return 1
  }
  for parent in "${N%/*}" "$N" "$N/menus"; do directory "$parent";done
  for program in canoe-shvc clover-canoe-shvc clover-kachikachi kachikachi retroarch hc-snes-superv; do
    test -z "$("$B" pidof "$program" || :)"
  done
  mcp=$("$B" pidof clover-mcp)
  case "$mcp" in ''|*[!0-9]*) exit 1;;esac
  test "$mcp" -gt 1
  folder=$("$B" sh -c \(LaunchCommand.shellQuote(SNESMenuAdapterScripts.verifier)) -- '\(menu.id.uuidString)' '\(menu.treeSHA256)')
  test "$folder" = '\(menu.consoleRoot)/games'
  display_state() {
    regular "$T"
    count=$("$B" awk '$2=="/usr/share/applications/clover-mcp.desktop" {n++;if($3!="tmpfs")bad=1}END{if(bad || n>1)exit 1;print n+0}' /proc/mounts)
    value=$("$B" sha256sum "$T")
    if test "$count" = 0; then
      test "${value%% *}" = '\(SNESMenuAdapterScripts.mcpDesktopSHA256)'
      display=original
    else
      regular "$R/mcp-template";regular "$R/mcp-selected"
      original=$("$B" sha256sum "$R/mcp-template");test "${original%% *}" = '\(SNESMenuAdapterScripts.mcpDesktopSHA256)'
      left=$("$B" stat -c '%d:%i' "$T");right=$("$B" stat -c '%d:%i' "$R/mcp-selected")
      test -n "$left" && test "$left" = "$right" || exit 1
      expected=$("$B" awk -v folder="$folder" '$0=="GamesFolder = /usr/share/games" {print "GamesFolder = " folder;n++;next}{print}END{if(n!=1)exit 1}' "$R/mcp-template" | "$B" sha256sum)
      test "${value%% *}" = "${expected%% *}"
      display=selected
    fi
  }
  selector_state() {
    if test -e "$S" || test -L "$S"; then
      regular "$S"
      test "$("$B" stat -c '%a' "$S")" = 600
      test "$("$B" wc -c < "$S")" -eq \(data.count)
      value=$("$B" sha256sum "$S");test "${value%% *}" = '\(BackupManifest.digest(data))'
      selected='\(BackupManifest.digest(data))'
    else selected=missing;fi
  }

  """
 }
 private static func receipt(menu:SNESOneGameMenu,binding:SNESRuntimeBinding,operation:UUID,challenge:UUID)->String {
  """
  printf '%s\\n' 'SWIFTHAKCHI_SNES_MENU_SELECTION_V1' 'CHALLENGE=\(challenge.uuidString)' 'HWID=\(binding.expectedHWID)' 'OPERATION=\(operation.uuidString)' 'ID=\(menu.id.uuidString)' 'TREE=\(menu.treeSHA256)'
  printf 'SELECTOR=%s\\nDISPLAY=%s\\nEND\\n' "$selected" "$display"

  """
 }
 static func inspect(menu:SNESOneGameMenu,originals:SNESOriginalGamesFrame,binding:SNESRuntimeBinding,operation:UUID,challenge:UUID)throws->String {
  try context(menu:menu,originals:originals,binding:binding,operation:operation)+"""
  test ! -e "$P" && test ! -L "$P" || exit 1
  selector_state
  display_state

  """+receipt(menu:menu,binding:binding,operation:operation,challenge:challenge)
 }
 static func publish(menu:SNESOneGameMenu,originals:SNESOriginalGamesFrame,binding:SNESRuntimeBinding,operation:UUID,challenge:UUID)throws->String {
  let data=selector(menu:menu)
  return try context(menu:menu,originals:originals,binding:binding,operation:operation)+"""
  test ! -e "$S" && test ! -L "$S" || exit 1
  test ! -e "$P" && test ! -L "$P" || exit 1
  display_state;test "$display" = original
  (set -C;ulimit -f 1;printf '%s' \(LaunchCommand.shellQuote(String(decoding:data,as:UTF8.self))) > "$P")
  regular "$P"
  test "$("$B" stat -c '%a' "$P")" = 600
  test "$("$B" wc -c < "$P")" -eq \(data.count)
  value=$("$B" sha256sum "$P");test "${value%% *}" = '\(BackupManifest.digest(data))'
  "$B" sync
  # No overwrite and no directory-target following, even if another selector appears.
  "$B" ln -T "$P" "$S"
  test -f "$P" && test ! -L "$P" && test -f "$S" && test ! -L "$S" || exit 1
  test "$("$B" stat -c '%h' "$P")" = 2 && test "$("$B" stat -c '%h' "$S")" = 2 || exit 1
  left=$("$B" stat -c '%d:%i' "$P");right=$("$B" stat -c '%d:%i' "$S")
  test -n "$left" && test "$left" = "$right" || exit 1
  "$B" rm "$P"
  "$B" sync
  selector_state
  display_state;test "$display" = original
  path=$("$B" sh -c \(LaunchCommand.shellQuote(SNESMenuAdapterScripts.verifier)))
  test "$path" = "$folder"

  """+receipt(menu:menu,binding:binding,operation:operation,challenge:challenge)
 }
}

struct SNESMenuSelectionReceipt:Sendable {
 let raw:Data,selected:Bool,displaySelected:Bool,challenge:UUID
 init(_ raw:Data,menu:SNESOneGameMenu,binding:SNESRuntimeBinding,operation:UUID,challenge:UUID)throws {
  try binding.validate()
  guard raw.count<=2048,let text=String(data:raw,encoding:.ascii) else {throw SNESOneGameMenu.failure()}
  let lines=text.components(separatedBy:"\n"),hash=BackupManifest.digest(SNESMenuSelectionCommands.selector(menu:menu))
  guard lines.count==10,lines[0]=="SWIFTHAKCHI_SNES_MENU_SELECTION_V1",lines[1]=="CHALLENGE="+challenge.uuidString,
    lines[2]=="HWID="+binding.expectedHWID,lines[3]=="OPERATION="+operation.uuidString,lines[4]=="ID="+menu.id.uuidString,
    lines[5]=="TREE="+menu.treeSHA256,["SELECTOR=missing","SELECTOR="+hash].contains(lines[6]),
    ["DISPLAY=original","DISPLAY=selected"].contains(lines[7]),lines[8]=="END",lines[9].isEmpty else {throw SNESOneGameMenu.failure()}
  self.raw=raw;selected=lines[6] != "SELECTOR=missing";displaySelected=lines[7]=="DISPLAY=selected";self.challenge=challenge
 }
}
