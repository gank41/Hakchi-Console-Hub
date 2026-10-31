import Foundation
import SwiftHakchiCore

/// New runtime format beside the immutable one-game verifier. No writer or restart is included.
enum SNESLibraryStartupScripts {
    /// Offline candidate only; never install or use this to authorize a sync.
    static func experimentalCompatibilityVerifier() throws -> String {
        var script = verifier
        func replace(_ old: String, _ new: String) throws {
            guard script.components(separatedBy: old).count == 2 else { throw SNESLibraryCompatibility.failure("Experimental verifier source changed: " + String(old.prefix(100))) }
            script = script.replacingOccurrences(of: old, with: new)
        }
        try replace(#"SWIFTHAKCHI_SNES_LIBRARY_V2) format=2;;*)"#, #"SWIFTHAKCHI_SNES_LIBRARY_V2) format=2;;SWIFTHAKCHI_SNES_LIBRARY_V4) format=4;;*)"#)
        try replace(#"substr(x,65)~/^(\.sfrom|\.png|_small\.png)$/"#, #"substr(x,65)~/^(\.sfrom|\.sfc|\.smc|\.png|_small\.png)$/"#)
        try replace(#"else if($0=="SWIFTHAKCHI_SNES_LIBRARY_V2")format=2;else die()"#, #"else if($0=="SWIFTHAKCHI_SNES_LIBRARY_V2")format=2;else if($0=="SWIFTHAKCHI_SNES_LIBRARY_V4")format=4;else die()"#)
        try replace(#"!number($3,4194400) || $3==0 || !digest($4)"#, #"!number($3,4194816) || (format!=4 && $3>4194400) || $3==0 || !digest($4)"#)
        try replace(#"if($2~/\.sfrom$/) {if($2!=$4 ".sfrom" || $3<96) die()} else if(format==2 || $3>262144) die()"#,
                    #"if($2~/\.sfrom$/) {if($2!=$4 ".sfrom" || $3<96 || $3>4194400) die()} else if($2~/\.(sfc|smc)$/) {if(format!=4 || $2!=$4 substr($2,65))die()} else if(format==2 || format==4 || $3>262144) die()"#)
        try replace(#"else if(format!=2 || substr(p[3],1,6)=="CLV-P-""#, #"else if((format!=2 && format!=4) || substr(p[3],1,6)=="CLV-P-""#)
        try replace(#"if(format==2) {total+=$3;if(total>134217728)die()}"#, #"if(format==2 || format==4) {total+=$3;if(total>134217728)die()}"#)
        try replace(#"usedObject[$7]=1\#n      } else if($5=="link") {"#,
                    #"usedObject[$7]=1\#n      } else if($5=="compat") {\#n        if(format!=4 || substr($4,1,6)!="CLV-U-" || chosenGame[$4]++ || $6!="-" || !($7 in obj) || $7!~/\.(sfc|smc)$/) die()\#n        usedObject[$7]=1\#n      } else if($5=="link") {"#)
        try replace(#"if test "$format" = 2;then"#, #"if test "$format" = 2 || test "$format" = 4;then"#)
        try replace(#"if(kind=="import") {\#n              if(fields["exec"]!="/usr/bin/clover-canoe-shvc -rom " root rom " --volume 100 -rollback-snapshot-period 600""#,
                    #"if(kind=="import" || kind=="compat") {\#n              expectedExec=kind=="import" ? "/usr/bin/clover-canoe-shvc -rom " root rom " --volume 100 -rollback-snapshot-period 600" : "/mnt/swifthakchi/hc-snes-superv --game " code " --rom " root rom\#n              if(fields["exec"]!=expectedExec"#)
        return script
    }
    /// Mac-only description for the not-yet-supported compatibility runtime.
    /// It does not authorize installation or alter the production manifest gate.
    static func compatibilityCandidateManifest(for menu:SNESLibraryMenu)throws->Data {
        guard menu.description.version == 4 else {throw SNESLibraryMenu.failure()}
        return try encodeManifest(for:menu)
    }
    static func manifest(for menu: SNESLibraryMenu) throws -> Data {
        guard [1, 2].contains(menu.description.version) else { throw SNESLibraryMenu.failure() }
        return try encodeManifest(for:menu)
    }
    private static func encodeManifest(for menu:SNESLibraryMenu)throws->Data {
        try menu.validate()
        let m = menu.description
        var lines = ["SWIFTHAKCHI_SNES_LIBRARY_V"+String(m.version), "ID " + m.id.uuidString, "LIMIT \(m.graph.maximumGamesPerPage)"]
        for page in m.graph.screens { lines.append(String(format: "PAGE %03d %d", page.number, page.entryCount)) }
        for stock in m.stock { lines.append("STOCK \(stock.code) \(stock.desktopSHA256) \(stock.romSHA256) \(stock.romBytes)") }
        for object in m.objects { lines.append("OBJECT \(object.name) \(object.byteCount) \(object.sha256)") }
        for file in m.files { lines.append("FILE \(file.path) \(file.byteCount) \(file.sha256)") }
        for entry in m.placements {
            lines.append(String(format: "ENTRY %03d %03d %@ %@ %@ %@ %@ %@", entry.page, entry.position, entry.code, entry.kind,
                                entry.target.map { String(format: "%03d", $0) } ?? "-", entry.rom ?? "-", entry.artwork ?? "-", entry.smallArtwork ?? "-"))
        }
        lines.append("END \(m.graph.screens.count) \(m.stock.count) \(m.objects.count) \(m.files.count) \(m.placements.count)")
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        guard data.count <= 1024 * 1024 else { throw SNESLibraryMenu.failure() }; return data
    }
    static func configuration() throws -> String {
        var script = SNESMenuAdapterScripts.configure
        let absent = "if test ! -e /var/lib/swifthakchi/snes-v1/active-menu && test ! -L /var/lib/swifthakchi/snes-v1/active-menu; then exit 0; fi\n"
        let old = """
        if ! folder=$("$B" sh "$R/menu-selector"); then
          if test -e /var/lib/swifthakchi/snes-v1/active-menu || test -L /var/lib/swifthakchi/snes-v1/active-menu; then
            printf '%s\\n' 'Swift Hakchi: added games were not ready; starting the built-in games.' >&2
          fi
          exit 0
        fi
        """
        let new = """
        if ! folder=$("$B" sh "$R/menu-route"); then
          printf '%s\\n' 'Swift Hakchi: added games were not ready; starting the built-in games.' >&2
          exit 0
        fi
        test "$folder" != /usr/share/games || exit 0
        """
        guard script.components(separatedBy: absent).count == 2, script.components(separatedBy: old).count == 2 else { throw SNESRuntimeBinding.failure() }
        script = script.replacingOccurrences(of: absent, with: "").replacingOccurrences(of: old, with: new)
        return script
    }
    /// Folder navigation changes only RAM state and the verified original menu processes.
    static let legacyChangePage = #"""
    #!/bin/sh
    set -eu
    set -o pipefail
    set -f
    umask 077
    R=/mnt/swifthakchi
    B="$R/busybox"
    P=/proc
    N=/var/lib/swifthakchi/snes-v2
    T=/usr/share/applications/clover-mcp.desktop
    test "$#" -eq 1
    target=$1
    case "$target" in [0-9][0-9][0-9]) ;; *) exit 1;; esac
    test -d "$R" && test ! -L "$R"
    "$B" sha256sum -c "$R/runtime-files.sha256" >/dev/null
    regular() {
      test -f "$1" && test ! -L "$1" || return 1
      test "$("$B" stat -c '%h' "$1")" = 1
      test "$("$B" stat -c '%u' "$1")" = 0
    }
    no_game() { test -z "$("$B" pidof canoe-shvc clover-canoe-shvc kachikachi clover-kachikachi || :)"; }
    process_token() {
      test "$("$B" readlink -f "$P/$1/exe")" = "/usr/bin/$2" || return 1
      "$B" awk -v pid="$1" -v name="$2" '$1==pid && $2=="(" substr(name,1,15) ")" && $4~/^[0-9]+$/ && $22~/^[0-9]+$/ {print $4 ":" $22;n++}END{if(n!=1)exit 1}' "$P/$1/stat"
    }
    framebuffer() (
      set +f
      count=0; found=0
      for descriptor in "$P/$ui"/fd/*; do
        count=$((count+1)); test "$count" -le 64 || return 1
        value=$("$B" readlink -f "$descriptor" 2>/dev/null) || continue
        test "$value" != /dev/fb0 || found=1
      done
      test "$found" = 1
    )
    configured() {
      regular "$T"; regular "$R/mcp-selected"; regular "$R/mcp-template"
      test "$("$B" stat -c '%d:%i' "$T")" = "$("$B" stat -c '%d:%i' "$R/mcp-selected")"
      value=$("$B" awk -v folder="$1" '$0=="GamesFolder = /usr/share/games"{print "GamesFolder = " folder;n++;next}{print}END{if(n!=1)exit 1}' "$R/mcp-template" | "$B" sha256sum)
      actual=$("$B" sha256sum "$T"); test "${value%% *}" = "${actual%% *}"
    }
    "$B" mkdir -m 0700 "$R/menu-change.lock"
    published=0; stopped=0; prior=0
    pending="$R/library-page.$$.pending"
    previous="$R/library-page.$$.previous"
    cleanup() {
      result=$?; trap - EXIT
      if test "$result" != 0 && test "$published" = 1 && test "$stopped" = 0; then
        if regular "$R/library-page"; then
          value=$("$B" sha256sum "$R/library-page")
          if test "${value%% *}" = "$published_hash"; then
            if test "$prior" = 1; then "$B" mv -f "$previous" "$R/library-page"; else "$B" rm "$R/library-page"; fi
          fi
        fi
      fi
      for file in "$pending" "$previous"; do
        if test -f "$file" && test ! -L "$file"; then "$B" rm "$file"; fi
      done
      "$B" rmdir "$R/menu-change.lock" || :
      exit "$result"
    }
    trap cleanup EXIT
    test ! -e "$pending" && test ! -L "$pending" && test ! -e "$previous" && test ! -L "$previous"
    if test -e "$R/library-page" || test -L "$R/library-page"; then
      regular "$R/library-page"
      test "$("$B" stat -c '%s' "$R/library-page")" -le 256
      "$B" cp "$R/library-page" "$previous"
      regular "$previous"; prior=1
    fi
    root=$("$B" sh "$R/library-selector")
    regular "$N/active-menu"
    selection=$("$B" cat "$N/active-menu")
    exec 3< "$N/active-menu"
    IFS= read -r header <&3; IFS= read -r kind <&3; IFS= read -r id <&3; IFS= read -r tree <&3
    if IFS= read -r extra <&3; then exit 1; fi
    exec 3<&-
    test "$header" = SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1 && test "$kind" = MENU
    test "$root" = "$N/menus/$id/pages/000"
    folder=$("$B" sh "$R/library-selector" "$id" "$tree" "$target")
    test "$folder" = "$N/menus/$id/pages/$target"
    current=$("$B" awk '/^GamesFolder = /{print substr($0,15);n++}END{if(n!=1)exit 1}' "$T")
    case "$current" in "$N/menus/$id/pages/"[0-9][0-9][0-9]) ;; *) exit 1;; esac
    active_page=${current##*/}
    checked=$("$B" sh "$R/library-selector" "$id" "$tree" "$active_page"); test "$checked" = "$current"
    configured "$current"
    no_game
    regular "$R/daemon.pid"
    daemon=$("$B" cat "$R/daemon.pid"); case "$daemon" in ''|*[!0-9]*) exit 1;; esac
    test "$daemon" -gt 1
    test "$("$B" readlink -f "$P/$daemon/exe")" = "$R/ld-linux-armhf.so.3"
    mcp=$("$B" pidof clover-mcp); case "$mcp" in ''|*[!0-9]*) exit 1;; esac
    test "$mcp" -gt 1 && test "$mcp" != "$daemon" && test "$mcp" != "$$"
    mcp_token=$(process_token "$mcp" clover-mcp); test "${mcp_token%%:*}" = 1
    ui=$("$B" pidof ReedPlayer-Clover || :)
    if test -n "$ui"; then
      case "$ui" in *[!0-9]*) exit 1;; esac
      test "$ui" -gt 1 && test "$ui" != "$mcp" && test "$ui" != "$daemon"
      ui_token=$(process_token "$ui" ReedPlayer-Clover); test "${ui_token%%:*}" = "$mcp"
      framebuffer
    fi
    (set -C; printf 'SWIFTHAKCHI_SNES_LIBRARY_PAGE_V1\n%s\n%s\n%s\n' "$id" "$tree" "$target" > "$pending")
    regular "$pending"
    value=$("$B" sha256sum "$pending"); published_hash=${value%% *}
    "$B" mv -f "$pending" "$R/library-page"
    regular "$R/library-page"; published=1
    no_game; configured "$current"
    test "$("$B" cat "$N/active-menu")" = "$selection"
    test "$(process_token "$mcp" clover-mcp)" = "$mcp_token"
    test "$("$B" pidof clover-mcp)" = "$mcp"
    test "$("$B" pidof ReedPlayer-Clover || :)" = "$ui"
    if test -n "$ui"; then test "$(process_token "$ui" ReedPlayer-Clover)" = "$ui_token"; framebuffer; fi
    # Original MCP's TERM handler shuts down the console. Never call it or stock stop.
    "$B" kill -KILL "$mcp"
    stopped=1
    for attempt in 1 2 3 4 5; do
      test -n "$("$B" pidof clover-mcp || :)" || break
      "$B" sleep 1
    done
    test -z "$("$B" pidof clover-mcp || :)"
    if test -n "$ui"; then
      current_ui=$(process_token "$ui" ReedPlayer-Clover)
      test "${current_ui#*:}" = "${ui_token#*:}"
      case "${current_ui%%:*}" in 1|"$mcp") ;; *) exit 1;; esac
      framebuffer
      "$B" kill -TERM "$ui"
      for attempt in 1 2 3 4 5; do
        test -n "$("$B" pidof ReedPlayer-Clover || :)" || break
        "$B" sleep 1
      done
      test -z "$("$B" pidof ReedPlayer-Clover || :)"
    fi
    no_game
    test "$("$B" cat "$N/active-menu")" = "$selection"
    (ulimit -f unlimited; exec "$B" sh -e "$R/menu-wrapper" start) </dev/null >/dev/null 2>&1
    ready=0
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      next=$("$B" pidof clover-mcp || :)
      case "$next" in ''|*[!0-9]*) ;; *) if test "$next" -gt 1 && test "$next" != "$mcp" && test "$next" != "$daemon"; then ready=1; break; fi;; esac
      "$B" sleep 1
    done
    test "$ready" = 1
    checked=$("$B" sh "$R/menu-route"); test "$checked" = "$folder"
    configured "$folder"
    """# + "\n"

    /// A rejected new selector falls back to stock in configure, never to a stale legacy menu.
    static let legacyRoute = #"""
    #!/bin/sh
    set -eu
    R=/mnt/swifthakchi
    B="$R/busybox"
    N=/var/lib/swifthakchi/snes-v2
    L=/var/lib/swifthakchi/snes-v1
    if test -e "$N/active-menu" || test -L "$N/active-menu"; then
      folder=$("$B" sh "$R/library-selector")
      if test "$folder" = /usr/share/games; then printf '%s\n' "$folder"; exit 0; fi
      page="$R/library-page"
      if test -f "$page" && test ! -L "$page" && test "$("$B" stat -c '%h' "$page")" = 1 && test "$("$B" stat -c '%u' "$page")" = 0 && test "$("$B" stat -c '%s' "$page")" -le 256; then
        exec 3< "$page"
        if IFS= read -r header <&3 && IFS= read -r id <&3 && IFS= read -r tree <&3 && IFS= read -r target <&3; then
          if ! IFS= read -r extra <&3 && test "$header" = SWIFTHAKCHI_SNES_LIBRARY_PAGE_V1; then
            expected=$(printf 'SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1\nMENU\n%s\n%s\n' "$id" "$tree")
            if test "$("$B" cat "$N/active-menu")" = "$expected"; then
              selected=$("$B" sh "$R/library-selector" "$id" "$tree" "$target")
              test "$("$B" cat "$N/active-menu")" = "$expected"
              printf '%s\n' "$selected"; exit 0
            fi
          fi
        fi
        exec 3<&-
      fi
      printf '%s\n' "$folder"
    elif test -e "$L/active-menu" || test -L "$L/active-menu"; then
      exec "$B" sh "$R/menu-selector"
    else
      printf '%s\n' /usr/share/games
    fi
    """# + "\n"
    // Frozen recipe 5: existing recovery records reconstruct these exact bytes.
    static let legacyVerifier = #"""
    #!/bin/sh
    set -eu
    set -o pipefail
    set -f
    export LC_ALL=C
    B=/mnt/swifthakchi/busybox
    N=/var/lib/swifthakchi/snes-v2
    S=/usr/share/games
    regular() {
      test -f "$1" && test ! -L "$1" || return 1
      test "$("$B" stat -c '%h' "$1")" = 1
      test "$("$B" stat -c '%u' "$1")" = 0
    }
    directory() { test -d "$1" && test ! -L "$1" || return 1; test "$("$B" stat -c '%u' "$1")" = 0; }
    ascii_file() {
      regular "$1"
      size=$("$B" wc -c < "$1" | "$B" tr -d '[:space:]')
      test "$size" -gt 0 && test "$size" -le "$2"
      clean=$("$B" tr -cd '\12\40-\176' < "$1" | "$B" wc -c | "$B" tr -d '[:space:]')
      test "$clean" = "$size"
      test "$("$B" tail -c 1 "$1" | "$B" wc -l)" -eq 1
    }
    selected_page=000
    selector=''
    directory "${N%/*}"; directory "$N"
    if test "$#" -eq 0; then
      ascii_file "$N/active-menu" 256
      selector=$("$B" cat "$N/active-menu")
      exec 3< "$N/active-menu"
      IFS= read -r header <&3; IFS= read -r kind <&3
      test "$header" = SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1
      if test "$kind" = BUILTIN; then
        if IFS= read -r extra <&3; then exit 1; fi
        exec 3<&-; printf '%s\n' "$S"; exit 0
      fi
      test "$kind" = MENU
      IFS= read -r id <&3; IFS= read -r tree <&3
      if IFS= read -r extra <&3; then exit 1; fi
      exec 3<&-
    elif test "$#" -eq 2 || test "$#" -eq 3; then
      id=$1; tree=$2; selected_page=${3:-000}
      case "$selected_page" in [0-9][0-9][0-9]) ;; *) exit 1;; esac
    else exit 1
    fi
    case "$id" in ????????-????-????-????-????????????) ;; *) exit 1;; esac
    case "$id" in *[!0-9A-F-]*) exit 1;; esac
    test "${#tree}" = 64; case "$tree" in *[!0-9a-f]*) exit 1;; esac
    directory "$N/menus"; directory "$N/objects"
    base="$N/menus/$id"
    directory "$base"; directory "$base/pages"
    manifest="$base/menu.manifest"
    ascii_file "$manifest" 1048576
    value=$("$B" sha256sum "$manifest"); test "${value%% *}" = "$tree"
    # Validate the complete bounded graph and every path before any path is opened.
    "$B" awk -v id="$id" '
      function die() { bad=1; exit 1 }
      function digest(x) { return length(x)==64 && x~/^[0-9a-f]+$/ }
      function number(x, max) { return length(x)<=8 && x~/^(0|[1-9][0-9]*)$/ && x+0<=max }
      function page(x) { return length(x)==3 && x~/^[0-9]+$/ && x==sprintf("%03d",x+0) && x+0<32 }
      function slot(x) { return length(x)==3 && x~/^[0-9]+$/ && x==sprintf("%03d",x+0) && x+0<37 }
      function code(x) { return length(x)==11 && x~/^CLV-[PUS]-[A-Z0-9]+$/ }
      function object(x) { return digest(substr(x,1,64)) && substr(x,65)~/^(\.sfrom|\.png|_small\.png)$/ }
      NR==1 { if($0!="SWIFTHAKCHI_SNES_LIBRARY_V1") die(); next }
      NR==2 { if(NF!=2 || $0!="ID " id) die(); next }
      NR==3 { if(NF!=2 || $1!="LIMIT" || ($2!=20 && $2!=25 && $2!=30 && $2!=35)) die(); limit=$2; next }
      ended { die() }
      $1=="PAGE" {
        if(NF!=3 || phase>1 || !page($2) || $2+0!=pages || !number($3,limit+2) || $3==0) die()
        phase=1; expected[$2]=$3; pages++; next
      }
      $1=="STOCK" {
        if(NF!=5 || phase>2 || !code($2) || substr($2,1,6)!="CLV-P-" || stock[$2]++ || !digest($3) || !digest($4) || !number($5,16777216) || $5<96 || ++stocks>48) die()
        phase=2; next
      }
      $1=="OBJECT" {
        if(NF!=4 || phase>3 || !object($2) || obj[$2]++ || !number($3,4194400) || $3==0 || !digest($4) || ++objects>1024) die()
        if($2~/\.sfrom$/) {if($2!=$4 ".sfrom" || $3<96) die()} else if($3>262144) die()
        phase=3; total+=$3; if(total>134217728) die(); next
      }
      $1=="FILE" {
        if(NF!=4 || phase>4 || !number($3,16384) || $3==0 || !digest($4) || files[$2]++ || ++fileCount>2048) die()
        if(split($2,p,"/")!=4 || p[1]!="pages" || !page(p[2]) || !(p[2] in expected) || !code(p[3]) || p[4]!=p[3] ".desktop") die()
        phase=4; next
      }
      $1=="ENTRY" {
        if(NF!=9 || phase>5 || !page($2) || !slot($3) || !($2 in expected) || $3+0!=seen[$2] || !code($4) || placed[$2 "/" $4]++) die()
        path="pages/" $2 "/" $4 "/" $4 ".desktop"; if(!(path in files) || usedFile[path]++) die()
        if($5=="stock") {
          if(!($4 in stock) || chosenStock[$4]++ || $6!="-" || $7!="-" || $8!="-" || $9!="-" || chosenGame[$4]++) die()
        } else {
          if(!($8 in obj) || !($9 in obj) || length($8)!=68 || $8!~/\.png$/ || $9!=substr($8,1,64) "_small.png") die()
          usedObject[$8]=1; usedObject[$9]=1
          if($5=="import") {
            if(substr($4,1,6)!="CLV-U-" || chosenGame[$4]++ || $6!="-" || !($7 in obj) || $7!~/\.sfrom$/) die()
            usedObject[$7]=1
          } else if($5=="link") {
            if(!page($6) || !($6 in expected) || $6==$2 || $4!=sprintf("CLV-S-%05d",$6+0) || $7!="-") die()
            edges[$2 SUBSEP $6]=1
          } else die()
        }
        if($5!="link" && ++games>304) die()
        phase=5; seen[$2]++; entries++; next
      }
      $1=="END" {
        if(NF!=6 || $0!="END " pages " " stocks+0 " " objects+0 " " fileCount " " entries || entries!=fileCount || pages<1 || pages>32) die()
        ended=1; next
      }
      { die() }
      END {
        if(bad || !ended) exit 1
        for(pageID in expected) if(seen[pageID]!=expected[pageID]) exit 1
        for(s in stock) if(chosenStock[s]!=1) exit 1
        for(o in obj) if(!usedObject[o]) exit 1
        reached["000"]=1
        for(i=0;i<32;i++) for(edge in edges) {split(edge,v,SUBSEP);if(reached[v[1]]) reached[v[2]]=1}
        for(pageID in expected) if(!reached[pageID]) exit 1
      }
    ' "$manifest"
    exec 4< "$manifest"
    files=0; objects=0; entries=0; pages=0
    while IFS= read -r row <&4; do
      set -- $row
      case "$1" in
        PAGE) directory "$base/pages/$2"; pages=$((pages+1));;
        STOCK)
          regular "$S/$2/$2.desktop"
          value=$("$B" sha256sum "$S/$2/$2.desktop"); test "${value%% *}" = "$3";;
        OBJECT)
          regular "$N/objects/$2"
          test "$("$B" stat -c '%s' "$N/objects/$2")" = "$3"
          objects=$((objects+1));;
        FILE)
          regular "$base/$2"
          test "$("$B" stat -c '%s' "$base/$2")" = "$3"
          files=$((files+1));;
        ENTRY)
          page=$2; rank=$3; code=$4; kind=$5; target=$6; rom=$7; art=$8
          directory "$base/pages/$page/$code"
          desktop="$base/pages/$page/$code/$code.desktop"
          if test "$kind" = stock; then
            # Compare to the read-only original after changing only its sorting key.
            value=$("$B" awk -v rank="$((0))" -v ordinal="$rank" '
              { sub(/\r$/,"",$0); line[NR]=$0; if($0!="") last=NR }
              END {
                rank=sprintf("%05d",ordinal+0);found=0
                for(i=1;i<=last;i++) {
                  if(tolower(line[i])~/^sortrawtitle=/) {print "SortRawTitle=" rank;found=1}
                  else print line[i]
                }
                if(!found) {print "[X-CLOVER Game]"; print "SortRawTitle=" rank}
              }
            ' "$S/$code/$code.desktop" | "$B" sha256sum)
            actual=$("$B" sha256sum "$desktop"); test "${value%% *}" = "${actual%% *}"
          else
            "$B" awk -v kind="$kind" -v code="$code" -v root="$N/objects/" -v rom="$rom" -v art="$art" -v target="$target" -v ordinal="$rank" '
              function die() {bad=1;exit 1}
              $0=="[Desktop Entry]" {if(group || header++)die();group=1;next}
              $0=="[X-CLOVER Game]" {if(group!=1 || gameHeader++)die();group=2;next}
              $0=="" {next}
              {
                at=index($0,"=");if(at<2 || length($0)>2048)die()
                key=tolower(substr($0,1,at-1));value=substr($0,at+1)
                if(key in fields)die();fields[key]=value
                desktop=(key=="type"||key=="exec"||key=="path"||key=="name"||key=="icon")
                if((desktop && group!=1)||(!desktop && group!=2))die()
              }
              END {
                if(bad || header!=1 || gameHeader!=1 || fields["type"]!="Application" || fields["code"]!=code || fields["name"]=="" || length(fields["name"])>256 || fields["icon"]!=root art || fields["sortrawtitle"]!=sprintf("%05d",ordinal+0))exit 1
                if(kind=="import") {
                  if(fields["exec"]!="/usr/bin/clover-canoe-shvc -rom " root rom " --volume 100 -rollback-snapshot-period 600" || fields["path"]!="/var/lib/clover/profiles/0/" code || fields["players"]!~/^[1-5]$/ || fields["savecount"]!~/^[0-4]$/ || fields["simultaneous"]!~/^[01]$/)exit 1
                  allowed="type exec path name icon code testid status id players simultaneous releasedate savecount sortrawtitle sortrawpublisher copyright myplaydemotime"
                } else {
                  if(fields["exec"]!="/mnt/swifthakchi/menu-change " target || fields["path"]!="/var/lib/clover/profiles/0/FOLDER" || fields["testid"]!="777")exit 1
                  allowed="type exec path name icon code testid id players simultaneous releasedate savecount sortrawtitle sortrawpublisher"
                }
                n=split(allowed,keys," ");for(i=1;i<=n;i++) {if(!(keys[i] in fields))exit 1;delete fields[keys[i]]}
                for(key in fields)exit 1
              }
            ' "$desktop"
          fi
          entries=$((entries+1));;
      esac
    done
    exec 4<&-
    "$B" awk -v base="$base" -v root="$N/objects/" '$1=="FILE" {print $4 "  " base "/" $2} $1=="OBJECT" {print $4 "  " root $2}' "$manifest" | "$B" sha256sum -c - >/dev/null
    test "$("$B" find "$base" -mindepth 1 -maxdepth 1 | "$B" wc -l)" -eq 2
    test "$("$B" find "$base" -type f | "$B" wc -l)" -eq $((files+1))
    test "$("$B" find "$base" -type d | "$B" wc -l)" -eq $((2+pages+entries))
    test -z "$("$B" find "$base" ! -type f ! -type d -print)"
    actual=$("$B" sha256sum "$manifest"); test "${actual%% *}" = "$tree"
    if test -n "$selector"; then test "$("$B" cat "$N/active-menu")" = "$selector"; fi
    "$B" awk -v page="$selected_page" '$1=="PAGE" && $2==page {n++} END{if(n!=1)exit 1}' "$manifest"
    printf '%s\n' "$base/pages/$selected_page"
    """# + "\n"

    /// Recipe 6 uses explicit decimal digits on the console's BusyBox awk.
    static let legacyArtworkVerifier = #"""
    #!/bin/sh
    set -eu
    set -o pipefail
    set -f
    export LC_ALL=C
    B=/mnt/swifthakchi/busybox
    N=/var/lib/swifthakchi/snes-v2
    S=/usr/share/games
    regular() {
      test -f "$1" && test ! -L "$1" || return 1
      test "$("$B" stat -c '%h' "$1")" = 1
      test "$("$B" stat -c '%u' "$1")" = 0
    }
    directory() { test -d "$1" && test ! -L "$1" || return 1; test "$("$B" stat -c '%u' "$1")" = 0; }
    ascii_file() {
      regular "$1"
      size=$("$B" wc -c < "$1" | "$B" tr -d '[:space:]')
      test "$size" -gt 0 && test "$size" -le "$2"
      clean=$("$B" tr -cd '\12\40-\176' < "$1" | "$B" wc -c | "$B" tr -d '[:space:]')
      test "$clean" = "$size"
      test "$("$B" tail -c 1 "$1" | "$B" wc -l)" -eq 1
    }
    selected_page=000
    selector=''
    directory "${N%/*}"; directory "$N"
    if test "$#" -eq 0; then
      ascii_file "$N/active-menu" 256
      selector=$("$B" cat "$N/active-menu")
      exec 3< "$N/active-menu"
      IFS= read -r header <&3; IFS= read -r kind <&3
      test "$header" = SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1
      if test "$kind" = BUILTIN; then
        if IFS= read -r extra <&3; then exit 1; fi
        exec 3<&-; printf '%s\n' "$S"; exit 0
      fi
      test "$kind" = MENU
      IFS= read -r id <&3; IFS= read -r tree <&3
      if IFS= read -r extra <&3; then exit 1; fi
      exec 3<&-
    elif test "$#" -eq 2 || test "$#" -eq 3; then
      id=$1; tree=$2; selected_page=${3:-000}
      case "$selected_page" in [0-9][0-9][0-9]) ;; *) exit 1;; esac
    else exit 1
    fi
    case "$id" in ????????-????-????-????-????????????) ;; *) exit 1;; esac
    case "$id" in *[!0-9A-F-]*) exit 1;; esac
    test "${#tree}" = 64; case "$tree" in *[!0-9a-f]*) exit 1;; esac
    directory "$N/menus"; directory "$N/objects"
    base="$N/menus/$id"
    directory "$base"; directory "$base/pages"
    manifest="$base/menu.manifest"
    ascii_file "$manifest" 1048576
    value=$("$B" sha256sum "$manifest"); test "${value%% *}" = "$tree"
    # Validate the complete bounded graph and every path before any path is opened.
    "$B" awk -v id="$id" '
      function decimal(x, i, n) { n=0; for(i=1;i<=length(x);i++) n=n*10+index("0123456789",substr(x,i,1))-1; return n }
      function die() { bad=1; exit 1 }
      function digest(x) { return length(x)==64 && x~/^[0-9a-f]+$/ }
      function number(x, max) { return length(x)<=8 && x~/^(0|[1-9][0-9]*)$/ && x+0<=max }
      function page(x) { return length(x)==3 && x~/^[0-9]+$/ && decimal(x)<32 }
      function slot(x) { return length(x)==3 && x~/^[0-9]+$/ && decimal(x)<37 }
      function code(x) { return length(x)==11 && x~/^CLV-[PUS]-[A-Z0-9]+$/ }
      function object(x) { return digest(substr(x,1,64)) && substr(x,65)~/^(\.sfrom|\.png|_small\.png)$/ }
      NR==1 { if($0!="SWIFTHAKCHI_SNES_LIBRARY_V1") die(); next }
      NR==2 { if(NF!=2 || $0!="ID " id) die(); next }
      NR==3 { if(NF!=2 || $1!="LIMIT" || ($2!=20 && $2!=25 && $2!=30 && $2!=35)) die(); limit=$2; next }
      ended { die() }
      $1=="PAGE" {
        if(NF!=3 || phase>1 || !page($2) || decimal($2)!=pages || !number($3,limit+2) || $3==0) die()
        phase=1; expected[$2]=$3; pages++; next
      }
      $1=="STOCK" {
        if(NF!=5 || phase>2 || !code($2) || substr($2,1,6)!="CLV-P-" || stock[$2]++ || !digest($3) || !digest($4) || !number($5,16777216) || $5<96 || ++stocks>48) die()
        phase=2; next
      }
      $1=="OBJECT" {
        if(NF!=4 || phase>3 || !object($2) || obj[$2]++ || !number($3,4194400) || $3==0 || !digest($4) || ++objects>1024) die()
        if($2~/\.sfrom$/) {if($2!=$4 ".sfrom" || $3<96) die()} else if($3>262144) die()
        phase=3; total+=$3; if(total>134217728) die(); next
      }
      $1=="FILE" {
        if(NF!=4 || phase>4 || !number($3,16384) || $3==0 || !digest($4) || files[$2]++ || ++fileCount>2048) die()
        if(split($2,p,"/")!=4 || p[1]!="pages" || !page(p[2]) || !(p[2] in expected) || !code(p[3]) || p[4]!=p[3] ".desktop") die()
        phase=4; next
      }
      $1=="ENTRY" {
        if(NF!=9 || phase>5 || !page($2) || !slot($3) || !($2 in expected) || decimal($3)!=seen[$2] || !code($4) || placed[$2 "/" $4]++) die()
        path="pages/" $2 "/" $4 "/" $4 ".desktop"; if(!(path in files) || usedFile[path]++) die()
        if($5=="stock") {
          if(!($4 in stock) || chosenStock[$4]++ || $6!="-" || $7!="-" || $8!="-" || $9!="-" || chosenGame[$4]++) die()
        } else {
          if(!($8 in obj) || !($9 in obj) || length($8)!=68 || $8!~/\.png$/ || $9!=substr($8,1,64) "_small.png") die()
          usedObject[$8]=1; usedObject[$9]=1
          if($5=="import") {
            if(substr($4,1,6)!="CLV-U-" || chosenGame[$4]++ || $6!="-" || !($7 in obj) || $7!~/\.sfrom$/) die()
            usedObject[$7]=1
          } else if($5=="link") {
            if(!page($6) || !($6 in expected) || $6==$2 || $4!=sprintf("CLV-S-%05d",decimal($6)) || $7!="-") die()
            edges[$2 SUBSEP $6]=1
          } else die()
        }
        if($5!="link" && ++games>304) die()
        phase=5; seen[$2]++; entries++; next
      }
      $1=="END" {
        if(NF!=6 || $0!="END " pages " " stocks+0 " " objects+0 " " fileCount " " entries || entries!=fileCount || pages<1 || pages>32) die()
        ended=1; next
      }
      { die() }
      END {
        if(bad || !ended) exit 1
        for(pageID in expected) if(seen[pageID]!=expected[pageID]) exit 1
        for(s in stock) if(chosenStock[s]!=1) exit 1
        for(o in obj) if(!usedObject[o]) exit 1
        reached["000"]=1
        for(i=0;i<32;i++) for(edge in edges) {split(edge,v,SUBSEP);if(reached[v[1]]) reached[v[2]]=1}
        for(pageID in expected) if(!reached[pageID]) exit 1
      }
    ' "$manifest"
    exec 4< "$manifest"
    files=0; objects=0; entries=0; pages=0
    while IFS= read -r row <&4; do
      set -- $row
      case "$1" in
        PAGE) directory "$base/pages/$2"; pages=$((pages+1));;
        STOCK)
          regular "$S/$2/$2.desktop"
          value=$("$B" sha256sum "$S/$2/$2.desktop"); test "${value%% *}" = "$3";;
        OBJECT)
          regular "$N/objects/$2"
          test "$("$B" stat -c '%s' "$N/objects/$2")" = "$3"
          objects=$((objects+1));;
        FILE)
          regular "$base/$2"
          test "$("$B" stat -c '%s' "$base/$2")" = "$3"
          files=$((files+1));;
        ENTRY)
          page=$2; rank=$3; code=$4; kind=$5; target=$6; rom=$7; art=$8
          directory "$base/pages/$page/$code"
          desktop="$base/pages/$page/$code/$code.desktop"
          if test "$kind" = stock; then
            # Compare to the read-only original after changing only its sorting key.
            value=$("$B" awk -v rank="$((0))" -v ordinal="$rank" '
              function decimal(x, i, n) { n=0; for(i=1;i<=length(x);i++) n=n*10+index("0123456789",substr(x,i,1))-1; return n }
        { sub(/\r$/,"",$0); line[NR]=$0; if($0!="") last=NR }
              END {
                rank=sprintf("%05d",decimal(ordinal));found=0
                for(i=1;i<=last;i++) {
                  if(tolower(line[i])~/^sortrawtitle=/) {print "SortRawTitle=" rank;found=1}
                  else print line[i]
                }
                if(!found) {print "[X-CLOVER Game]"; print "SortRawTitle=" rank}
              }
            ' "$S/$code/$code.desktop" | "$B" sha256sum)
            actual=$("$B" sha256sum "$desktop"); test "${value%% *}" = "${actual%% *}"
          else
            "$B" awk -v kind="$kind" -v code="$code" -v root="$N/objects/" -v rom="$rom" -v art="$art" -v target="$target" -v ordinal="$rank" '
              function decimal(x, i, n) { n=0; for(i=1;i<=length(x);i++) n=n*10+index("0123456789",substr(x,i,1))-1; return n }
        function die() {bad=1;exit 1}
              $0=="[Desktop Entry]" {if(group || header++)die();group=1;next}
              $0=="[X-CLOVER Game]" {if(group!=1 || gameHeader++)die();group=2;next}
              $0=="" {next}
              {
                at=index($0,"=");if(at<2 || length($0)>2048)die()
                key=tolower(substr($0,1,at-1));value=substr($0,at+1)
                if(key in fields)die();fields[key]=value
                desktop=(key=="type"||key=="exec"||key=="path"||key=="name"||key=="icon")
                if((desktop && group!=1)||(!desktop && group!=2))die()
              }
              END {
                if(bad || header!=1 || gameHeader!=1 || fields["type"]!="Application" || fields["code"]!=code || fields["name"]=="" || length(fields["name"])>256 || fields["icon"]!=root art || fields["sortrawtitle"]!=sprintf("%05d",decimal(ordinal)))exit 1
                if(kind=="import") {
                  if(fields["exec"]!="/usr/bin/clover-canoe-shvc -rom " root rom " --volume 100 -rollback-snapshot-period 600" || fields["path"]!="/var/lib/clover/profiles/0/" code || fields["players"]!~/^[1-5]$/ || fields["savecount"]!~/^[0-4]$/ || fields["simultaneous"]!~/^[01]$/)exit 1
                  allowed="type exec path name icon code testid status id players simultaneous releasedate savecount sortrawtitle sortrawpublisher copyright myplaydemotime"
                } else {
                  if(fields["exec"]!="/mnt/swifthakchi/menu-change " target || fields["path"]!="/var/lib/clover/profiles/0/FOLDER" || fields["testid"]!="777")exit 1
                  allowed="type exec path name icon code testid id players simultaneous releasedate savecount sortrawtitle sortrawpublisher"
                }
                n=split(allowed,keys," ");for(i=1;i<=n;i++) {if(!(keys[i] in fields))exit 1;delete fields[keys[i]]}
                for(key in fields)exit 1
              }
            ' "$desktop"
          fi
          entries=$((entries+1));;
      esac
    done
    exec 4<&-
    "$B" awk -v base="$base" -v root="$N/objects/" '$1=="FILE" {print $4 "  " base "/" $2} $1=="OBJECT" {print $4 "  " root $2}' "$manifest" | "$B" sha256sum -c - >/dev/null
    test "$("$B" find "$base" -mindepth 1 -maxdepth 1 | "$B" wc -l)" -eq 2
    test "$("$B" find "$base" -type f | "$B" wc -l)" -eq $((files+1))
    test "$("$B" find "$base" -type d | "$B" wc -l)" -eq $((2+pages+entries))
    test -z "$("$B" find "$base" ! -type f ! -type d -print)"
    actual=$("$B" sha256sum "$manifest"); test "${actual%% *}" = "$tree"
    if test -n "$selector"; then test "$("$B" cat "$N/active-menu")" = "$selector"; fi
    "$B" awk -v page="$selected_page" '$1=="PAGE" && "p" $2=="p" page {n++} END{if(n!=1)exit 1}' "$manifest"
    printf '%s\n' "$base/pages/$selected_page"
    """# + "\n"

    /// Recipes 10+ also accept native code-named menu-local PNGs.
    static let verifier = #"""
    #!/bin/sh
    set -eu
    set -o pipefail
    set -f
    export LC_ALL=C
    B=/mnt/swifthakchi/busybox
    N=/var/lib/swifthakchi/snes-v2
    S=/usr/share/games
    regular() {
      test -f "$1" && test ! -L "$1" || return 1
      test "$("$B" stat -c '%h' "$1")" = 1
      test "$("$B" stat -c '%u' "$1")" = 0
    }
    directory() { test -d "$1" && test ! -L "$1" || return 1; test "$("$B" stat -c '%u' "$1")" = 0; }
    ascii_file() {
      regular "$1"
      size=$("$B" wc -c < "$1" | "$B" tr -d '[:space:]')
      test "$size" -gt 0 && test "$size" -le "$2"
      clean=$("$B" tr -cd '\12\40-\176' < "$1" | "$B" wc -c | "$B" tr -d '[:space:]')
      test "$clean" = "$size"
      test "$("$B" tail -c 1 "$1" | "$B" wc -l)" -eq 1
    }
    selected_page=000
    selector=''
    directory "${N%/*}"; directory "$N"
    if test "$#" -eq 0; then
      ascii_file "$N/active-menu" 256
      selector=$("$B" cat "$N/active-menu")
      exec 3< "$N/active-menu"
      IFS= read -r header <&3; IFS= read -r kind <&3
      test "$header" = SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1
      if test "$kind" = BUILTIN; then
        if IFS= read -r extra <&3; then exit 1; fi
        exec 3<&-; printf '%s\n' "$S"; exit 0
      fi
      test "$kind" = MENU
      IFS= read -r id <&3; IFS= read -r tree <&3
      if IFS= read -r extra <&3; then exit 1; fi
      exec 3<&-
    elif test "$#" -eq 2 || test "$#" -eq 3; then
      id=$1; tree=$2; selected_page=${3:-000}
      case "$selected_page" in [0-9][0-9][0-9]) ;; *) exit 1;; esac
    else exit 1
    fi
    case "$id" in ????????-????-????-????-????????????) ;; *) exit 1;; esac
    case "$id" in *[!0-9A-F-]*) exit 1;; esac
    test "${#tree}" = 64; case "$tree" in *[!0-9a-f]*) exit 1;; esac
    directory "$N/menus"; directory "$N/objects"
    base="$N/menus/$id"
    directory "$base"; directory "$base/pages"
    manifest="$base/menu.manifest"
    ascii_file "$manifest" 1048576
    value=$("$B" sha256sum "$manifest"); test "${value%% *}" = "$tree"
    format=$("$B" head -n 1 "$manifest")
    case "$format" in SWIFTHAKCHI_SNES_LIBRARY_V1) format=1;;SWIFTHAKCHI_SNES_LIBRARY_V2) format=2;;*) exit 1;;esac
    # Validate the complete bounded graph and every path before any path is opened.
    "$B" awk -v id="$id" '
      function decimal(x, i, n) { n=0; for(i=1;i<=length(x);i++) n=n*10+index("0123456789",substr(x,i,1))-1; return n }
      function die() { bad=1; exit 1 }
      function digest(x) { return length(x)==64 && x~/^[0-9a-f]+$/ }
      function number(x, max) { return length(x)<=8 && x~/^(0|[1-9][0-9]*)$/ && x+0<=max }
      function page(x) { return length(x)==3 && x~/^[0-9]+$/ && decimal(x)<32 }
      function slot(x) { return length(x)==3 && x~/^[0-9]+$/ && decimal(x)<37 }
      function code(x) { return length(x)==11 && x~/^CLV-[PUS]-[A-Z0-9]+$/ }
      function object(x) { return digest(substr(x,1,64)) && substr(x,65)~/^(\.sfrom|\.png|_small\.png)$/ }
      NR==1 { if($0=="SWIFTHAKCHI_SNES_LIBRARY_V1") format=1;else if($0=="SWIFTHAKCHI_SNES_LIBRARY_V2")format=2;else die();next }
      NR==2 { if(NF!=2 || $0!="ID " id) die(); next }
      NR==3 { if(NF!=2 || $1!="LIMIT" || ($2!=20 && $2!=25 && $2!=30 && $2!=35)) die(); limit=$2; next }
      ended { die() }
      $1=="PAGE" {
        if(NF!=3 || phase>1 || !page($2) || decimal($2)!=pages || !number($3,limit+2) || $3==0) die()
        phase=1; expected[$2]=$3; pages++; next
      }
      $1=="STOCK" {
        if(NF!=5 || phase>2 || !code($2) || substr($2,1,6)!="CLV-P-" || stock[$2]++ || !digest($3) || !digest($4) || !number($5,16777216) || $5<96 || ++stocks>48) die()
        phase=2; next
      }
      $1=="OBJECT" {
        if(NF!=4 || phase>3 || !object($2) || obj[$2]++ || !number($3,4194400) || $3==0 || !digest($4) || ++objects>1024) die()
        if($2~/\.sfrom$/) {if($2!=$4 ".sfrom" || $3<96) die()} else if(format==2 || $3>262144) die()
        phase=3; total+=$3; if(total>134217728) die(); next
      }
      $1=="FILE" {
        if(NF!=4 || phase>4 || !number($3,262144) || $3==0 || !digest($4) || files[$2]++ || ++fileCount>2048) die()
        if(split($2,p,"/")!=4 || p[1]!="pages" || !page(p[2]) || !(p[2] in expected) || !code(p[3])) die()
        if(p[4]==p[3] ".desktop") {if($3>16384)die()}
        else if(format!=2 || substr(p[3],1,6)=="CLV-P-" || (p[4]!=p[3] ".png" && p[4]!=p[3] "_small.png"))die()
        if(format==2) {total+=$3;if(total>134217728)die()}
        phase=4; next
      }
      $1=="ENTRY" {
        if(NF!=9 || phase>5 || !page($2) || !slot($3) || !($2 in expected) || decimal($3)!=seen[$2] || !code($4) || placed[$2 "/" $4]++) die()
        path="pages/" $2 "/" $4 "/" $4 ".desktop"; if(!(path in files) || usedFile[path]++) die()
        if($5=="stock") {
          if(!($4 in stock) || chosenStock[$4]++ || $6!="-" || $7!="-" || $8!="-" || $9!="-" || chosenGame[$4]++) die()
        } else {
          if(length($8)!=68 || !digest(substr($8,1,64)) || $8!~/\.png$/ || $9!=substr($8,1,64) "_small.png") die()
          if(format==1) {
            if(!($8 in obj) || !($9 in obj))die()
            usedObject[$8]=1;usedObject[$9]=1
          } else {
            large="pages/" $2 "/" $4 "/" $4 ".png";small="pages/" $2 "/" $4 "/" $4 "_small.png"
            if(!(large in files) || !(small in files) || usedFile[large]++ || usedFile[small]++)die()
          }
          if($5=="import") {
            if(substr($4,1,6)!="CLV-U-" || chosenGame[$4]++ || $6!="-" || !($7 in obj) || $7!~/\.sfrom$/) die()
            usedObject[$7]=1
          } else if($5=="link") {
            if(!page($6) || !($6 in expected) || $6==$2 || $4!=sprintf("CLV-S-%05d",decimal($6)) || $7!="-") die()
            edges[$2 SUBSEP $6]=1
          } else die()
        }
        if($5!="link" && ++games>304) die()
        phase=5; seen[$2]++; entries++; next
      }
      $1=="END" {
        if(NF!=6 || $0!="END " pages " " stocks+0 " " objects+0 " " fileCount " " entries ||  pages<1 || pages>32) die()
        ended=1; next
      }
      { die() }
      END {
        if(bad || !ended) exit 1
        for(pageID in expected) if(seen[pageID]!=expected[pageID]) exit 1
        for(s in stock) if(chosenStock[s]!=1) exit 1
        for(o in obj) if(!usedObject[o]) exit 1
        for(f in files) if(usedFile[f]!=1)exit 1
        reached["000"]=1
        for(i=0;i<32;i++) for(edge in edges) {split(edge,v,SUBSEP);if(reached[v[1]]) reached[v[2]]=1}
        for(pageID in expected) if(!reached[pageID]) exit 1
      }
    ' "$manifest"
    exec 4< "$manifest"
    files=0; objects=0; entries=0; pages=0
    while IFS= read -r row <&4; do
      set -- $row
      case "$1" in
        PAGE) directory "$base/pages/$2"; pages=$((pages+1));;
        STOCK)
          regular "$S/$2/$2.desktop"
          value=$("$B" sha256sum "$S/$2/$2.desktop"); test "${value%% *}" = "$3";;
        OBJECT)
          regular "$N/objects/$2"
          test "$("$B" stat -c '%s' "$N/objects/$2")" = "$3"
          objects=$((objects+1));;
        FILE)
          regular "$base/$2"
          test "$("$B" stat -c '%s' "$base/$2")" = "$3"
          files=$((files+1));;
        ENTRY)
          page=$2; rank=$3; code=$4; kind=$5; target=$6; rom=$7; art=$8
          directory "$base/pages/$page/$code"
          desktop="$base/pages/$page/$code/$code.desktop"
          if test "$kind" = stock; then
            # Compare to the read-only original after changing only its sorting key.
            value=$("$B" awk -v rank="$((0))" -v ordinal="$rank" '
              function decimal(x, i, n) { n=0; for(i=1;i<=length(x);i++) n=n*10+index("0123456789",substr(x,i,1))-1; return n }
        { sub(/\r$/,"",$0); line[NR]=$0; if($0!="") last=NR }
              END {
                rank=sprintf("%05d",decimal(ordinal));found=0
                for(i=1;i<=last;i++) {
                  if(tolower(line[i])~/^sortrawtitle=/) {print "SortRawTitle=" rank;found=1}
                  else print line[i]
                }
                if(!found) {print "[X-CLOVER Game]"; print "SortRawTitle=" rank}
              }
            ' "$S/$code/$code.desktop" | "$B" sha256sum)
            actual=$("$B" sha256sum "$desktop"); test "${value%% *}" = "${actual%% *}"
          else
            icon="$N/objects/$art"
            if test "$format" = 2;then
              large="$base/pages/$page/$code/$code.png";small="$base/pages/$page/$code/$code"_small.png
              value=$("$B" sha256sum "$large");a=${value%% *}
              value=$("$B" sha256sum "$small");b=${value%% *}
              value=$(printf '%s:%s' "$a" "$b" | "$B" sha256sum);test "$art" = "${value%% *}.png"
              icon="$large"
            fi
            "$B" awk -v kind="$kind" -v code="$code" -v root="$N/objects/" -v rom="$rom" -v art="$art" -v expected_icon="$icon" -v target="$target" -v ordinal="$rank" '
              function decimal(x, i, n) { n=0; for(i=1;i<=length(x);i++) n=n*10+index("0123456789",substr(x,i,1))-1; return n }
        function die() {bad=1;exit 1}
              $0=="[Desktop Entry]" {if(group || header++)die();group=1;next}
              $0=="[X-CLOVER Game]" {if(group!=1 || gameHeader++)die();group=2;next}
              $0=="" {next}
              {
                at=index($0,"=");if(at<2 || length($0)>2048)die()
                key=tolower(substr($0,1,at-1));value=substr($0,at+1)
                if(key in fields)die();fields[key]=value
                desktop=(key=="type"||key=="exec"||key=="path"||key=="name"||key=="icon")
                if((desktop && group!=1)||(!desktop && group!=2))die()
              }
              END {
                if(bad || header!=1 || gameHeader!=1 || fields["type"]!="Application" || fields["code"]!=code || fields["name"]=="" || length(fields["name"])>256 || fields["icon"]!=expected_icon || fields["sortrawtitle"]!=sprintf("%05d",decimal(ordinal)))exit 1
                if(kind=="import") {
                  if(fields["exec"]!="/usr/bin/clover-canoe-shvc -rom " root rom " --volume 100 -rollback-snapshot-period 600" || fields["path"]!="/var/lib/clover/profiles/0/" code || fields["players"]!~/^[1-5]$/ || fields["savecount"]!~/^[0-4]$/ || fields["simultaneous"]!~/^[01]$/)exit 1
                  allowed="type exec path name icon code testid status id players simultaneous releasedate savecount sortrawtitle sortrawpublisher copyright myplaydemotime"
                } else {
                  if(fields["exec"]!="/mnt/swifthakchi/menu-change " target || fields["path"]!="/var/lib/clover/profiles/0/FOLDER" || fields["testid"]!="777")exit 1
                  allowed="type exec path name icon code testid id players simultaneous releasedate savecount sortrawtitle sortrawpublisher"
                }
                n=split(allowed,keys," ");for(i=1;i<=n;i++) {if(!(keys[i] in fields))exit 1;delete fields[keys[i]]}
                for(key in fields)exit 1
              }
            ' "$desktop"
          fi
          entries=$((entries+1));;
      esac
    done
    exec 4<&-
    "$B" awk -v base="$base" -v root="$N/objects/" '$1=="FILE" {print $4 "  " base "/" $2} $1=="OBJECT" {print $4 "  " root $2}' "$manifest" | "$B" sha256sum -c - >/dev/null
    test "$("$B" find "$base" -mindepth 1 -maxdepth 1 | "$B" wc -l)" -eq 2
    test "$("$B" find "$base" -type f | "$B" wc -l)" -eq $((files+1))
    test "$("$B" find "$base" -type d | "$B" wc -l)" -eq $((2+pages+entries))
    test -z "$("$B" find "$base" ! -type f ! -type d -print)"
    actual=$("$B" sha256sum "$manifest"); test "${actual%% *}" = "$tree"
    if test -n "$selector"; then test "$("$B" cat "$N/active-menu")" = "$selector"; fi
    "$B" awk -v page="$selected_page" '$1=="PAGE" && "p" $2=="p" page {n++} END{if(n!=1)exit 1}' "$manifest"
    printf '%s\n' "$base/pages/$selected_page"
    """# + "\n"

    /// Recipe 7 accepts the stock manager's bounded launch options.
    static let launchCompatibleChangePage = #"""
    #!/bin/sh
    set -eu
    set -o pipefail
    set -f
    umask 077
    R=/mnt/swifthakchi
    B="$R/busybox"
    P=/proc
    N=/var/lib/swifthakchi/snes-v2
    T=/usr/share/applications/clover-mcp.desktop
    # Clover adds launch options to folder commands. Only the page controls navigation.
    test "$#" -ge 1 && test "$#" -le 65
    target=$1; shift
    case "$target" in [0-9][0-9][0-9]) ;; *) exit 1;; esac
    page_number=$((1$target-1000)); test "$page_number" -lt 32
    expected_code=$(printf 'CLV-S-%05d' "$page_number")
    seen=' '; transition_fds=''
    while test "$#" -gt 0; do
      test "$#" -ge 2
      option=$1; value=$2; shift 2
      test "${#value}" -le 4096
      case "$option" in
        --title-code|--video-mode|--save-data-backing-file|--save-screenshot-on-quit|--rollback-output-dir|--rollback-mode|--save-on-quit|--rollback-input-dir|--load-state-file|--replay-inputs|--decorative-frame-path|--load-time-path|--save-time-path|--wait-transition-fd|--start-transition-fd|--finish-transition-fd) ;;
        *) exit 1;;
      esac
      case "$seen" in *" $option "*) exit 1;; esac
      seen="$seen$option "
      case "$option" in
        --title-code) test "$value" = "$expected_code";;
        --wait-transition-fd|--start-transition-fd|--finish-transition-fd)
          case "$value" in ''|*[!0-9]*|0?*) exit 1;; esac
          test "${#value}" -le 3
          test "$value" -ge 3
          test "$value" -le 255
          transition_fds="$transition_fds $value";;
      esac
    done
    test -d "$R" && test ! -L "$R"
    "$B" sha256sum -c "$R/runtime-files.sha256" >/dev/null
    regular() {
      test -f "$1" && test ! -L "$1" || return 1
      test "$("$B" stat -c '%h' "$1")" = 1
      test "$("$B" stat -c '%u' "$1")" = 0
    }
    no_game() { test -z "$("$B" pidof canoe-shvc clover-canoe-shvc kachikachi clover-kachikachi || :)"; }
    process_token() {
      test "$("$B" readlink -f "$P/$1/exe")" = "/usr/bin/$2" || return 1
      "$B" awk -v pid="$1" -v name="$2" '$1==pid && $2=="(" substr(name,1,15) ")" && $4~/^[0-9]+$/ && $22~/^[0-9]+$/ {print $4 ":" $22;n++}END{if(n!=1)exit 1}' "$P/$1/stat"
    }
    framebuffer() (
      set +f
      count=0; found=0
      for descriptor in "$P/$ui"/fd/*; do
        count=$((count+1)); test "$count" -le 64 || return 1
        value=$("$B" readlink -f "$descriptor" 2>/dev/null) || continue
        test "$value" != /dev/fb0 || found=1
      done
      test "$found" = 1
    )
    configured() {
      regular "$T"; regular "$R/mcp-selected"; regular "$R/mcp-template"
      test "$("$B" stat -c '%d:%i' "$T")" = "$("$B" stat -c '%d:%i' "$R/mcp-selected")"
      value=$("$B" awk -v folder="$1" '$0=="GamesFolder = /usr/share/games"{print "GamesFolder = " folder;n++;next}{print}END{if(n!=1)exit 1}' "$R/mcp-template" | "$B" sha256sum)
      actual=$("$B" sha256sum "$T"); test "${value%% *}" = "${actual%% *}"
    }
    "$B" mkdir -m 0700 "$R/menu-change.lock"
    published=0; stopped=0; prior=0
    pending="$R/library-page.$$.pending"
    previous="$R/library-page.$$.previous"
    cleanup() {
      result=$?; trap - EXIT
      if test "$result" != 0 && test "$published" = 1 && test "$stopped" = 0; then
        if regular "$R/library-page"; then
          value=$("$B" sha256sum "$R/library-page")
          if test "${value%% *}" = "$published_hash"; then
            if test "$prior" = 1; then "$B" mv -f "$previous" "$R/library-page"; else "$B" rm "$R/library-page"; fi
          fi
        fi
      fi
      for file in "$pending" "$previous"; do
        if test -f "$file" && test ! -L "$file"; then "$B" rm "$file"; fi
      done
      "$B" rmdir "$R/menu-change.lock" || :
      exit "$result"
    }
    trap cleanup EXIT
    test ! -e "$pending" && test ! -L "$pending" && test ! -e "$previous" && test ! -L "$previous"
    if test -e "$R/library-page" || test -L "$R/library-page"; then
      regular "$R/library-page"
      test "$("$B" stat -c '%s' "$R/library-page")" -le 256
      "$B" cp "$R/library-page" "$previous"
      regular "$previous"; prior=1
    fi
    root=$("$B" sh "$R/library-selector")
    regular "$N/active-menu"
    selection=$("$B" cat "$N/active-menu")
    exec 3< "$N/active-menu"
    IFS= read -r header <&3; IFS= read -r kind <&3; IFS= read -r id <&3; IFS= read -r tree <&3
    if IFS= read -r extra <&3; then exit 1; fi
    exec 3<&-
    test "$header" = SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1 && test "$kind" = MENU
    test "$root" = "$N/menus/$id/pages/000"
    folder=$("$B" sh "$R/library-selector" "$id" "$tree" "$target")
    test "$folder" = "$N/menus/$id/pages/$target"
    current=$("$B" awk '/^GamesFolder = /{print substr($0,15);n++}END{if(n!=1)exit 1}' "$T")
    case "$current" in "$N/menus/$id/pages/"[0-9][0-9][0-9]) ;; *) exit 1;; esac
    active_page=${current##*/}
    checked=$("$B" sh "$R/library-selector" "$id" "$tree" "$active_page"); test "$checked" = "$current"
    configured "$current"
    no_game
    regular "$R/daemon.pid"
    daemon=$("$B" cat "$R/daemon.pid"); case "$daemon" in ''|*[!0-9]*) exit 1;; esac
    test "$daemon" -gt 1
    test "$("$B" readlink -f "$P/$daemon/exe")" = "$R/ld-linux-armhf.so.3"
    mcp=$("$B" pidof clover-mcp); case "$mcp" in ''|*[!0-9]*) exit 1;; esac
    test "$mcp" -gt 1 && test "$mcp" != "$daemon" && test "$mcp" != "$$"
    mcp_token=$(process_token "$mcp" clover-mcp); test "${mcp_token%%:*}" = 1
    ui=$("$B" pidof ReedPlayer-Clover || :)
    if test -n "$ui"; then
      case "$ui" in *[!0-9]*) exit 1;; esac
      test "$ui" -gt 1 && test "$ui" != "$mcp" && test "$ui" != "$daemon"
      ui_token=$(process_token "$ui" ReedPlayer-Clover); test "${ui_token%%:*}" = "$mcp"
      framebuffer
    fi
    (set -C; printf 'SWIFTHAKCHI_SNES_LIBRARY_PAGE_V1\n%s\n%s\n%s\n' "$id" "$tree" "$target" > "$pending")
    regular "$pending"
    value=$("$B" sha256sum "$pending"); published_hash=${value%% *}
    "$B" mv -f "$pending" "$R/library-page"
    regular "$R/library-page"; published=1
    no_game; configured "$current"
    test "$("$B" cat "$N/active-menu")" = "$selection"
    test "$(process_token "$mcp" clover-mcp)" = "$mcp_token"
    test "$("$B" pidof clover-mcp)" = "$mcp"
    test "$("$B" pidof ReedPlayer-Clover || :)" = "$ui"
    if test -n "$ui"; then test "$(process_token "$ui" ReedPlayer-Clover)" = "$ui_token"; framebuffer; fi
    # Original MCP's TERM handler shuts down the console. Never call it or stock stop.
    "$B" kill -KILL "$mcp"
    stopped=1
    for attempt in 1 2 3 4 5; do
      test -n "$("$B" pidof clover-mcp || :)" || break
      "$B" sleep 1
    done
    test -z "$("$B" pidof clover-mcp || :)"
    if test -n "$ui"; then
      current_ui=$(process_token "$ui" ReedPlayer-Clover)
      test "${current_ui#*:}" = "${ui_token#*:}"
      case "${current_ui%%:*}" in 1|"$mcp") ;; *) exit 1;; esac
      framebuffer
      "$B" kill -TERM "$ui"
      for attempt in 1 2 3 4 5; do
        test -n "$("$B" pidof ReedPlayer-Clover || :)" || break
        "$B" sleep 1
      done
      test -z "$("$B" pidof ReedPlayer-Clover || :)"
    fi
    no_game
    test "$("$B" cat "$N/active-menu")" = "$selection"
    # Keep the previous launcher's pipes out of the replacement manager.
    (
      for descriptor in $transition_fds; do eval "exec ${descriptor}>&-"; done
      ulimit -f unlimited
      exec "$B" sh -e "$R/menu-wrapper" start
    ) </dev/null >/dev/null 2>&1
    ready=0
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      next=$("$B" pidof clover-mcp || :)
      case "$next" in ''|*[!0-9]*) ;; *) if test "$next" -gt 1 && test "$next" != "$mcp" && test "$next" != "$daemon"; then ready=1; break; fi;; esac
      "$B" sleep 1
    done
    test "$ready" = 1
    checked=$("$B" sh "$R/menu-route"); test "$checked" = "$folder"
    configured "$folder"
    """# + "\n"

    // Recipe 8 removes redundant graph passes; recipes 5-7 remain immutable.
    static let route = #"""
    #!/bin/sh
    set -eu
    set -o pipefail
    set -f
    R=/mnt/swifthakchi
    B="$R/busybox"
    N=/var/lib/swifthakchi/snes-v2
    L=/var/lib/swifthakchi/snes-v1
    regular() {
     test -f "$1" && test ! -L "$1" || return 1
     test "$("$B" stat -c '%h' "$1")" = 1
     test "$("$B" stat -c '%u' "$1")" = 0
    }
    if test -e "$N/active-menu" || test -L "$N/active-menu"; then
     regular "$N/active-menu"
     size=$("$B" stat -c '%s' "$N/active-menu"); test "$size" -gt 0 && test "$size" -le 256
     clean=$("$B" tr -cd '\12\40-\176' < "$N/active-menu" | "$B" wc -c | "$B" tr -d '[:space:]'); test "$clean" = "$size"
     value=$("$B" sha256sum "$N/active-menu"); selection_hash=${value%% *}
     exec 3< "$N/active-menu"
     IFS= read -r header <&3; IFS= read -r kind <&3
     test "$header" = SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1
     case "$kind" in
      BUILTIN)
       if IFS= read -r extra <&3; then exit 1; fi
       exec 3<&-
       folder=$("$B" sh "$R/library-selector");;
      MENU)
       IFS= read -r id <&3; IFS= read -r tree <&3
       if IFS= read -r extra <&3; then exit 1; fi
       exec 3<&-
       target=000
       page="$R/library-page"
       if test -f "$page" && test ! -L "$page" && test "$("$B" stat -c '%h' "$page")" = 1 && test "$("$B" stat -c '%u' "$page")" = 0 && test "$("$B" stat -c '%s' "$page")" -le 256; then
        exec 3< "$page"
        if IFS= read -r page_header <&3 && IFS= read -r page_id <&3 && IFS= read -r page_tree <&3 && IFS= read -r page_target <&3; then
         if ! IFS= read -r extra <&3 && test "$page_header" = SWIFTHAKCHI_SNES_LIBRARY_PAGE_V1 && test "$page_id" = "$id" && test "$page_tree" = "$tree"; then target=$page_target; fi
        fi
        exec 3<&-
       fi
       # This validates the whole graph and every payload, including the selected page.
       folder=$("$B" sh "$R/library-selector" "$id" "$tree" "$target");;
      *) exit 1;;
     esac
     regular "$N/active-menu"
     value=$("$B" sha256sum "$N/active-menu"); test "${value%% *}" = "$selection_hash"
     printf '%s\n' "$folder"
    elif test -e "$L/active-menu" || test -L "$L/active-menu"; then
     exec "$B" sh "$R/menu-selector"
    else
     printf '%s\n' /usr/share/games
    fi
    """# + "\n"

    static let efficientChangePage = #"""
    #!/bin/sh
    set -eu
    set -o pipefail
    set -f
    umask 077
    R=/mnt/swifthakchi
    B="$R/busybox"
    P=/proc
    N=/var/lib/swifthakchi/snes-v2
    T=/usr/share/applications/clover-mcp.desktop
    # Clover adds launch options to folder commands. Only the page controls navigation.
    test "$#" -ge 1 && test "$#" -le 65
    target=$1; shift
    case "$target" in [0-9][0-9][0-9]) ;; *) exit 1;; esac
    page_number=$((1$target-1000)); test "$page_number" -lt 32
    expected_code=$(printf 'CLV-S-%05d' "$page_number")
    seen=' '; transition_fds=''
    while test "$#" -gt 0; do
      test "$#" -ge 2
      option=$1; value=$2; shift 2
      test "${#value}" -le 4096
      case "$option" in
        --title-code|--video-mode|--save-data-backing-file|--save-screenshot-on-quit|--rollback-output-dir|--rollback-mode|--save-on-quit|--rollback-input-dir|--load-state-file|--replay-inputs|--decorative-frame-path|--load-time-path|--save-time-path|--wait-transition-fd|--start-transition-fd|--finish-transition-fd) ;;
        *) exit 1;;
      esac
      case "$seen" in *" $option "*) exit 1;; esac
      seen="$seen$option "
      case "$option" in
        --title-code) test "$value" = "$expected_code";;
        --wait-transition-fd|--start-transition-fd|--finish-transition-fd)
          case "$value" in ''|*[!0-9]*|0?*) exit 1;; esac
          test "${#value}" -le 3
          test "$value" -ge 3
          test "$value" -le 255
          transition_fds="$transition_fds $value";;
      esac
    done
    test -d "$R" && test ! -L "$R"
    "$B" sha256sum -c "$R/runtime-files.sha256" >/dev/null
    regular() {
      test -f "$1" && test ! -L "$1" || return 1
      test "$("$B" stat -c '%h' "$1")" = 1
      test "$("$B" stat -c '%u' "$1")" = 0
    }
    no_game() { test -z "$("$B" pidof canoe-shvc clover-canoe-shvc kachikachi clover-kachikachi || :)"; }
    process_token() {
      test "$("$B" readlink -f "$P/$1/exe")" = "/usr/bin/$2" || return 1
      "$B" awk -v pid="$1" -v name="$2" '$1==pid && $2=="(" substr(name,1,15) ")" && $4~/^[0-9]+$/ && $22~/^[0-9]+$/ {print $4 ":" $22;n++}END{if(n!=1)exit 1}' "$P/$1/stat"
    }
    framebuffer() (
      set +f
      count=0; found=0
      for descriptor in "$P/$ui"/fd/*; do
        count=$((count+1)); test "$count" -le 64 || return 1
        value=$("$B" readlink -f "$descriptor" 2>/dev/null) || continue
        test "$value" != /dev/fb0 || found=1
      done
      test "$found" = 1
    )
    configured() {
      regular "$T"; regular "$R/mcp-selected"; regular "$R/mcp-template"
      test "$("$B" stat -c '%d:%i' "$T")" = "$("$B" stat -c '%d:%i' "$R/mcp-selected")"
      value=$("$B" awk -v folder="$1" '$0=="GamesFolder = /usr/share/games"{print "GamesFolder = " folder;n++;next}{print}END{if(n!=1)exit 1}' "$R/mcp-template" | "$B" sha256sum)
      actual=$("$B" sha256sum "$T"); test "${value%% *}" = "${actual%% *}"
    }
    selection_matches() {
     regular "$N/active-menu"
     value=$("$B" sha256sum "$N/active-menu"); test "${value%% *}" = "$selection_hash"
    }
    "$B" mkdir -m 0700 "$R/menu-change.lock"
    published=0; stopped=0; prior=0
    pending="$R/library-page.$$.pending"
    previous="$R/library-page.$$.previous"
    cleanup() {
      result=$?; trap - EXIT
      if test "$result" != 0 && test "$published" = 1 && test "$stopped" = 0; then
        if regular "$R/library-page"; then
          value=$("$B" sha256sum "$R/library-page")
          if test "${value%% *}" = "$published_hash"; then
            if test "$prior" = 1; then "$B" mv -f "$previous" "$R/library-page"; else "$B" rm "$R/library-page"; fi
          fi
        fi
      fi
      for file in "$pending" "$previous"; do
        if test -f "$file" && test ! -L "$file"; then "$B" rm "$file"; fi
      done
      "$B" rmdir "$R/menu-change.lock" || :
      exit "$result"
    }
    trap cleanup EXIT
    test ! -e "$pending" && test ! -L "$pending" && test ! -e "$previous" && test ! -L "$previous"
    if test -e "$R/library-page" || test -L "$R/library-page"; then
      regular "$R/library-page"
      test "$("$B" stat -c '%s' "$R/library-page")" -le 256
      "$B" cp "$R/library-page" "$previous"
      regular "$previous"; prior=1
    fi
    regular "$N/active-menu"
    size=$("$B" stat -c '%s' "$N/active-menu"); test "$size" -gt 0 && test "$size" -le 256
    clean=$("$B" tr -cd '\12\40-\176' < "$N/active-menu" | "$B" wc -c | "$B" tr -d '[:space:]'); test "$clean" = "$size"
    value=$("$B" sha256sum "$N/active-menu"); selection_hash=${value%% *}
    exec 3< "$N/active-menu"
    IFS= read -r header <&3; IFS= read -r kind <&3; IFS= read -r id <&3; IFS= read -r tree <&3
    if IFS= read -r extra <&3; then exit 1; fi
    exec 3<&-
    test "$header" = SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1 && test "$kind" = MENU
    folder=$("$B" sh "$R/library-selector" "$id" "$tree" "$target")
    test "$folder" = "$N/menus/$id/pages/$target"
    current=$("$B" awk '/^GamesFolder = /{print substr($0,15);n++}END{if(n!=1)exit 1}' "$T")
    case "$current" in "$N/menus/$id/pages/"[0-9][0-9][0-9]) ;; *) exit 1;; esac
    active_page=${current##*/}
    # The target check above verified every page. Check membership against that same manifest.
    manifest="$N/menus/$id/menu.manifest"
    "$B" awk -v page="$active_page" '$1=="PAGE" && "p" $2=="p" page {n++}END{if(n!=1)exit 1}' "$manifest"
    value=$("$B" sha256sum "$manifest"); test "${value%% *}" = "$tree"
    selection_matches
    configured "$current"
    no_game
    regular "$R/daemon.pid"
    daemon=$("$B" cat "$R/daemon.pid"); case "$daemon" in ''|*[!0-9]*) exit 1;; esac
    test "$daemon" -gt 1
    test "$("$B" readlink -f "$P/$daemon/exe")" = "$R/ld-linux-armhf.so.3"
    mcp=$("$B" pidof clover-mcp); case "$mcp" in ''|*[!0-9]*) exit 1;; esac
    test "$mcp" -gt 1 && test "$mcp" != "$daemon" && test "$mcp" != "$$"
    mcp_token=$(process_token "$mcp" clover-mcp); test "${mcp_token%%:*}" = 1
    ui=$("$B" pidof ReedPlayer-Clover || :)
    if test -n "$ui"; then
      case "$ui" in *[!0-9]*) exit 1;; esac
      test "$ui" -gt 1 && test "$ui" != "$mcp" && test "$ui" != "$daemon"
      ui_token=$(process_token "$ui" ReedPlayer-Clover); test "${ui_token%%:*}" = "$mcp"
      framebuffer
    fi
    (set -C; printf 'SWIFTHAKCHI_SNES_LIBRARY_PAGE_V1\n%s\n%s\n%s\n' "$id" "$tree" "$target" > "$pending")
    regular "$pending"
    value=$("$B" sha256sum "$pending"); published_hash=${value%% *}
    "$B" mv -f "$pending" "$R/library-page"
    regular "$R/library-page"; published=1
    no_game; configured "$current"
    selection_matches
    test "$(process_token "$mcp" clover-mcp)" = "$mcp_token"
    test "$("$B" pidof clover-mcp)" = "$mcp"
    test "$("$B" pidof ReedPlayer-Clover || :)" = "$ui"
    if test -n "$ui"; then test "$(process_token "$ui" ReedPlayer-Clover)" = "$ui_token"; framebuffer; fi
    # Original MCP's TERM handler shuts down the console. Never call it or stock stop.
    "$B" kill -KILL "$mcp"
    stopped=1
    for attempt in 1 2 3 4 5; do
      test -n "$("$B" pidof clover-mcp || :)" || break
      "$B" sleep 1
    done
    test -z "$("$B" pidof clover-mcp || :)"
    if test -n "$ui"; then
      current_ui=$(process_token "$ui" ReedPlayer-Clover)
      test "${current_ui#*:}" = "${ui_token#*:}"
      case "${current_ui%%:*}" in 1|"$mcp") ;; *) exit 1;; esac
      framebuffer
      "$B" kill -TERM "$ui"
      for attempt in 1 2 3 4 5; do
        test -n "$("$B" pidof ReedPlayer-Clover || :)" || break
        "$B" sleep 1
      done
      test -z "$("$B" pidof ReedPlayer-Clover || :)"
    fi
    no_game
    selection_matches
    # Keep the previous launcher's pipes out of the replacement manager.
    (
      for descriptor in $transition_fds; do eval "exec ${descriptor}>&-"; done
      ulimit -f unlimited
      exec "$B" sh -e "$R/menu-wrapper" start
    ) </dev/null >/dev/null 2>&1
    ready=0
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      next=$("$B" pidof clover-mcp || :)
      case "$next" in ''|*[!0-9]*) ;; *) if test "$next" -gt 1 && test "$next" != "$mcp" && test "$next" != "$daemon"; then ready=1; break; fi;; esac
      "$B" sleep 1
    done
    test "$ready" = 1
    checked=$("$B" sh "$R/menu-route"); test "$checked" = "$folder"
    configured "$folder"
    """# + "\n"

    static let changePage = #"""
    #!/bin/sh
    set -eu
    set -o pipefail
    set -f
    umask 077
    R=/mnt/swifthakchi
    B="$R/busybox"
    P=/proc
    N=/var/lib/swifthakchi/snes-v2
    T=/usr/share/applications/clover-mcp.desktop
    # Clover adds launch options to folder commands. Only the page controls navigation.
    test "$#" -ge 1 && test "$#" -le 65
    target=$1; shift
    case "$target" in [0-9][0-9][0-9]) ;; *) exit 1;; esac
    page_number=$((1$target-1000)); test "$page_number" -lt 32
    expected_code=$(printf 'CLV-S-%05d' "$page_number")
    seen=' '; transition_fds=''
    while test "$#" -gt 0; do
      test "$#" -ge 2
      option=$1; value=$2; shift 2
      test "${#value}" -le 4096
      case "$option" in
        --title-code|--video-mode|--save-data-backing-file|--save-screenshot-on-quit|--rollback-output-dir|--rollback-mode|--save-on-quit|--rollback-input-dir|--load-state-file|--replay-inputs|--decorative-frame-path|--load-time-path|--save-time-path|--wait-transition-fd|--start-transition-fd|--finish-transition-fd) ;;
        *) exit 1;;
      esac
      case "$seen" in *" $option "*) exit 1;; esac
      seen="$seen$option "
      case "$option" in
        --title-code) test "$value" = "$expected_code";;
        --wait-transition-fd|--start-transition-fd|--finish-transition-fd)
          case "$value" in ''|*[!0-9]*|0?*) exit 1;; esac
          test "${#value}" -le 3
          test "$value" -ge 3
          test "$value" -le 255
          transition_fds="$transition_fds $value";;
      esac
    done
    test -d "$R" && test ! -L "$R"
    "$B" sha256sum -c "$R/runtime-files.sha256" >/dev/null
    regular() {
      test -f "$1" && test ! -L "$1" || return 1
      test "$("$B" stat -c '%h' "$1")" = 1
      test "$("$B" stat -c '%u' "$1")" = 0
    }
    no_game() { test -z "$("$B" pidof canoe-shvc clover-canoe-shvc kachikachi clover-kachikachi || :)"; }
    process_token() {
      test "$("$B" readlink -f "$P/$1/exe")" = "/usr/bin/$2" || return 1
      "$B" awk -v pid="$1" -v name="$2" '$1==pid && $2=="(" substr(name,1,15) ")" && $4~/^[0-9]+$/ && $22~/^[0-9]+$/ {print $4 ":" $22;n++}END{if(n!=1)exit 1}' "$P/$1/stat"
    }
    framebuffer() (
      set +f
      count=0; found=0
      for descriptor in "$P/$ui"/fd/*; do
        count=$((count+1)); test "$count" -le 64 || return 1
        value=$("$B" readlink -f "$descriptor" 2>/dev/null) || continue
        test "$value" != /dev/fb0 || found=1
      done
      test "$found" = 1
    )
    configured() {
      regular "$T"; regular "$R/mcp-selected"; regular "$R/mcp-template"
      test "$("$B" stat -c '%d:%i' "$T")" = "$("$B" stat -c '%d:%i' "$R/mcp-selected")"
      value=$("$B" awk -v folder="$1" '$0=="GamesFolder = /usr/share/games"{print "GamesFolder = " folder;n++;next}{print}END{if(n!=1)exit 1}' "$R/mcp-template" | "$B" sha256sum)
      actual=$("$B" sha256sum "$T"); test "${value%% *}" = "${actual%% *}"
    }
    selection_matches() {
     regular "$N/active-menu"
     value=$("$B" sha256sum "$N/active-menu"); test "${value%% *}" = "$selection_hash"
    }
    "$B" mkdir -m 0700 "$R/menu-change.lock"
    published=0; stopped=0; prior=0
    pending="$R/library-page.$$.pending"
    previous="$R/library-page.$$.previous"
    cleanup() {
      result=$?; trap - EXIT
      if test "$result" != 0 && test "$published" = 1 && test "$stopped" = 0; then
        if regular "$R/library-page"; then
          value=$("$B" sha256sum "$R/library-page")
          if test "${value%% *}" = "$published_hash"; then
            if test "$prior" = 1; then "$B" mv -f "$previous" "$R/library-page"; else "$B" rm "$R/library-page"; fi
          fi
        fi
      fi
      for file in "$pending" "$previous"; do
        if test -f "$file" && test ! -L "$file"; then "$B" rm "$file"; fi
      done
      "$B" rmdir "$R/menu-change.lock" || :
      exit "$result"
    }
    trap cleanup EXIT
    test ! -e "$pending" && test ! -L "$pending" && test ! -e "$previous" && test ! -L "$previous"
    if test -e "$R/library-page" || test -L "$R/library-page"; then
      regular "$R/library-page"
      test "$("$B" stat -c '%s' "$R/library-page")" -le 256
      "$B" cp "$R/library-page" "$previous"
      regular "$previous"; prior=1
    fi
    regular "$N/active-menu"
    size=$("$B" stat -c '%s' "$N/active-menu"); test "$size" -gt 0 && test "$size" -le 256
    clean=$("$B" tr -cd '\12\40-\176' < "$N/active-menu" | "$B" wc -c | "$B" tr -d '[:space:]'); test "$clean" = "$size"
    value=$("$B" sha256sum "$N/active-menu"); selection_hash=${value%% *}
    exec 3< "$N/active-menu"
    IFS= read -r header <&3; IFS= read -r kind <&3; IFS= read -r id <&3; IFS= read -r tree <&3
    if IFS= read -r extra <&3; then exit 1; fi
    exec 3<&-
    test "$header" = SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1 && test "$kind" = MENU
    folder=$("$B" sh "$R/library-selector" "$id" "$tree" "$target")
    test "$folder" = "$N/menus/$id/pages/$target"
    current=$("$B" awk '/^GamesFolder = /{print substr($0,15);n++}END{if(n!=1)exit 1}' "$T")
    case "$current" in "$N/menus/$id/pages/"[0-9][0-9][0-9]) ;; *) exit 1;; esac
    active_page=${current##*/}
    # The target check above verified every page. Check membership against that same manifest.
    manifest="$N/menus/$id/menu.manifest"
    "$B" awk -v page="$active_page" '$1=="PAGE" && "p" $2=="p" page {n++}END{if(n!=1)exit 1}' "$manifest"
    value=$("$B" sha256sum "$manifest"); test "${value%% *}" = "$tree"
    selection_matches
    configured "$current"
    no_game
    regular "$R/daemon.pid"
    daemon=$("$B" cat "$R/daemon.pid"); case "$daemon" in ''|*[!0-9]*) exit 1;; esac
    test "$daemon" -gt 1
    test "$("$B" readlink -f "$P/$daemon/exe")" = "$R/ld-linux-armhf.so.3"
    mcp=$("$B" pidof clover-mcp); case "$mcp" in ''|*[!0-9]*) exit 1;; esac
    test "$mcp" -gt 1 && test "$mcp" != "$daemon" && test "$mcp" != "$$"
    mcp_token=$(process_token "$mcp" clover-mcp); test "${mcp_token%%:*}" = 1
    ui=$("$B" pidof ReedPlayer-Clover || :)
    if test -n "$ui"; then
      case "$ui" in *[!0-9]*) exit 1;; esac
      test "$ui" -gt 1 && test "$ui" != "$mcp" && test "$ui" != "$daemon"
      ui_token=$(process_token "$ui" ReedPlayer-Clover); test "${ui_token%%:*}" = "$mcp"
      framebuffer
    fi
    (set -C; printf 'SWIFTHAKCHI_SNES_LIBRARY_PAGE_V1\n%s\n%s\n%s\n' "$id" "$tree" "$target" > "$pending")
    regular "$pending"
    value=$("$B" sha256sum "$pending"); published_hash=${value%% *}
    "$B" mv -f "$pending" "$R/library-page"
    regular "$R/library-page"; published=1
    no_game; configured "$current"
    selection_matches
    test "$(process_token "$mcp" clover-mcp)" = "$mcp_token"
    test "$("$B" pidof clover-mcp)" = "$mcp"
    test "$("$B" pidof ReedPlayer-Clover || :)" = "$ui"
    if test -n "$ui"; then test "$(process_token "$ui" ReedPlayer-Clover)" = "$ui_token"; framebuffer; fi
    # Original MCP's TERM handler shuts down the console. Never call it or stock stop.
    "$B" kill -KILL "$mcp"
    stopped=1
    for attempt in 1 2 3 4 5; do
      test -n "$("$B" pidof clover-mcp || :)" || break
      "$B" sleep 1
    done
    test -z "$("$B" pidof clover-mcp || :)"
    if test -n "$ui"; then
      current_ui=$(process_token "$ui" ReedPlayer-Clover)
      test "${current_ui#*:}" = "${ui_token#*:}"
      case "${current_ui%%:*}" in 1|"$mcp") ;; *) exit 1;; esac
      framebuffer
      "$B" kill -TERM "$ui"
      for attempt in 1 2 3 4 5; do
        test -n "$("$B" pidof ReedPlayer-Clover || :)" || break
        "$B" sleep 1
      done
      test -z "$("$B" pidof ReedPlayer-Clover || :)"
    fi
    no_game
    selection_matches
    # Keep the previous launcher's pipes out of the replacement manager.
    (
      for descriptor in $transition_fds; do eval "exec ${descriptor}>&-"; done
      ulimit -f unlimited
      exec "$R/menu-launch"
    ) </dev/null >/dev/null 2>&1
    ready=0
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      next=$("$B" pidof clover-mcp || :)
      case "$next" in ''|*[!0-9]*) ;; *) if test "$next" -gt 1 && test "$next" != "$mcp" && test "$next" != "$daemon"; then ready=1; break; fi;; esac
      "$B" sleep 1
    done
    test "$ready" = 1
    checked=$("$B" sh "$R/menu-route"); test "$checked" = "$folder"
    configured "$folder"
    """# + "\n"
    /// Experimental source only; no startup recipe selects this variant. The
    /// existing installed recipe remains byte-exact for reconstruction. The
    /// future supervisor must actually use this short executable name.
    static func experimentalCompatibilityChangePage() throws -> String {
        let old = #"no_game() { test -z "$("$B" pidof canoe-shvc clover-canoe-shvc kachikachi clover-kachikachi || :)"; }"#
        let new = #"no_game() { test -z "$("$B" pidof canoe-shvc clover-canoe-shvc kachikachi clover-kachikachi retroarch hc-snes-superv || :)"; }"#
        guard changePage.components(separatedBy: old).count == 2 else { throw SNESLibraryMenu.failure() }
        return changePage.replacingOccurrences(of: old, with: new)
    }

}
