import Testing
@testable import SwiftHakchi

struct SNESLibraryWorkflowTests {
    @Test func returningToPreviousGamesHasItsOwnReviewRestartAndBusyGate() {
        #expect(SNESLibraryWorkflowPhase.readyToRollback.action == .rollback)
        #expect(SNESLibraryWorkflowPhase.rollbackRestart.action == .checkRollbackRestart)
        #expect(SNESLibraryWorkflowPhase.returningPrevious.isBusy)
        #expect(SNESLibraryWorkflowPhase.returningPrevious.action == nil)
        for phase in [SNESLibraryWorkflowPhase.readyToRollback,.returningPrevious,.rollbackRestart] {
            #expect(!phase.canEdit && !phase.isTerminal)
        }
    }

    @Test func copyingShowingAndFinishingAreSeparateAndCannotBeSkipped() {
        #expect(SNESLibraryWorkflowPhase.ready.action == .copy)
        #expect(SNESLibraryWorkflowPhase.copied.action == .show)
        #expect(SNESLibraryWorkflowPhase.restart.action == .checkRestart)
        #expect(SNESLibraryWorkflowPhase.testing.action == .confirmTest)
        #expect(SNESLibraryWorkflowPhase.readyToFinish.action == .finish)
        #expect(SNESLibraryWorkflowPhase.complete.action == .close)
        for phase in [SNESLibraryWorkflowPhase.copying, .savingSelection, .checkingRestart, .savingBackup, .finishing] {
            #expect(phase.isBusy && phase.action == nil && !phase.canEdit)
        }
    }
    @Test func controlsUseTheApprovedPlainLanguageAndOnlyReviewsAreEditable() {
        #expect(SNESLibraryWorkflowPhase.ready.buttonTitle == "Copy Games to Console")
        #expect(SNESLibraryWorkflowPhase.copied.buttonTitle == "Show Updated Games")
        #expect(SNESLibraryWorkflowPhase.readyToFinish.buttonTitle == "Finish Sync")
        #expect(SNESLibraryWorkflowPhase.complete.buttonTitle == "Done")
        #expect(SNESLibraryWorkflowPhase.review.canEdit && SNESLibraryWorkflowPhase.ready.canEdit)
        for phase in [SNESLibraryWorkflowPhase.copied, .restart, .testing, .readyToFinish, .interrupted] { #expect(!phase.canEdit) }
    }
    @Test func normalSyncProgressNamesEachStageWithoutMislabelingRecovery() {
        #expect(SNESLibraryWorkflowPhase.preparing.syncStep == 1)
        #expect(SNESLibraryWorkflowPhase.copying.syncStep == 2)
        #expect(SNESLibraryWorkflowPhase.savingSelection.syncStep == 3)
        #expect(SNESLibraryWorkflowPhase.testing.syncStep == 4)
        #expect(SNESLibraryWorkflowPhase.savingBackup.syncStep == 5)
        #expect(SNESLibraryWorkflowPhase.finishing.syncStep == 5)
        #expect(SNESLibraryWorkflowPhase.interrupted.syncStep == nil)
        #expect(SNESLibraryWorkflowPhase.returningPrevious.syncStep == nil)
        #expect(SNESLibraryWorkflowPhase.savingSelection.progressTitle.contains("console’s game menu"))
        #expect(!SNESLibraryWorkflowPhase.savingBackup.progressDetail.isEmpty)
        #expect(!SNESLibraryWorkflowPhase.finishing.progressDetail.isEmpty)
    }
}
