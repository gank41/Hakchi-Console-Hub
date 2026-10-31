import Foundation

protocol SNESOneGameStageReadIO:SNESInstalledStartupIO {
    func preflight(_ material:SNESOneGameMaterial,challenge:UUID) async throws->Data
    func inspect(_ material:SNESOneGameMaterial,challenge:UUID) async throws->Data
    func verify(_ material:SNESOneGameMaterial,challenge:UUID) async throws->Data
}
protocol SNESOneGameStageIO:SNESOneGameStageReadIO {
    func copy(_ material:SNESOneGameMaterial,permit:SNESOneGameCopyPermit) async throws->Data
}

/// A single inactive upload. This actor has no menu-selector or firmware writer.
actor SNESOneGameStage {
    private var busy=false
    private struct Connection {
        let device:RecoveryProbeUSBDevice,before:SNESStartupTrialReport
    }
    private func attachment(_ material:SNESOneGameMaterial,_ io:any SNESOneGameStageReadIO,_ device:RecoveryProbeUSBDevice) async throws {
        try material.validate()
        guard try await io.inventory()==[device] else {throw SNESOneGameMenu.failure()}
        try material.validate()
    }
    private func begin(_ material:SNESOneGameMaterial,_ io:any SNESOneGameStageReadIO) async throws->Connection {
        try material.validate()
        let devices=try await io.inventory();try material.validate()
        guard devices.count==1,let device=devices.first else {throw SNESOneGameMenu.failure()}
        _=try SNESStartupTrialUSBPolicy.nativeIdentity(device)
        let expected=try SNESStartupTrialExpectation.checked(material.accepted.material.trial)
        guard device.deviceVersion==expected.deviceVersion else {throw SNESOneGameMenu.failure()}
        try await io.connect(expected:device);try material.validate()
        try await attachment(material,io,device)
        let challenge=UUID(),raw=try await io.report(challenge:challenge);try material.validate()
        let report=try SNESStartupTrialReport(raw,expected:expected,challenge:challenge)
        try await attachment(material,io,device)
        return Connection(device:device,before:report)
    }
    private func finish(_ material:SNESOneGameMaterial,_ io:any SNESOneGameStageReadIO,_ connection:Connection) async throws {
        try await attachment(material,io,connection.device)
        let challenge=UUID(),raw=try await io.report(challenge:challenge);try material.validate()
        let report=try SNESStartupTrialReport(raw,expected:SNESStartupTrialExpectation.checked(material.accepted.material.trial),challenge:challenge)
        guard report.mcpPID==connection.before.mcpPID,report.daemonPID==connection.before.daemonPID else {throw SNESOneGameMenu.failure()}
        try await attachment(material,io,connection.device)
    }
    func preflight(material:SNESOneGameMaterial,io:any SNESOneGameStageReadIO) async throws->SNESOneGameStageReceipt {
        guard !busy else {throw LegacyInspectionError.busy};busy=true;defer{busy=false}
        var closed=false
        do {
            let connection=try await begin(material,io),challenge=UUID()
            let raw=try await io.preflight(material,challenge:challenge);try material.validate()
            let receipt=try SNESOneGameStageReceipt(raw,menu:material.menu,binding:material.accepted.material.trial.candidate.material.binding,challenge:challenge,preflight:true)
            try await finish(material,io,connection)
            closed=true;await io.disconnect();try material.validate()
            return receipt
        } catch {
            if !closed {closed=true;await io.disconnect()}
            throw error
        }
    }
    func inspect(material:SNESOneGameMaterial,io:any SNESOneGameStageReadIO) async throws->SNESOneGameInspectionReceipt {
        guard !busy else {throw LegacyInspectionError.busy};busy=true;defer{busy=false}
        var closed=false
        do {
            let connection=try await begin(material,io),challenge=UUID()
            let raw=try await io.inspect(material,challenge:challenge);try material.validate()
            let result=try SNESOneGameInspectionReceipt(raw,menu:material.menu,binding:material.accepted.material.trial.candidate.material.binding,challenge:challenge)
            try await finish(material,io,connection)
            closed=true;await io.disconnect();try material.validate();return result
        } catch {if !closed {closed=true;await io.disconnect()};throw error}
    }
    func copy(material:SNESOneGameMaterial,journal:SNESOneGameStageJournal,io:any SNESOneGameStageIO) async throws->SNESOneGameStageReceipt {
        guard !busy else {throw LegacyInspectionError.busy};busy=true;defer{busy=false}
        var closed=false,intent=false
        do {
            guard try await journal.phase() == .prepared else {throw SNESOneGameMenu.failure()}
            let connection=try await begin(material,io),challenge=UUID()
            let raw=try await io.preflight(material,challenge:challenge);try material.validate()
            let ready=try SNESOneGameStageReceipt(raw,menu:material.menu,binding:material.accepted.material.trial.candidate.material.binding,challenge:challenge,preflight:true)
            guard ready.freeBytes>=material.requiredFreeBytes else {throw SNESOneGameMenu.failure()}
            try await attachment(material,io,connection.device)
            let permit=try await journal.beginCopy();intent=true;try permit.require(material)
            try await attachment(material,io,connection.device)
            let copied=try await io.copy(material,permit:permit);try material.validate()
            _=try SNESOneGameStageReceipt(copied,menu:material.menu,binding:material.accepted.material.trial.candidate.material.binding,challenge:permit.challenge,preflight:false)
            try await attachment(material,io,connection.device)
            let verificationChallenge=UUID()
            guard verificationChallenge != permit.challenge else {throw SNESOneGameMenu.failure()}
            let verified=try await io.verify(material,challenge:verificationChallenge);try material.validate()
            let receipt=try SNESOneGameStageReceipt(verified,menu:material.menu,binding:material.accepted.material.trial.candidate.material.binding,challenge:verificationChallenge,preflight:false)
            try await finish(material,io,connection)
            closed=true;await io.disconnect();try material.validate()
            try await journal.verified(receipt:receipt)
            return receipt
        } catch {
            if intent {try? await journal.uncertain()}
            if !closed {closed=true;await io.disconnect()}
            throw error
        }
    }
}
