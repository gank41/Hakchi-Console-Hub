import Foundation
import SwiftHakchiCore

/// Exact upstream inputs for the offline startup builder. Fetching these files
/// does not open a console connection or authorize booting or writing firmware.
struct SNESStartupToolInputs: Sendable {
    let busybox: Data
    let daemonHmod: Data
    typealias Fetch = @Sendable (URL, Int) async throws -> Data

    private static let revision = "d1ca2d6f155099b240fe75a60425bdb461c8c5a6"
    private static let busyboxSize = 1_427_376
    private static let daemonSize = 9_890
    private static let busyboxDigest = "440b72b46c50939356768f35ea02b682176ca49ef07b3702ee75912af74aabd6"
    private static let daemonDigest = "04029161cb7e14b625de3f16edf5485d72e3cc80f9936c38b5a98d7414f4e0fd"

    static func acquire(fetch: @escaping Fetch = { url, size in try await fetchHTTP(url, size) }) async throws -> Self {
        try Task.checkCancellation()
        let root = "https://raw.githubusercontent.com/ClusterM/hakchi2/\(revision)/mods/"
        guard let daemonURL = URL(string: root + "hmods/clovershell.hmod"),
              let busyboxURL = URL(string: root + "mod_hakchi/bin/busybox") else { throw failure() }
        let daemon = try await fetch(daemonURL, daemonSize)
        guard daemon.count == daemonSize, BackupManifest.digest(daemon) == daemonDigest else { throw failure() }
        try Task.checkCancellation()
        let busybox = try await fetch(busyboxURL, busyboxSize)
        guard busybox.count == busyboxSize, BackupManifest.digest(busybox) == busyboxDigest else { throw failure() }
        try Task.checkCancellation()
        return Self(busybox: busybox, daemonHmod: daemon)
    }

    private static func fetchHTTP(_ url: URL, _ exactSize: Int) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 120
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url == url,
              response.expectedContentLength < 0 || response.expectedContentLength == Int64(exactSize) else { throw failure() }
        var result = Data(); result.reserveCapacity(exactSize)
        for try await byte in bytes {
            guard result.count < exactSize else { throw failure() }
            result.append(byte)
            if result.count.isMultiple(of: 4096) { try Task.checkCancellation() }
        }
        guard result.count == exactSize else { throw failure() }
        return result
    }

    private static func failure() -> RecoveryProbeError {
        .refused("The required startup tools could not be verified. Check your internet connection and try again. Nothing was sent to the console.")
    }
}
