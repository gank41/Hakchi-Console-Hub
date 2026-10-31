import Foundation

enum LegacyChangeError: Error, LocalizedError {
    case refused(String)
    var errorDescription: String? { if case .refused(let reason) = self { return reason }; return nil }
}

struct LegacyGameTarget: Codable, Equatable, Sendable {
    let code: String
    let page: String
    let sha256: String
    let bytes: Int64
    init(code: String, page: String, sha256: String, bytes: Int64) throws {
        guard code.range(of: #"^CLV-H-[A-Z0-9]{5}$"#, options: .regularExpression) != nil,
              page.range(of: #"^[0-9]{3}$"#, options: .regularExpression) != nil,
              sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              bytes > 0, bytes <= 64 * 1024 * 1024 else { throw LegacyChangeError.refused("Unsupported custom game target.") }
        self.code = code; self.page = page; self.sha256 = sha256; self.bytes = bytes
    }
    func validated() throws -> Self { try Self(code: code, page: page, sha256: sha256, bytes: bytes) }
}

struct LegacyChangePlan: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let target: LegacyGameTarget
    let report: LegacyConsoleReport
    let backup: URL
    let recovery: URL
    let createdAt: Date
}

struct LegacyChangeRecord: Codable, Identifiable, Sendable {
    enum Phase: String, Codable, Sendable { case pending, applied, restored, unchanged }
    var id: UUID { plan.id }
    let plan: LegacyChangePlan
    var phase: Phase
}

/// A capability tied to one challenge-verified client session. A released or disconnected
/// lease never authorizes another request, even when the same client reconnects.
struct LegacySessionLease: LegacyRequestExecuting, Sendable {
    fileprivate let client: LegacyInspectionClient
    fileprivate let id: UUID
    func execute(_ request: LegacyReadRequest, timeoutMilliseconds: Int) async throws -> SSHResult {
        try await client.executeLeased(request, lease: id, timeoutMilliseconds: timeoutMilliseconds)
    }
    func release() async { await client.releaseLease(id) }
    func perform(_ request: LegacyChangeRequest) async throws -> SSHResult { try await client.performChange(request, lease: id) }
    func uploadFile(_ file: URL, operationID: UUID, expectedSHA256: String,
                    expectedBytes: Int64, timeoutMilliseconds: Int = 300_000,
                    progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> SSHResult {
        try await client.uploadLeasedFile(file, operationID: operationID, expectedSHA256: expectedSHA256,
                                          expectedBytes: expectedBytes, lease: id, timeoutMilliseconds: timeoutMilliseconds,
                                          progress: progress)
    }
    init(client: LegacyInspectionClient, id: UUID) { self.client = client; self.id = id }
}
