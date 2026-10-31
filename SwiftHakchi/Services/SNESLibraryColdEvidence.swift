import Foundation
import SwiftHakchiCore

/// Inert evidence for the Mac journal. Physical adapters independently enforce their private native context.
struct SNESLibraryColdEvidence: Sendable {
    enum Destination:Sendable,Equatable {case updated,previous}
    let destination:Destination
    let reviewSHA256: String, previousAttachment: RecoveryProbeUSBDevice, attachment: RecoveryProbeUSBDevice
    let inventory: SNESLibraryInventory, evidenceSHA256: String
    init(plan: SNESLibrarySyncPlan, previousAttachment: RecoveryProbeUSBDevice, attachment: RecoveryProbeUSBDevice,
         expected: SNESStartupTrialExpectation, inventory: SNESLibraryInventory, challenges: [UUID], reports: [Data], now: Date = Date(),destination:Destination = .updated,pendingReceipt:SNESLibraryRollbackPendingReceipt? = nil) throws {
        _ = try SNESStartupTrialUSBPolicy.nativeIdentity(previousAttachment); _ = try SNESStartupTrialUSBPolicy.nativeIdentity(attachment)
        guard previousAttachment.deviceVersion == plan.requiredUSBVersion, attachment.deviceVersion == plan.requiredUSBVersion,
              previousAttachment.registryEntryID != attachment.registryEntryID, expected.deviceVersion == plan.requiredUSBVersion,
              expected.hwid == plan.before.hwid, challenges.count == 2, Set(challenges).count == 2, reports.count == 2,
              (0...60).contains(now.timeIntervalSince(inventory.capacity.measuredAt)) else { throw SNESLibraryInventory.failure() }
        let first = try SNESStartupTrialReport(reports[0], expected: expected, challenge: challenges[0])
        let last = try SNESStartupTrialReport(reports[1], expected: expected, challenge: challenges[1])
        guard first.mcpPID == last.mcpPID, first.daemonPID == last.daemonPID else { throw SNESLibraryInventory.failure() }
        for raw in reports {
            let lines = String(decoding: raw, as: UTF8.self).components(separatedBy: "\n")
            guard lines.contains(where: { line in
                let fields = line.split(separator: " ")
                return fields.count == 6 && fields[1] == "/usr/share/applications/clover-mcp.desktop" && fields[2] == "tmpfs"
            }) else { throw SNESLibraryInventory.failure() }
        }
        let pending:Data
        if destination == .previous {
            guard let proof=pendingReceipt,proof.id==plan.material.menu.id,proof.contextSHA256==inventory.contextSHA256,proof.hwid==plan.before.hwid else {throw SNESLibraryInventory.failure()}
            pending=proof.raw;try SNESLibraryPreviousCheck.require(plan,inventory:inventory)
        } else {pending=Data();try SNESLibraryActiveCheck.require(plan, inventory: inventory, preserveProfiles: false)}
        self.destination=destination
        self.reviewSHA256 = plan.reviewSHA256; self.previousAttachment = previousAttachment; self.attachment = attachment; self.inventory = inventory
        let descriptor = try SNESLibraryMenu.encode([previousAttachment, attachment])
        evidenceSHA256 = BackupManifest.digest((destination == .previous ? Data("rollback:".utf8)+pending:Data()) + descriptor + Data((plan.reviewSHA256 + ":" + inventory.stateSHA256 + ":" + reports.map(BackupManifest.digest).joined(separator: ":")).utf8))
    }
}
