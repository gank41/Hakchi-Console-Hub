import Foundation

/// Fixed staging boundaries shared by the native RAM uploader and its fault fixtures.
/// No step is run after source validation fails, including the initial observation.
struct SNESStartupRAMStaging {
    typealias Step = @Sendable () async throws -> Void
    static func run(validate:@Sendable ()throws->Void,observe:@escaping Step,create:@escaping Step,uploadImage:@escaping Step,uploadStock:@escaping Step,verify:@escaping Step) async throws {
        for step in [observe,create,uploadImage,uploadStock,verify,observe] {
            try validate();try await step();try validate()
        }
    }
}
