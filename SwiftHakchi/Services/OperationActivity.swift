import Foundation

struct OperationActivity: Sendable {
    struct Entry: Identifiable, Sendable {
        let id = UUID()
        let date: Date
        let message: String
    }
    private(set) var entries: [Entry] = []
    mutating func append(_ message: String, at date: Date = Date()) {
        let safe = Self.safe(message)
        guard entries.last?.message != safe else { return }
        entries.append(Entry(date:date,message:safe))
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
    }
    static func safe(_ message: String) -> String {
        // Redact before truncating, including identifiers at a truncation boundary.
        var text = String(message.prefix(16384))
        for pattern in ["(?i)\\b[0-9a-f]{32}\\b", "(?i)\\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\\b"] {
            text = text.replacingOccurrences(of:pattern,with:"[private identifier]",options:.regularExpression)
        }
        return String(text.unicodeScalars.filter { $0.value >= 32 || $0 == "\n" || $0 == "\t" }.prefix(1024))
    }
    var details: String {
        entries.map { "[\($0.date.formatted(date:.omitted,time:.standard))] \($0.message)" }.joined(separator:"\n")
    }
}

struct TaskProgressReporter: Sendable {
    let receive: @MainActor @Sendable (String, Double?, Bool?) -> Void
    func updateProgress(status: String, fraction: Double, cancellable: Bool? = nil) {
        Task { @MainActor in receive(status,fraction,cancellable) }
    }
    func report(status: String, fraction: Double? = nil, cancellable: Bool? = nil) async {
        await receive(status,fraction,cancellable)
    }
}
