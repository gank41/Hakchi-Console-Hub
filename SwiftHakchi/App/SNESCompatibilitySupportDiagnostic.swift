import Foundation
import SwiftHakchiCore
import Darwin

struct SNESCompatibilitySupportObservation:Sendable {
    let capture:SNESCompatibilitySupportCapture
    let context:String
    let hwid:String
    let attachment:RecoveryProbeUSBDevice
    let reports:[Data]
    let reportChallenges:[UUID]
}

/// Developer-only, normal-boot reader. It has no console write or install mode.
enum SNESCompatibilitySupportDiagnostic {
    private static func collectNative(_ device:RecoveryProbeUSBDevice,_ workspace:WorkspacePaths) async throws->SNESCompatibilitySupportObservation {
        let connection=try await NativeSNESLibraryIO.connect(attachment:device,sessionID:UUID(),workspace:workspace,
            progress:{FileHandle.standardError.write(Data(($0.title+"\n").utf8))})
        do {
            FileHandle.standardError.write(Data("Reading original libraries and passive device details twice…\n".utf8))
            let result=try await connection.session.captureCompatibilitySupport()
            try connection.context.requireCurrent(attachment:device,sessionID:connection.context.sessionID)
            await connection.session.disconnect()
            return .init(capture:result.capture,context:connection.context.sha256,hwid:connection.context.installation.expected.hwid,
                attachment:device,reports:result.reports,reportChallenges:result.reportChallenges)
        } catch {await connection.session.disconnect();throw error}
    }
    static func runIfPresent(_ args:[String],
        checkHost:@Sendable () async throws->Void={try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed()},
        inventory:@Sendable () async throws->[RecoveryProbeUSBDevice]={try RecoveryProbeUSBRegistry.inventory()},
        collect:@Sendable (RecoveryProbeUSBDevice,WorkspacePaths) async throws->SNESCompatibilitySupportObservation=collectNative) async throws->String? {
        guard args.first=="--capture-native-snes-support" else {return nil}
        func path(_ text:String)->Bool {
            text.hasPrefix("/") && !text.contains("\0") && text.utf8.count<=4096 && URL(fileURLWithPath:text).standardizedFileURL.path==text
        }
        guard args.count==3,path(args[1]),path(args[2]) else {throw SNESCompatibilitySupportFrame.failure()}
        let workspaceRoot=try RestoreDirectory(URL(fileURLWithPath:args[1]))
        let outputRoot=try RestoreDirectory(URL(fileURLWithPath:args[2]))
        try Task.checkCancellation();try await checkHost()
        let devices=try await inventory()
        guard devices.count==1,let device=devices.first,ConsoleAttachmentPolicy.kind(of:device) == .nativeSNES else {throw SNESCompatibilitySupportFrame.failure()}
        let value=try await collect(device,WorkspacePaths(root:workspaceRoot.url))
        try Task.checkCancellation();try workspaceRoot.check();try outputRoot.check()
        guard value.attachment==device,value.capture.frames.count==2,value.capture.challenges.count==2,
              Set(value.capture.challenges).count==2,value.reports.count==2,value.reportChallenges.count==2,
              Set(value.reportChallenges).count==2,value.reports.allSatisfy({!$0.isEmpty && $0.count<=16384}) else {throw SNESCompatibilitySupportFrame.failure()}
        let first=try SNESCompatibilitySupportFrame(value.capture.frames[0],challenge:value.capture.challenges[0],context:value.context,hwid:value.hwid)
        let second=try SNESCompatibilitySupportFrame(value.capture.frames[1],challenge:value.capture.challenges[1],context:value.context,hwid:value.hwid)
        guard first.raw==value.capture.frame.raw,first.libraries==second.libraries,first.chains==second.chains,
              first.metadata==second.metadata else {throw SNESCompatibilitySupportFrame.failure()}
        let leaf="SNES-Compatibility-Support-"+UUID().uuidString
        guard mkdirat(outputRoot.fd,leaf,0o700)==0 else {throw RestoreDirectory.failure()}
        let directory=try RestoreDirectory(outputRoot.url.appendingPathComponent(leaf))
        func write(_ name:String,_ data:Data)throws {
            try directory.check()
            let fd=openat(directory.fd,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
            guard fd>=0 else {throw RestoreDirectory.failure()}
            let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
            do {try handle.write(contentsOf:data);try handle.synchronize();try handle.close()}
            catch {try? handle.close();throw error}
        }
        for (i,data) in value.capture.frames.enumerated() {try write("support-\(i).frame",data)}
        for (i,data) in value.reports.enumerated() {try write("startup-\(i).frame",data)}
        for (role,_) in SNESCompatibilitySupportFrame.textLimits {guard let bytes=first.metadata[role] else {throw SNESCompatibilitySupportFrame.failure()};try write(role+".txt",bytes)}
        let record:[String:Any]=[
            "version":1,"scope":"passive-native-snes-compatibility-support","complete":true,
            "contextSHA256":value.context,"hwid":value.hwid,
            "attachment":["registryID":device.registryEntryID ?? 0,"locationID":device.locationID,"version":device.deviceVersion],
            "captureChallenges":value.capture.challenges.map(\.uuidString),"captureSHA256":value.capture.frames.map(BackupManifest.digest),
            "startupChallenges":value.reportChallenges.map(\.uuidString),"startupSHA256":value.reports.map(BackupManifest.digest),
            "libraryChains":first.chains,"librarySHA256":first.libraries.mapValues(BackupManifest.digest),
            "metadataSHA256":first.metadata.mapValues(BackupManifest.digest),
            "consoleFilesWritten":false,"firmwareWritten":false,"connectionClosed":true,"runtimeEligibility":false]
        try write("manifest.json",JSONSerialization.data(withJSONObject:record,options:[.sortedKeys,.prettyPrinted]))
        guard fsync(directory.fd)==0,fsync(outputRoot.fd)==0 else {throw RestoreDirectory.failure()}
        return String(decoding:try JSONSerialization.data(withJSONObject:[
            "directory":directory.url.path,"complete":true,"consoleFilesWritten":false,"firmwareWritten":false,"connectionClosed":true],
            options:[.sortedKeys,.prettyPrinted]),as:UTF8.self)
    }
}
