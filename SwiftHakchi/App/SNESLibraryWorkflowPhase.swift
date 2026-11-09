import Foundation

enum SNESLibraryWorkflowPhase: Equatable {
    enum Action: Equatable { case prepare, createBackup, clearDeferred, copy, show, checkRestart, confirmTest, finish, discard, close, rollback, checkRollbackRestart }
    case reading, review, backupNeeded, deferredReady, preparing, ready, copying, copied, savingSelection, restart, checkingRestart, testing, savingBackup, checkingCompletion, clearingPrevious, readyToFinish, finishing, readyToDiscard, discarding, cancelled, complete, needsSetup, interrupted, readyToRollback, returningPrevious, rollbackRestart
    var isBusy: Bool { [.reading, .preparing, .copying, .savingSelection, .checkingRestart, .savingBackup, .checkingCompletion, .clearingPrevious, .finishing, .discarding, .returningPrevious].contains(self) }
    var isTerminal: Bool { self == .complete || self == .cancelled }
    var canEdit: Bool { self == .review || self == .ready }
    /// Steps describe the normal sync only. Recovery and interruptions have their own instructions.
    var syncStep: Int? {
        switch self {
        case .review, .deferredReady, .clearingPrevious, .preparing: 1
        case .ready, .copying: 2
        case .copied, .savingSelection: 3
        case .restart, .checkingRestart, .testing: 4
        case .savingBackup, .checkingCompletion, .readyToFinish, .finishing: 5
        default: nil
        }
    }
    var action: Action? {
        switch self {
        case .readyToRollback: .rollback
        case .rollbackRestart: .checkRollbackRestart
        case .review: .prepare
        case .backupNeeded: .createBackup
        case .deferredReady: .clearDeferred
        case .ready: .copy
        case .copied: .show
        case .restart: .checkRestart
        case .testing: .confirmTest
        case .readyToFinish: .finish
        case .readyToDiscard: .discard
        case .complete, .cancelled: .close
        default: nil
        }
    }
    var buttonTitle: String {
        switch action {
        case .rollback: "Return to Previous Games"
        case .checkRollbackRestart: "The Previous Menu Is Visible"
        case .prepare: "Review Changes"
        case .createBackup: "Back Up Now and Review"
        case .clearDeferred: "Continue Sync"
        case .copy: "Copy Games to Console"
        case .show: "Show Updated Games"
        case .checkRestart: "The New Menu Is Visible"
        case .confirmTest: "Finish Sync"
        case .finish: "Finish Sync"
        case .discard: "Remove Unfinished Copy"
        case .close: "Done"
        case nil: "Please wait…"
        }
    }
    var progressTitle: String {
        switch self {
        case .returningPrevious: "Restoring the console’s previous game menu…"
        case .reading: "Reading the console and selected games…"
        case .preparing: "Preparing your games and checking the Mac backup…"
        case .copying: "Copying new games and artwork…"
        case .savingSelection: "Setting up the console’s game menu…"
        case .checkingRestart: "Checking the restarted console…"
        case .savingBackup: "Saving your optional backup to this Mac…"
        case .checkingCompletion: "Checking your updated games…"
        case .clearingPrevious: "Preparing your next sync…"
        case .finishing: "Removing the previous console copy…"
        case .discarding: "Removing the unfinished copy…"
        default: ""
        }
    }
    var progressDetail: String {
        switch self {
        case .reading: "The app is checking what is on your console and what you selected on your Mac."
        case .preparing: "A backup helps you recover your games and saves if you need them later. This can take several minutes."
        case .copying: "The app is copying and checking the game files. Your current game menu stays available until the next step."
        case .savingSelection: "The updated games will appear on the console after you restart it."
        case .checkingRestart: "The app is checking that the console started with the expected games."
        case .savingBackup: "This keeps your current games and saves on the Mac. It can take several minutes."
        case .checkingCompletion: "The app is checking the console before finishing. Your previous console copy will stay."
        case .clearingPrevious: "The app is backing up your current games and clearing the previous sync’s old copy before continuing. This can take several minutes."
        case .finishing: "The app is freeing space after verifying your backup. Your current games and saves stay on the console."
        case .returningPrevious: "The app is preparing the console to show your previous games again."
        case .discarding: "The app is removing only the unfinished copy; your current games and saves stay."
        default: ""
        }
    }
}
