import Foundation
import Testing
@testable import SwiftHakchi
@testable import SwiftHakchiCore

private actor LegacyIdentityFixture: LegacyRequestExecuting {
    let output: Data
    let exitCode: Int
    init(_ output: String, exitCode: Int = 0) {
        self.output = Data(output.utf8)
        self.exitCode = exitCode
    }
    func execute(_ request: LegacyReadRequest, timeoutMilliseconds: Int) -> SSHResult {
        guard case .chipID = request else {
            return SSHResult(stdout: "", stderr: "wrong request", stdoutData: Data(), exitCode: 1)
        }
        return SSHResult(stdout: String(decoding: output, as: UTF8.self), stderr: "",
                         stdoutData: output, exitCode: exitCode)
    }
}

private actor LegacyBackupIdentityFixture: LegacyRequestExecuting {
    let underlying = LegacyConsoleFixture()
    let chipID: Data
    init(_ chipID: String) { self.chipID = Data(chipID.utf8) }
    func execute(_ request: LegacyReadRequest, timeoutMilliseconds: Int) async throws -> SSHResult {
        if case .chipID = request {
            return SSHResult(stdout: String(decoding: chipID, as: UTF8.self), stderr: "",
                             stdoutData: chipID, exitCode: 0)
        }
        return await underlying.execute(request, timeoutMilliseconds: timeoutMilliseconds)
    }
}

struct LegacyDeviceIdentityTests {
    private let fixture = "SWIFTHAKCHI_CHIP_ID_V1\n0x01234567\n0x89ABCDEF\n0x00112233\n0x44556677\nEND\n"

    @Test func fourWordsUseTheSameOrderAsFELAndOnlyReadRegisters() async throws {
        let result = try await LegacyDeviceIdentity.read(client: LegacyIdentityFixture(fixture))
        #expect(result == "0123456789abcdef0011223344556677")
        let command = LegacyReadRequest.chipID.command
        #expect(command.contains("/bin/devmem 0x01c23800 32"))
        #expect(command.contains("/bin/devmem 0x01c2380c 32"))
        #expect(!command.contains("burn_"))
        #expect(!command.contains("mount "))
        #expect(!command.contains("mv "))
        #expect(!command.contains("rm "))
    }

    @Test func fingerprintCheckRejectsAnotherConsole() throws {
        let id = try LegacyDeviceIdentity.parse(Data(fixture.utf8))
        #expect(LegacyDeviceIdentity.matches(id,
            fingerprint: BackupManifest.digest(Data(id.utf8))))
        #expect(!LegacyDeviceIdentity.matches("7777777789abcdef0011223344556677",
            fingerprint: BackupManifest.digest(Data(id.utf8))))
        #expect(throws: (any Error).self) { try LegacyDeviceIdentity.requireFirstNES(id) }
    }

    @Test(arguments: [
        "SWIFTHAKCHI_CHIP_ID_V1\n0x01234567\n0x89ABCDEF\n0x00112233\nEND\n",
        "SWIFTHAKCHI_CHIP_ID_V1\n0x01234567\n0x89ABCDEF\n0x00112233\n0x44556677\n0x00000000\nEND\n",
        "SWIFTHAKCHI_CHIP_ID_V1\n0x67452301\n0x89ABCDEF\n0x00112233\n0x44556677\nEND\nEXTRA\n",
        "SWIFTHAKCHI_CHIP_ID_V1\n0x01234567\n0x89ABCDEFG\n0x00112233\n0x44556677\nEND\n"
    ])
    func malformedReadIsRejected(_ output: String) {
        #expect(throws: (any Error).self) { try LegacyDeviceIdentity.parse(Data(output.utf8)) }
    }

    @Test func failedDeviceCommandCannotSupplyAnIdentity() async {
        await #expect(throws: (any Error).self) {
            try await LegacyDeviceIdentity.read(client: LegacyIdentityFixture(fixture, exitCode: 1))
        }
    }

    @Test func diagnosticReportsMatchWithoutPrintingThePrivateID() async throws {
        let id = try LegacyDeviceIdentity.parse(Data(fixture.utf8))
        let output = try await LegacyDeviceIdentityDiagnostic.run(
            client: LegacyIdentityFixture(fixture),
            expectedFingerprint: BackupManifest.digest(Data(id.utf8)))
        #expect(output.contains("\"identityMatched\" : true"))
        #expect(output.contains("\"USBOpened\" : true"))
        #expect(!output.contains(id))
    }

    @Test func diagnosticRejectsMismatchedLiveIdentity() async {
        await #expect(throws: (any Error).self) {
            try await LegacyDeviceIdentityDiagnostic.run(
                client: LegacyIdentityFixture(fixture),
                expectedFingerprint: LegacyBoot2ActivationPlan.supportedHWIDSHA256)
        }
    }

    @Test func freshBackupRequiresIdentityAndReturnsVerifiedArchive() async throws {
        let id = try LegacyDeviceIdentity.parse(Data(fixture.utf8))
        let destination = try testDirectory(); defer { try? FileManager.default.removeItem(at: destination) }
        let output = try await LegacyBackupDiagnostic.run(client: LegacyBackupIdentityFixture(fixture),
            destination: destination, expectedFingerprint: BackupManifest.digest(Data(id.utf8)))
        #expect(output.contains("\"identityMatched\" : true"))
        #expect(output.contains("\"gamesChanged\" : false"))
        #expect(!output.contains(id))
        let children = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
        #expect(children.count == 1)
        try LegacyGameChangeService.verifyBackup(children[0])
    }
}
