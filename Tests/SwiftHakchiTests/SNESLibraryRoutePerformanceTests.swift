import Foundation
import Testing
@testable import SwiftHakchi

struct SNESLibraryRoutePerformanceTests {
    @Test(arguments: ["root", "page", "stale-page", "bad-marker", "linked-marker", "selector-race", "linked-selector", "builtin"])
    func routingValidatesTheWholeLibraryOnceAndBindsTheSelection(_ kind: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("runtime"), namespace = root.appendingPathComponent("snes-v2")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true)
        let id = UUID().uuidString, digest = String(repeating: "a", count: 64)
        func put(_ url: URL, _ text: String, executable: Bool = false) throws {
            try Data(text.utf8).write(to: url)
            if executable { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
        }
        let selection = namespace.appendingPathComponent("active-menu"), marker = runtime.appendingPathComponent("library-page")
        try put(selection, kind == "builtin" ? "SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1\nBUILTIN\n" : "SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1\nMENU\n\(id)\n\(digest)\n")
        let linked = root.appendingPathComponent("linked")
        if kind == "linked-selector" {
            try FileManager.default.moveItem(at: selection, to: linked)
            try FileManager.default.createSymbolicLink(at: selection, withDestinationURL: linked)
        }
        if kind != "root" {
            let tree = kind == "stale-page" ? String(repeating: "b", count: 64) : digest
            try put(marker, "\(kind == "bad-marker" ? "WRONG" : "SWIFTHAKCHI_SNES_LIBRARY_PAGE_V1")\n\(id)\n\(tree)\n001\n")
            if kind == "linked-marker" {
                try FileManager.default.moveItem(at: marker, to: linked)
                try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: linked)
            }
        }
        let bb = """
        #!/bin/sh
        case "$1" in
          stat) case "$3" in '%h') exec /usr/bin/stat -f '%l' "$4";; '%u') echo 0;; '%s') exec /usr/bin/stat -f '%z' "$4";; *) exit 97;; esac;;
          *) exec "$@";;
        esac
        """
        try put(runtime.appendingPathComponent("busybox"), bb, executable: true)
        let verifier = """
        #!/bin/sh
        set -eu
        printf 'validation\\n' >> '\(root.path)/calls'
        if test '\(kind)' = selector-race; then printf 'extra\\n' >> '\(selection.path)'; fi
        if test "$#" = 0; then
          if test '\(kind)' = builtin; then printf '/usr/share/games\\n'; else printf '\(namespace.path)/menus/\(id)/pages/000\\n'; fi
        else
          test "$#" = 3 && test "$1" = '\(id)' && test "$2" = '\(digest)'
          case "$3" in 000|001) ;; *) exit 1;; esac
          printf '\(namespace.path)/menus/\(id)/pages/%s\\n' "$3"
        fi
        """
        try put(runtime.appendingPathComponent("library-selector"), verifier)
        let source = SNESLibraryStartupScripts.route
            .replacingOccurrences(of: "/mnt/swifthakchi", with: runtime.path)
            .replacingOccurrences(of: "/var/lib/swifthakchi/snes-v2", with: namespace.path)
        let script = root.appendingPathComponent("route.sh"); try put(script, source)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [script.path]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        if ["selector-race", "linked-selector"].contains(kind) {
            #expect(process.terminationStatus != 0); #expect(data.isEmpty)
        } else {
            #expect(process.terminationStatus == 0)
            let expected = kind == "builtin" ? "/usr/share/games" : namespace.path + "/menus/" + id + "/pages/" + (kind == "page" ? "001" : "000")
            #expect(String(decoding: data, as: UTF8.self) == expected + "\n")
            let calls = try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)
            #expect(calls == "validation\n")
        }
    }
}
