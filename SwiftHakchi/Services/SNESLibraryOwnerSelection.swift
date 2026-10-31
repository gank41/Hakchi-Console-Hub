import Foundation

/// Resolves a matching accepted installation. Cached references remain hints, never device authority.
enum SNESLibraryOwnerSelection {
    static func choose<Owner: Sendable>(cached: SNESLibraryInstallationReference?, deviceVersion: UInt16,
        resolve: @Sendable (SNESLibraryInstallationReference) async throws -> (Owner, UInt16),
        discover: @Sendable () async throws -> SNESLibraryInstallationReference?) async throws -> (reference: SNESLibraryInstallationReference, owner: Owner) {
        try Task.checkCancellation()
        guard [0x6a04, 0x6a05, 0x6a06, 0x6a07, 0x6a08, 0x6a09, 0x6a0a, 0x6a0b].contains(deviceVersion) else { throw SNESLibraryInstallation.failure() }
        if let cached {
            try cached.validate()
            // A damaged source is an error, not a reason to silently substitute another record.
            let (owner, version) = try await resolve(cached); try Task.checkCancellation()
            if version == deviceVersion { return (cached, owner) }
        }
        guard let next = try await discover() else { throw SNESLibraryInstallation.failure() }
        try Task.checkCancellation(); try next.validate()
        guard cached == nil || cached?.hwid == next.hwid else { throw SNESLibraryInstallation.failure() }
        let (owner, version) = try await resolve(next); try Task.checkCancellation()
        guard version == deviceVersion else { throw SNESLibraryInstallation.failure() }
        return (next, owner)
    }
}
