import Foundation

/// A passive snapshot of only the menu and game processes. It identifies
/// eventfd numbers and counters; it does not attach to or control processes.
struct SNESNativeProcessSnapshot {
    struct EventFD { let number: Int; let count: String; let semaphore: String; let id: Int? }
    struct Process { let pid: Int; let parent: Int; let name: String; var eventFDs: [EventFD]; var transitions: [String: Int]; var options: Set<String> }
    let processes: [Process]
    private static let names: Set<String> = ["clover-mcp", "canoe-shvc", "clover-canoe-sh", "retroarch", "hc-snes-superv"]
    private static let optionNames: Set<String> = ["save-on-quit", "save-screenshot-on-quit", "rollback-output-dir", "rollback-mode", "rollback-input-dir", "load-state-file", "load-time-path", "save-time-path"]
    enum Invalid: Error { case frame }

    static func parse(_ data: Data, allowAdditionalOptions: Bool = false, allowTemporaryTrial: Bool = false) throws -> Self {
        guard data.count <= 65536, let text = String(data: data, encoding: .utf8) else { throw Invalid.frame }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 3, lines.first == "SNES-PROCESS-V1", lines.last == "", lines[lines.count-2] == "END" else { throw Invalid.frame }
        var processes: [Process] = []
        var index: [Int: Int] = [:]
        for line in lines.dropFirst().dropLast(2) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count >= 3, fields.count <= 6, let pid = Int(fields[1]), pid > 0, pid <= 4_194_304 else { throw Invalid.frame }
            if fields[0] == "PROC" {
                guard fields.count == 4, let parent = Int(fields[2]), parent >= 0, parent <= 4_194_304,
                      (names.contains(String(fields[3])) || (allowTemporaryTrial && ["trial-owner", "trial-menu-owne"].contains(String(fields[3])))),
                      index[pid] == nil, processes.count < 128 else { throw Invalid.frame }
                index[pid] = processes.count
                processes.append(Process(pid: pid, parent: parent, name: String(fields[3]), eventFDs: [], transitions: [:], options: []))
            } else if fields[0] == "FD" {
                guard fields.count == 6, let i = index[pid], let fd = Int(fields[2]), fd >= 0, fd <= 65535,
                      (fields[3] == "-" || (!fields[3].isEmpty && fields[3].count <= 16 && fields[3].allSatisfy({ $0.isHexDigit && $0.isASCII }))),
                      ["0", "1", "-"].contains(String(fields[4])),
                      (fields[5] == "-" || (Int(fields[5]).map { $0 >= 0 && $0 <= 4_194_304 } ?? false)),
                      processes[i].eventFDs.count < 256,
                      !processes[i].eventFDs.contains(where: { $0.number == fd }) else { throw Invalid.frame }
                processes[i].eventFDs.append(EventFD(number: fd, count: String(fields[3]), semaphore: String(fields[4]), id: Int(fields[5])))
            } else if fields[0] == "ARG" {
                guard fields.count == 4, let i = index[pid], ["wait", "start", "finish"].contains(String(fields[2])),
                      let fd = Int(fields[3]), fd >= 0, fd <= 65535, processes[i].transitions[String(fields[2])] == nil else { throw Invalid.frame }
                processes[i].transitions[String(fields[2])] = fd
            } else if fields[0] == "OPT" {
                guard fields.count == 3, let i = index[pid],
                      optionNames.contains(String(fields[2])) || (allowAdditionalOptions && isOptionName(fields[2])),
                      processes[i].options.count < 64,
                      processes[i].options.insert(String(fields[2])).inserted else { throw Invalid.frame }
            } else { throw Invalid.frame }
        }
        return Self(processes: processes)
    }
    private static func isOptionName(_ name: Substring) -> Bool {
        let bytes = name.utf8
        guard !bytes.isEmpty, bytes.count <= 64, let first = bytes.first, (97...122).contains(first) else { return false }
        return bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }
    /// Separate, opt-in diagnostic: the original snapshot remains restricted to
    /// the save-related option names it was designed to collect.
    static var commandWithOptionNames: String {
        let marker = #"$0=="--finish-transition-fd" {kind="finish";next}"#
        let extra = #"""
        $0 ~ /^--[a-z][a-z0-9-]*$/ && length($0) <= 66 {if (!seen[$0]++) printf "OPT %s %s\n",pid,substr($0,3);next}
        """#
        // Native option arity has not yet been established. Do not discard the
        // next token just because it follows one of the known option names.
        return command.replacingOccurrences(of: marker, with: marker + "\n" + extra)
            .replacingOccurrences(of: ";skip=1;next}", with: ";next}")
    }
    static var commandForTemporaryTrial: String {
        command.replacingOccurrences(of: "|retroarch|hc-snes-superv)",
                                     with: "|retroarch|trial-owner|trial-menu-owne|hc-snes-superv)")
            .replacingOccurrences(of: "B=/mnt/swifthakchi/busybox", with: "B=/probe/busybox")
    }
    static let command = #"""
    set -eu
    B=/mnt/swifthakchi/busybox
    printf 'SNES-PROCESS-V1\n'
    for p in /proc/[0-9]*; do
      [ -d "$p" ] || continue
      n=$("$B" cat "$p/comm" 2>/dev/null) || continue
      case "$n" in clover-mcp|canoe-shvc|clover-canoe-sh|retroarch|hc-snes-superv) ;; *) continue;; esac
      pid=${p##*/}
      pp=$("$B" awk '$1=="PPid:" {print $2}' "$p/status" 2>/dev/null) || continue
      case "$pid:$pp" in *[!0-9:]*|:*|*:) continue;; esac
      printf 'PROC %s %s %s\n' "$pid" "$pp" "$n"
      "$B" tr '\000' '\n' < "$p/cmdline" 2>/dev/null | "$B" awk -v pid="$pid" '
        skip {skip=0;next}
        kind!="" {if ($0 ~ /^[0-9]+$/) printf "ARG %s %s %s\n",pid,kind,$0;kind="";next}
        $0 ~ /^--(save-on-quit|save-screenshot-on-quit|rollback-output-dir|rollback-mode|rollback-input-dir|load-state-file|load-time-path|save-time-path)$/ {printf "OPT %s %s\n",pid,substr($0,3);skip=1;next}
        $0=="--wait-transition-fd" {kind="wait";next}
        $0=="--start-transition-fd" {kind="start";next}
        $0=="--finish-transition-fd" {kind="finish";next}
      ' || :
      for f in "$p"/fd/[0-9]*; do
        [ "$("$B" readlink "$f" 2>/dev/null || :)" = 'anon_inode:[eventfd]' ] || continue
        fd=${f##*/}; info="$p/fdinfo/$fd"
        count=$("$B" awk '$1=="eventfd-count:" {print $2}' "$info" 2>/dev/null || :)
        sem=$("$B" awk '$1=="eventfd-semaphore:" {print $2}' "$info" 2>/dev/null || :)
        id=$("$B" awk '$1=="eventfd-id:" {print $2}' "$info" 2>/dev/null || :)
        case "$count" in ''|*[!0-9a-fA-F]*) count=-;; esac
        case "$sem" in 0|1) ;; *) sem=-;; esac
        case "$id" in ''|*[!0-9]*) id=-;; esac
        printf 'FD %s %s %s %s %s\n' "$pid" "$fd" "$count" "$sem" "$id"
      done
    done
    printf 'END\n'
    """#
}
