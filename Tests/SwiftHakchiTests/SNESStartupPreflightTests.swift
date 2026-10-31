import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

actor SNESStartupPreflightFixtureCache {
    static let shared=SNESStartupPreflightFixtureCache()
    private var saved:SNESStartupAdapterCandidate?
    func candidate() throws -> SNESStartupAdapterCandidate {
        if let saved { return saved }
        let candidate=try #require(try privateStartupAdapter());saved=candidate;return candidate
    }
}
actor SNESStartupPreflightFakeIO:SNESStartupPreflightIO {
    let candidate:SNESStartupAdapterCandidate,source:SNESPreparationSource,base:SNESPreparationFakeIO,fault:String
    var stages=0,hashes=0
    init(candidate:SNESStartupAdapterCandidate,fault:String) throws {
        self.candidate=candidate;self.fault=fault
        source=try SNESPreparationSource.load(candidate.material.support.setup)
        base=SNESPreparationFakeIO(source:source,fault:fault)
    }
    func inventory() async throws -> [RecoveryProbeUSBDevice] {
        if fault=="attachment",stages>0 { return [] };return try await base.inventory()
    }
    func boot(_ inputs:RecoveryBootInputs,expected:RecoveryProbeUSBDevice) async throws { try await base.boot(inputs,expected:expected) }
    func connect(expected:RecoveryProbeUSBDevice) async throws { try await base.connect(expected:expected) }
    func observe() async throws -> String { await base.observe() }
    func readBoot2(_ slot:RecoveryBootSlot) async throws -> RecoveryBoot2Read { try await (base as any RecoveryProbeIO).readBoot2(slot) }
    func readBoot1() async throws -> Data { try await (base as any RecoveryProbeIO).readBoot1() }
    func readPartitions() async throws -> Data { try await (base as any RecoveryProbeIO).readPartitions() }
    func readDataSuperblock() async throws -> Data {
        var header = fault=="header" ? Data(count:2048) : try RestoreDirectory(candidate.backup.directory).read("data-header.bin",maximum:2048)
        if fault=="older-backup" || (fault=="changed-header" && stages>0) { header[1068]^=1 }
        return Data("SWIFTHAKCHI_DATA_SUPERBLOCK_V1 2048 \(BackupManifest.digest(header))\n".utf8)+header
    }
    func disconnect() async { await base.disconnect() }
    func dataHash(challenge:UUID) -> Data {
        hashes+=1
        let digest=(["stale-backup","older-backup"].contains(fault) || (fault=="changed-data" && hashes==2)) ? String(repeating:"0",count:64):candidate.backup.sha256
        return Data("SWIFTHAKCHI_SNES_DATA_HASH_V1 \(challenge.uuidString) \(candidate.backup.byteCount) \(digest)\n".utf8)
    }
    func stageStartup(_ image:Data,stock:Data,id:UUID) throws {
        stages+=1;#expect(image==candidate.image && stock==source.stock)
        if fault=="stage" { throw SNESRuntimeBinding.failure() }
        if fault=="cancel" { throw CancellationError() }
    }
}
@Suite(.serialized)
struct SNESStartupPreflightTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_CURRENT_DATA"] != nil),
          arguments:["none","inventory","boot","connect","identity","mounted-data","kernel","second-kernel","boot1","partitions","header","stale-backup","stage","cancel","attachment","changed-data"])
    func checksCurrentBackupAndPreimageBeforeOneRAMStage(_ fault:String) async throws {
        let candidate=try await SNESStartupPreflightFixtureCache.shared.candidate()
        let io=try SNESStartupPreflightFakeIO(candidate:candidate,fault:fault),pinned=try PinnedFELInputs.load()
        let inputs=RecoveryBootInputs(fes1:pinned.fes1,uboot:pinned.uboot,bootImage:pinned.bootImage)
        if ["none","stale-backup"].contains(fault) {
            let result=try await SNESStartupPreflightService(wait:{}).capture(candidate:candidate,inputs:inputs,io:io)
            let export=try result.checkedExport(),m=try #require(JSONSerialization.jsonObject(with:export.manifest) as? [String:Any])
            #expect(m["scope"] as? String=="snes-startup-no-flash-preflight")
            #expect(m["complete"] as? Bool==true)
            for flag in ["firmwareWritten","firmwareInstallEligible","bootEligible","firmwareRestoreEligible"] { #expect(m[flag] as? Bool==false) }
            #expect(m["dataSHA256"] as? String==(fault=="none" ? candidate.backup.sha256:String(repeating:"0",count:64)))
            #expect(m["initialBackupDataSHA256"] as? String==candidate.backup.sha256)
            #expect(m["backupMatchesCheckedData"] as? Bool==(fault=="none"))
            #expect(await io.hashes==2)
        } else {
            await #expect(throws:(any Error).self) { _=try await SNESStartupPreflightService(wait:{}).capture(candidate:candidate,inputs:inputs,io:io) }
        }
        let events=await io.base.events
        #expect(events.filter { $0=="disconnect" }.count==1)
        #expect(events.filter { $0=="boot" }.count==(fault=="inventory" ? 0:1))
        #expect(await io.stages==(["none","stale-backup","stage","cancel","attachment","changed-data"].contains(fault) ? 1:0))
    }
}

extension SNESStartupPreflightTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_CURRENT_DATA"] != nil))
    func overlappingPreflightCannotOpenAnotherConnection() async throws {
        let candidate=try await SNESStartupPreflightFixtureCache.shared.candidate(),pinned=try PinnedFELInputs.load()
        let inputs=RecoveryBootInputs(fes1:pinned.fes1,uboot:pinned.uboot,bootImage:pinned.bootImage)
        let first=try SNESStartupPreflightFakeIO(candidate:candidate,fault:"none"),second=try SNESStartupPreflightFakeIO(candidate:candidate,fault:"none")
        let gate=StartupPreflightTestGate(),service=SNESStartupPreflightService(wait:{})
        let task=Task {try await service.capture(candidate:candidate,inputs:inputs,io:first,progress:{if $0 == .readingCurrentKernel {await gate.pause()}})}
        await gate.waitUntilPaused()
        await #expect(throws:(any Error).self) {try await service.capture(candidate:candidate,inputs:inputs,io:second)}
        #expect(await second.base.events.isEmpty)
        await gate.release();_=try await task.value
        #expect(await first.stages==1)
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_STARTUP_CANDIDATE"] != nil))
    func changedMacBackupAcrossAwaitStopsBeforeKernelReadsOrStaging() async throws {
        let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let path=try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_STARTUP_CANDIDATE"])
        let original=try SNESStartupAdapterCandidate.load(directory:URL(fileURLWithPath:path))
        let backup=root.appendingPathComponent(original.backup.directory.lastPathComponent),folder=root.appendingPathComponent(URL(fileURLWithPath:path).lastPathComponent)
        try FileManager.default.copyItem(at:original.backup.directory,to:backup)
        try FileManager.default.copyItem(at:URL(fileURLWithPath:path),to:folder)
        let manifest=folder.appendingPathComponent("manifest.json")
        var value=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as? [String:Any]);value["currentDataPath"]=backup.path
        try JSONSerialization.data(withJSONObject:value).write(to:manifest)
        let candidate=try SNESStartupAdapterCandidate.load(directory:folder)
        let io=try SNESStartupPreflightFakeIO(candidate:candidate,fault:"none"),pinned=try PinnedFELInputs.load(),gate=StartupPreflightTestGate()
        let task=Task {try await SNESStartupPreflightService(wait:{}).capture(candidate:candidate,inputs:.init(fes1:pinned.fes1,uboot:pinned.uboot,bootImage:pinned.bootImage),io:io,progress:{if $0 == .readingCurrentKernel {await gate.pause()}})}
        await gate.waitUntilPaused()
        let first=backup.appendingPathComponent("data-0000.bin");var bytes=try Data(contentsOf:first);bytes[0]^=1;try bytes.write(to:first)
        await gate.release()
        await #expect(throws:(any Error).self) {try await task.value}
        let events=await io.base.events
        #expect(!events.contains("kernel"))
        #expect(events.filter {$0=="disconnect"}.count==1)
        #expect(await io.stages==0)
    }
}

private actor StartupPreflightTestGate {
    private var reached=false
    private var waiting:[CheckedContinuation<Void,Never>]=[]
    private var paused:CheckedContinuation<Void,Never>?
    func pause() async {
        reached=true
        for next in waiting {next.resume()};waiting=[]
        await withCheckedContinuation {paused=$0}
    }
    func waitUntilPaused() async {
        if reached {return}
        await withCheckedContinuation {waiting.append($0)}
    }
    func release() {paused?.resume();paused=nil}
}

extension SNESStartupPreflightTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_CURRENT_DATA"] != nil),arguments:["older-backup","changed-header"])
    func readonlyCheckUsesLiveDataAndNeverCertifiesHistoricalBackup(_ fault:String) async throws {
        let candidate=try await SNESStartupPreflightFixtureCache.shared.candidate(),pinned=try PinnedFELInputs.load()
        let io=try SNESStartupPreflightFakeIO(candidate:candidate,fault:fault)
        let inputs=RecoveryBootInputs(fes1:pinned.fes1,uboot:pinned.uboot,bootImage:pinned.bootImage)
        if fault=="older-backup" {
            let result=try await SNESStartupPreflightService(wait:{}).capture(candidate:candidate,inputs:inputs,io:io)
            let m=try #require(JSONSerialization.jsonObject(with:result.checkedExport().manifest) as? [String:Any])
            #expect(m["dataSHA256"] as? String==String(repeating:"0",count:64))
            #expect(m["initialBackupDataSHA256"] as? String==candidate.backup.sha256)
            #expect(m["backupMatchesCheckedData"] as? Bool==false)
            for flag in ["firmwareWritten","firmwareInstallEligible","bootEligible","firmwareRestoreEligible"] {#expect(m[flag] as? Bool==false)}
        } else {
            await #expect(throws:(any Error).self) {_=try await SNESStartupPreflightService(wait:{}).capture(candidate:candidate,inputs:inputs,io:io)}
        }
        #expect(await io.stages==1)
        #expect(await io.base.events.filter {$0=="disconnect"}.count==1)
    }
}
