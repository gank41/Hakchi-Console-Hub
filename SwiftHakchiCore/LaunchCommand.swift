import Foundation

/// Handles the simple executable/argument commands used by clover launchers.
/// Deliberately rejects shell programs instead of attempting to rewrite them.
public enum LaunchCommand {
    private struct Token { let value: String; let range: Range<String.Index> }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    public static func replacingROM(in command: String, oldPath: String, newPath: String) throws -> String {
        guard !oldPath.isEmpty, newPath.hasPrefix("/"),
              !newPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SyncPlanError.unsafeCommand
        }
        let tokens = try tokenize(command)
        guard let executable = tokens.first?.value, executable.hasPrefix("/bin/"), tokens.count > 1 else {
            throw SyncPlanError.unsafeCommand
        }
        let matches = tokens.dropFirst().filter { $0.value == oldPath }
        guard matches.count == 1, let match = matches.first else { throw SyncPlanError.unsafeCommand }
        var result = command
        result.replaceSubrange(match.range, with: shellQuote(newPath))
        return result
    }

    public static func romPath(in command: String, filename: String) throws -> String {
        let candidates = try arguments(in: command).dropFirst().filter { ($0 as NSString).lastPathComponent == filename }
        guard candidates.count == 1, let path = candidates.first, path.hasPrefix("/") else { throw SyncPlanError.unsafeCommand }
        _ = try replacingROM(in: command, oldPath: path, newPath: path)
        return path
    }

    public static func arguments(in command: String) throws -> [String] { try tokenize(command).map(\.value) }

    private static func tokenize(_ command: String) throws -> [Token] {
        var result: [Token] = []
        var index = command.startIndex
        while index < command.endIndex {
            while index < command.endIndex, command[index] == " " || command[index] == "\t" { index = command.index(after: index) }
            if index == command.endIndex { break }
            let start = index
            var value = ""
            var quote: Character?
            while index < command.endIndex {
                let c = command[index]
                if c.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && c != "\t" }) { throw SyncPlanError.unsafeCommand }
                if quote == nil, c == " " || c == "\t" { break }
                if c == "'" || c == "\"" {
                    if quote == nil { quote = c }
                    else if quote == c { quote = nil }
                    else { value.append(c) }
                } else if c == "\\", quote != "'" {
                    index = command.index(after: index)
                    guard index < command.endIndex else { throw SyncPlanError.unsafeCommand }
                    value.append(command[index])
                } else {
                    if quote != "'", "$`;|&<>\n\r()".contains(c) { throw SyncPlanError.unsafeCommand }
                    value.append(c)
                }
                index = command.index(after: index)
            }
            guard quote == nil else { throw SyncPlanError.unsafeCommand }
            result.append(Token(value: value, range: start..<index))
        }
        return result
    }
}
