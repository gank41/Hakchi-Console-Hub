import Foundation

/// Narrow injectable boundary for recovery failure-order tests; the production actor implements it.
protocol FELBooting: Sendable {
    func memboot(fes1Data: Data, ubootData: Data, bootImgData: Data,
                 progress: (@Sendable (String, Double) -> Void)?) async throws
}

extension FELBooting {
    func memboot(fes1Data: Data, ubootData: Data, bootImgData: Data) async throws {
        try await memboot(fes1Data: fes1Data, ubootData: ubootData, bootImgData: bootImgData, progress: nil)
    }
}
