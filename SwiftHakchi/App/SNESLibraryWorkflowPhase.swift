import Foundation

enum SNESLibraryWorkflowPhase: Equatable {
    enum Action: Equatable { case prepare, createBackup, copy, show, checkRestart, confirmTest, finish, discard, close, rollback, checkRollbackRestart }
    case reading, review, backupNeeded, preparing, ready, copying, copied, savingSelection, restart, checkingRestart, testing, savingBackup, readyToFinish, finishing, readyToDiscard, discarding, cancelled, complete, needsSetup, interrupted, readyToRollback, returningPrevious, rollbackRestart
    var isBusy: Bool { [.reading, .preparing, .copying, .savingSelection, .checkingRestart, .savingBackup, .finishing, .discarding, .returningPrevious].contains(self) }
    var isTerminal: Bool { self == .complete || self == .cancelled }
    var canEdit: Bool { self == .review || self == .ready }
    /// Steps describe the normal sync only. Recovery and interruptions have their own instructions.
    var syncStep: Int? {
        switch self {
        case .review, .preparing: 1
        case .ready, .copying: 2
        case .copied, .savingSelection: 3
        case .restart, .checkingRestart, .testing: 4
        case .savingBackup, .readyToFinish, .finishing: 5
        default: nil
        }
    }
    var action: Action? {
        switch self {
        case .readyToRollback: .rollback
        case .rollbackRestart: .checkRollbackRestart
        case .review: .prepare
        case .backupNeeded: .createBackup
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
        case .copy: "Copy Games to Console"
        case .show: "Show Updated Games"
        case .checkRestart: "The New Menu Is Visible"
        case .confirmTest: "Games Work—Continue"
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
        case .savingBackup: "Backing up your tested games and saves to this Mac…"
        case .finishing: "Finishing sync and clearing the old console copy…"
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
        case .savingBackup: "This backup keeps the tested game library and current saves on your Mac. It can take several minutes."
        case .finishing: "The app is removing the older console copy to free space. Your tested games, saves and Mac backup stay."
        case .returningPrevious: "The app is preparing the console to show your previous games again."
        case .discarding: "The app is removing only the unfinished copy; your current games and saves stay."
        default: ""
        }
    }
}
