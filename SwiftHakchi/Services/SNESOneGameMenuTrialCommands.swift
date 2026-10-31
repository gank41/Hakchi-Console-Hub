import Foundation
import SwiftHakchiCore

/// Fixed RAM-only menu test; no persistent selector, firmware, cleanup or reboot command.
struct SNESOneGameMenuTrialCommands {
 static let originalInitSHA256="d6dfdbf88c1c93af5d25f870f5eb7d198bef9ae17289f2b854b603fb47a35d10"
 static func ramRoot(_ menu:SNESOneGameMenu)->String {"/run/swifthakchi-snes-menu-"+menu.id.uuidString}
 private static func context(menu:SNESOneGameMenu,originals:SNESOriginalGamesFrame,binding:SNESRuntimeBinding)throws->String {
  try SNESOneGameStageCommands.context(menu:menu,binding:binding)+SNESOneGameStageCommands.originalChecks(originals)+"""
  R='\(ramRoot(menu))'
  T=/usr/share/applications/clover-mcp.desktop
  I=/etc/init.d/S81clover-mcp
  test ! -e "$N/active-menu" && test ! -L "$N/active-menu"
  "$B" awk '$2=="/run" {n++;if($3!="tmpfs" || $4 !~ /(^|,)rw(,|$)/)bad=1} END {exit !(n==1&&!bad)}' /proc/mounts
  test -f "$I" && test ! -L "$I"
  value=$("$B" sha256sum "$I");test "${value%% *}" = '\(originalInitSHA256)'
  test -f "$T" && test ! -L "$T"
  folder=$("$B" sh -c \(LaunchCommand.shellQuote(SNESMenuAdapterScripts.verifier)) -- '\(menu.id.uuidString)' '\(menu.treeSHA256)')
  test "$folder" = '\(menu.consoleRoot)/games'
  daemon=$("$B" cat /mnt/swifthakchi/daemon.pid)
  case "$daemon" in ''|*[!0-9]*) exit 1;; esac
  test "$daemon" -gt 1
  no_game() {
    for program in canoe-shvc clover-canoe-shvc clover-kachikachi kachikachi retroarch hc-snes-superv; do
      test -z "$("$B" pidof "$program" || :)" || return 1
    done
  }
  menu_pid() {
    mcp=$("$B" pidof clover-mcp)
    case "$mcp" in ''|*[!0-9]*) return 1;; esac
    test "$mcp" -gt 1 && test "$mcp" != "$daemon"
  }
  no_bind() {
    "$B" awk '$2=="/usr/share/applications/clover-mcp.desktop" {n++} END {exit n!=0}' /proc/mounts
  }
  selected() {
    directory "$R"
    for file in "$R/template" "$R/menu.desktop"; do
      test -f "$file" && test ! -L "$file"
      test "$("$B" stat -c '%h' "$file")" = 1 && test "$("$B" stat -c '%u' "$file")" = 0
    done
    value=$("$B" sha256sum "$R/template");test "${value%% *}" = '\(SNESMenuAdapterScripts.mcpDesktopSHA256)'
    "$B" awk '$2=="/usr/share/applications/clover-mcp.desktop" {n++;if($3!="tmpfs")bad=1} END {exit !(n==1&&!bad)}' /proc/mounts
    test "$("$B" stat -c '%d:%i' "$T")" = "$("$B" stat -c '%d:%i' "$R/menu.desktop")"
    value=$("$B" awk -v folder="$folder" '$0=="GamesFolder = /usr/share/games" {print "GamesFolder = " folder;n++;next}{print}END{if(n!=1)exit 1}' "$R/template" | "$B" sha256sum)
    actual=$("$B" sha256sum "$T");test "${actual%% *}" = "${value%% *}"
    test "$("$B" find "$R" -mindepth 1 -maxdepth 2 | "$B" wc -l)" -eq 2
  }

  """
 }
 private static func receipt(menu:SNESOneGameMenu,binding:SNESRuntimeBinding,challenge:UUID,original:Bool)->String {
  """
  no_game
  menu_pid
  printf '%s\\n' 'SWIFTHAKCHI_SNES_GAME_MENU_TRIAL_V1' 'CHALLENGE=\(challenge.uuidString)' 'HWID=\(binding.expectedHWID)' 'ID=\(menu.id.uuidString)' 'TREE=\(menu.treeSHA256)' 'STATE=\(original ? "original":"ram-menu")'
  printf 'MCP_PID=%s\\nDAEMON_PID=%s\\nSELECTOR_CHANGED=0\\nEND\\n' "$mcp" "$daemon"

  """
 }
 static func startupReport(_ material:SNESOneGameMaterial,challenge:UUID)throws->String {
  try material.validate()
  let checked=try state(menu:material.menu,originals:material.originals.frame,binding:material.accepted.material.trial.candidate.material.binding,challenge:challenge)
  return "set -e\n(\n"+checked+") >/dev/null\n"+(try SNESStartupTrialCommands.script(trial:material.accepted.material.trial,challenge:challenge))
 }
 static func start(menu:SNESOneGameMenu,originals:SNESOriginalGamesFrame,binding:SNESRuntimeBinding,challenge:UUID)throws->String {
  try context(menu:menu,originals:originals,binding:binding)+"""
  test ! -e "$R" && test ! -L "$R"
  no_bind
  no_game
  menu_pid
  previous=$mcp
  # The original stop action sends TERM to MCP, which powers down this console.
  # Match only the observed original menu pair; never signal a game or the USB service.
  process_token() {
    test "$("$B" readlink -f "/proc/$1/exe")" = "/usr/bin/$2" || return 1
    "$B" awk -v pid="$1" -v name="$2" '$1==pid && $2=="(" substr(name,1,15) ")" && $4~/^[0-9]+$/ && $22~/^[0-9]+$/ {print $4 ":" $22;n++}END{if(n!=1)exit 1}' "/proc/$1/stat"
  }
  ui_framebuffer() {
    count=0;found=0
    for descriptor in /proc/"$ui"/fd/*; do
      count=$((count+1));test "$count" -le 64 || return 1
      value=$("$B" readlink -f "$descriptor" 2>/dev/null) || continue
      test "$value" != /dev/fb0 || found=1
    done
    test "$found" = 1
  }
  ui=$("$B" pidof ReedPlayer-Clover)
  case "$ui" in ''|*[!0-9]*) exit 1;; esac
  test "$ui" -gt 1 && test "$ui" != "$previous" && test "$ui" != "$daemon"
  mcp_token=$(process_token "$previous" clover-mcp)
  ui_token=$(process_token "$ui" ReedPlayer-Clover)
  test "${mcp_token%%:*}" = 1 && test "${ui_token%%:*}" = "$previous"
  ui_framebuffer
  value=$("$B" sha256sum "$T");test "${value%% *}" = '\(SNESMenuAdapterScripts.mcpDesktopSHA256)'
  (ulimit -f unlimited) 2>/dev/null
  "$B" mkdir -m 0700 "$R"
  "$B" cp "$T" "$R/template"
  "$B" awk -v folder="$folder" '$0=="GamesFolder = /usr/share/games" {print "GamesFolder = " folder;n++;next}{print}END{if(n!=1)exit 1}' "$R/template" > "$R/menu.desktop"
  "$B" chmod 0600 "$R/template" "$R/menu.desktop"
  no_game
  menu_pid
  test "$mcp" = "$previous"
  test "$(process_token "$previous" clover-mcp)" = "$mcp_token"
  test "$(process_token "$ui" ReedPlayer-Clover)" = "$ui_token"
  test "$("$B" pidof ReedPlayer-Clover)" = "$ui"
  ui_framebuffer
  "$B" kill -KILL "$previous"
  for attempt in 1 2 3 4 5; do
    test -n "$("$B" pidof clover-mcp || :)" || break
    "$B" sleep 1
  done
  test -z "$("$B" pidof clover-mcp || :)"
  # MCP is gone; its menu child may now have been adopted by init. Check its
  # executable and start time again before releasing the framebuffer with TERM.
  current_ui=$(process_token "$ui" ReedPlayer-Clover)
  test "${current_ui#*:}" = "${ui_token#*:}"
  case "${current_ui%%:*}" in 1|"$previous") ;; *) exit 1;; esac
  test "$("$B" pidof ReedPlayer-Clover)" = "$ui"
  ui_framebuffer
  "$B" kill -TERM "$ui"
  for attempt in 1 2 3 4 5; do
    test -n "$("$B" pidof ReedPlayer-Clover || :)" || break
    "$B" sleep 1
  done
  test -z "$("$B" pidof ReedPlayer-Clover || :)"
  no_game
  no_bind
  "$B" mount --bind "$R/menu.desktop" "$T"
  selected
  # Restore original startup's policy only in the menu child, never in the USB daemon.
  (ulimit -f unlimited; exec "$B" sh -e "$I" start) </dev/null >/dev/null 2>&1
  ready=0
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if menu_pid; then ready=1;break;fi
    "$B" sleep 1
  done
  test "$ready" = 1 && test "$mcp" != "$previous"
  selected

  """+receipt(menu:menu,binding:binding,challenge:challenge,original:false)
 }
 static func state(menu:SNESOneGameMenu,originals:SNESOriginalGamesFrame,binding:SNESRuntimeBinding,challenge:UUID,original:Bool=false)throws->String {
  var script=try context(menu:menu,originals:originals,binding:binding)
  if original {script += """
  test ! -e "$R" && test ! -L "$R"
  no_bind
  value=$("$B" sha256sum "$T");test "${value%% *}" = '\(SNESMenuAdapterScripts.mcpDesktopSHA256)'
  (ulimit -f unlimited) 2>/dev/null

  """} else {script += "selected\n"}
  return script+receipt(menu:menu,binding:binding,challenge:challenge,original:original)
 }
}
