import Foundation
import SwiftHakchiCore
import Darwin

struct SNESCompatibilityInputObservation:Sendable {
    let raw:Data
    let challenge:UUID
    let context:String
    let hwid:String
    let attachment:RecoveryProbeUSBDevice
    let reports:[Data]
    let reportChallenges:[UUID]
}
enum SNESCompatibilityInputDiagnostic {
    private static func collectNative(_ device:RecoveryProbeUSBDevice,_ workspace:WorkspacePaths) async throws->SNESCompatibilityInputObservation {
        let connection=try await NativeSNESLibraryIO.connect(attachment:device,sessionID:UUID(),workspace:workspace,
            progress:{FileHandle.standardError.write(Data(($0.title+"\n").utf8))})
        do {
            let result=try await connection.session.captureResetInput()
            try connection.context.requireCurrent(attachment:device,sessionID:connection.context.sessionID)
            await connection.session.disconnect()
            return .init(raw:result.frame.raw,challenge:result.challenge,context:connection.context.sha256,
                hwid:connection.context.installation.expected.hwid,attachment:device,reports:result.reports,reportChallenges:result.reportChallenges)
        } catch {await connection.session.disconnect();throw error}
    }
    static func runIfPresent(_ args:[String],
        checkHost:@Sendable () async throws->Void={try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed()},
        inventory:@Sendable () async throws->[RecoveryProbeUSBDevice]={try RecoveryProbeUSBRegistry.inventory()},
        collect:@Sendable (RecoveryProbeUSBDevice,WorkspacePaths) async throws->SNESCompatibilityInputObservation=collectNative) async throws->String? {
        guard args.first=="--capture-native-snes-reset-input" else {return nil}
        func path(_ s:String)->Bool{s.hasPrefix("/") && !s.contains("\0") && s.utf8.count<=4096 && URL(fileURLWithPath:s).standardizedFileURL.path==s}
        guard args.count==3,path(args[1]),path(args[2]) else {throw SNESCompatibilitySupportFrame.failure()}
        let workspace=try RestoreDirectory(URL(fileURLWithPath:args[1])),output=try RestoreDirectory(URL(fileURLWithPath:args[2]))
        try Task.checkCancellation();try await checkHost()
        let devices=try await inventory()
        guard devices.count==1,let device=devices.first,ConsoleAttachmentPolicy.kind(of:device) == .nativeSNES else {throw SNESCompatibilitySupportFrame.failure()}
        let value=try await collect(device,WorkspacePaths(root:workspace.url))
        try Task.checkCancellation();try workspace.check();try output.check()
        guard value.attachment==device,value.reports.count==2,value.reportChallenges.count==2,Set(value.reportChallenges).count==2,
              value.reports.allSatisfy({!$0.isEmpty && $0.count<=16384}) else {throw SNESCompatibilitySupportFrame.failure()}
        let frame=try SNESCompatibilityInputFrame(value.raw,challenge:value.challenge,context:value.context,hwid:value.hwid)
        let leaf="SNES-Reset-Input-"+UUID().uuidString
        guard mkdirat(output.fd,leaf,0o700)==0 else {throw RestoreDirectory.failure()}
        let directory=try RestoreDirectory(output.url.appendingPathComponent(leaf))
        func write(_ name:String,_ bytes:Data)throws {
            try directory.check()
            let fd=openat(directory.fd,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
            guard fd>=0 else {throw RestoreDirectory.failure()}
            let file=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
            do {try file.write(contentsOf:bytes);try file.synchronize();try file.close()}
            catch {try? file.close();throw error}
        }
        try write("input.frame",value.raw)
        for (i,bytes) in value.reports.enumerated(){try write("startup-\(i).frame",bytes)}
        var manifest:[String:Any]=["version":1,"scope":"read-only-snes-reset-button","complete":true,
            "challenge":value.challenge.uuidString,"contextSHA256":value.context,"hwid":value.hwid,
            "attachment":["registryID":device.registryEntryID ?? 0,"locationID":device.locationID,"version":device.deviceVersion],
            "frameSHA256":BackupManifest.digest(value.raw),"device":frame.device,
            "startupChallenges":value.reportChallenges.map(\.uuidString),"startupSHA256":value.reports.map(BackupManifest.digest),
            "consoleFilesWritten":false,"firmwareWritten":false,"connectionClosed":true,"runtimeEligibility":false]
        if let key=frame.resetKey {manifest["resetKey"]=Int(key)}
        try write("manifest.json",JSONSerialization.data(withJSONObject:manifest,options:[.sortedKeys,.prettyPrinted]))
        guard fsync(directory.fd)==0,fsync(output.fd)==0 else {throw RestoreDirectory.failure()}
        return String(decoding:try JSONSerialization.data(withJSONObject:["directory":directory.url.path,"complete":true,
            "consoleFilesWritten":false,"connectionClosed":true],options:[.sortedKeys,.prettyPrinted]),as:UTF8.self)
    }
}

struct SNESPowerInputObservation:Sendable {
    let raw:Data,challenge:UUID,context:String,hwid:String,attachment:RecoveryProbeUSBDevice,report:Data,reportChallenge:UUID
}
enum SNESPowerInputDiagnostic {
    private static func collectNative(_ device:RecoveryProbeUSBDevice,_ workspace:WorkspacePaths) async throws->SNESPowerInputObservation {
        let connection=try await NativeSNESLibraryIO.connect(attachment:device,sessionID:UUID(),workspace:workspace,readOnlyOwnerIndex:true,
            progress:{FileHandle.standardError.write(Data(($0.title+"\n").utf8))})
        do {
            let result=try await connection.session.capturePowerInput()
            try connection.context.requireCurrent(attachment:device,sessionID:connection.context.sessionID)
            await connection.session.disconnect()
            return .init(raw:result.frame.raw,challenge:result.challenge,context:connection.context.sha256,
                hwid:connection.context.installation.expected.hwid,attachment:device,report:result.report,reportChallenge:result.reportChallenge)
        } catch {await connection.session.disconnect();throw error}
    }
    static func runIfPresent(_ args:[String],
        checkHost:@Sendable () async throws->Void={try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed()},
        inventory:@Sendable () async throws->[RecoveryProbeUSBDevice]={try RecoveryProbeUSBRegistry.inventory()},
        collect:@Sendable (RecoveryProbeUSBDevice,WorkspacePaths) async throws->SNESPowerInputObservation=collectNative) async throws->String? {
        guard args.first=="--capture-native-snes-power-input" else {return nil}
        func path(_ s:String)->Bool{s.hasPrefix("/") && !s.contains("\0") && s.utf8.count<=4096 && URL(fileURLWithPath:s).standardizedFileURL.path==s}
        guard args.count==3,path(args[1]),path(args[2]) else {throw SNESCompatibilitySupportFrame.failure()}
        let workspace=try RestoreDirectory(URL(fileURLWithPath:args[1])),output=try RestoreDirectory(URL(fileURLWithPath:args[2]))
        try Task.checkCancellation();try await checkHost()
        let devices=try await inventory()
        guard devices.count==1,let device=devices.first,ConsoleAttachmentPolicy.kind(of:device) == .nativeSNES else {throw SNESCompatibilitySupportFrame.failure()}
        let value=try await collect(device,WorkspacePaths(root:workspace.url))
        try Task.checkCancellation();try workspace.check();try output.check()
        guard value.attachment==device,!value.report.isEmpty,value.report.count<=16384 else {throw SNESCompatibilitySupportFrame.failure()}
        let frame=try SNESPowerInputFrame(value.raw,challenge:value.challenge,context:value.context,hwid:value.hwid)
        let leaf="SNES-Power-Input-"+UUID().uuidString
        guard mkdirat(output.fd,leaf,0o700)==0 else {throw RestoreDirectory.failure()}
        let directory=try RestoreDirectory(output.url.appendingPathComponent(leaf))
        func write(_ name:String,_ bytes:Data)throws {
            try directory.check()
            let fd=openat(directory.fd,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
            guard fd>=0 else {throw RestoreDirectory.failure()}
            let file=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
            do {try file.write(contentsOf:bytes);try file.synchronize();try file.close()}
            catch {try? file.close();throw error}
        }
        try write("input.frame",value.raw);try write("startup.frame",value.report)
        let manifest:[String:Any]=["version":1,"scope":"read-only-snes-power-button","complete":true,
            "challenge":value.challenge.uuidString,"contextSHA256":value.context,"hwid":value.hwid,
            "attachment":["registryID":device.registryEntryID ?? 0,"locationID":device.locationID,"version":device.deviceVersion],
            "frameSHA256":BackupManifest.digest(value.raw),"device":frame.device,"eventType":Int(frame.eventType),
            "eventCode":Int(frame.eventCode),"eventValue":Int(frame.eventValue),"startupChallenge":value.reportChallenge.uuidString,
            "startupSHA256":BackupManifest.digest(value.report),"consoleFilesWritten":false,"firmwareWritten":false,
            "connectionClosed":true,"runtimeEligibility":false]
        try write("manifest.json",JSONSerialization.data(withJSONObject:manifest,options:[.sortedKeys,.prettyPrinted]))
        guard fsync(directory.fd)==0,fsync(output.fd)==0 else {throw RestoreDirectory.failure()}
        return String(decoding:try JSONSerialization.data(withJSONObject:["directory":directory.url.path,"complete":true,
            "consoleFilesWritten":false,"connectionClosed":true],options:[.sortedKeys,.prettyPrinted]),as:UTF8.self)
    }
}
