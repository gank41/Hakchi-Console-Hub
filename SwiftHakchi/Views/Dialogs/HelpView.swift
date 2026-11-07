import SwiftUI

/// In-app help window with sidebar navigation and scrollable content sections
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    enum Section: String, CaseIterable, Identifiable {
        case gettingStarted = "Getting Started"
        case flashing = "Setting Up a Console"
        case managingGames = "Managing Games"
        case syncing = "Syncing Games"
        case modules = "Extra Features"
        case settings = "Settings"
        case troubleshooting = "Troubleshooting"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .gettingStarted: return "star"
            case .flashing: return "cpu"
            case .managingGames: return "gamecontroller"
            case .syncing: return "arrow.triangle.2.circlepath"
            case .modules: return "shippingbox"
            case .settings: return "gearshape"
            case .troubleshooting: return "wrench.and.screwdriver"
            }
        }
    }

    @State private var selectedSection: Section = .gettingStarted

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Hakchi Console Hub Help")
                    .font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Sidebar + content
            HStack(spacing: 0) {
                // Sidebar
                List(Section.allCases, selection: $selectedSection) { section in
                    Label(section.rawValue, systemImage: section.icon)
                        .tag(section)
                }
                .listStyle(.sidebar)
                .frame(width: 200)

                Divider()

                // Content
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        sectionContent(selectedSection)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(width: 650, height: 500)
    }

    // MARK: - Section content

    @ViewBuilder
    private func sectionContent(_ section: Section) -> some View {
        switch section {
        case .gettingStarted: gettingStartedContent
        case .flashing: flashingContent
        case .managingGames: managingGamesContent
        case .syncing: syncingContent
        case .modules: modulesContent
        case .settings: settingsContent
        case .troubleshooting: troubleshootingContent
        }
    }

    // MARK: - Getting Started

    private var gettingStartedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Getting Started")

            bodyText("Hakchi Console Hub helps you organize game files on your Mac and, on supported consoles, add them to your game menu.")
            bodyText("This is a work in progress. Adding supported games has been tested on a prepared US SNES Classic and an already-modified NES. The first-time SNES setup guide is a preview and has not yet been tested from beginning to end on a new console. Startup restore is available for certain saved installations; its app flow still needs console testing.")

            heading("Requirements")
            bulletList([
                "macOS 14 (Sonoma) or later",
                "A USB cable that can transfer data, plus an adapter if your Mac needs one",
                "A supported console, its controller and a TV for checking games",
            ])

            heading("Quick Start")
            numberedList([
                "Choose your console at the top of the window.",
                "Choose Add Game Files and select the games on your Mac. Your original files stay where they are.",
                "Connect a prepared console to your Mac, turn it on and leave its game menu visible. Choose Connect.",
                "Check the games you want, choose Sync Library, then choose Review Changes. Follow each step shown in the app.",
                "After restarting when asked, try an added game and an included game on your TV. When both work, follow the app's final step.",
            ])
            bodyText("Adding files to the Mac library does not immediately change your console. A game marked Needs Attention may not work with the console's built-in player.")
            bodyText("While the app says Working, keep the console connected and follow the message on screen. If something stops unexpectedly, read the message before restarting or trying again.")
        }
    }

    // MARK: - Setting Up a Console

    private var flashingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Setting Up a Console")

            bodyText("A new console may need setup before the app can add games. Setup changes how the console starts, so keep its backup on your Mac. Adding game files is a separate step.")

            heading("US SNES Classic")
            bodyText("Choose SNES Classic (USA), then choose Set Up SNES. The guide starts by saving and checking the console's startup files, then explains each available step. The first-time setup flow is a preview and has not yet been tested from beginning to end on a new console.")

            heading("When the App Asks You to Get Ready")
            bodyText("The on-screen instructions tell you when to turn the console off, unplug the USB cable, hold RESET and reconnect it. Follow those instructions for your console. During a setup check, the TV and power light may stay dark; the app will tell you what to expect.")

            heading("Connecting Normally")
            bodyText("To manage games on a prepared console, turn it on without holding RESET and leave the game menu visible. Connect its USB cable to the Mac and choose Connect. If another app or a virtual machine is using the console, disconnect it there first.")

            heading("Your Backups")
            bodyText("Keep the backup made for each console. Restoring games and folders, restoring game progress, and returning the console's startup software are different actions. Read the app's review before choosing an action. The replacement-console review and saved-game transfer are experimental and have not been verified between two consoles or two Macs.")
            bodyText("Restore Original SNES Startup can use a saved installation record to prepare and review a restore. The restore is available only when the saved record includes the startup tool tested on a console; other records need further testing.")
        }
    }

    // MARK: - Managing Games

    private var managingGamesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Managing Games")

            heading("Adding Game Files")
            bodyText("Choose Add Game Files and select game files or ZIP/7z archives on your Mac. The app makes its own copies; your original files stay where they are. Settings > Storage shows where the copies are kept. Adding a file to the Mac does not add it to the console.")
            bulletList([
                ".nes and .fds \u{2014} NES game files. The tested older NES transfer currently uses .nes files.",
                ".sfc, .smc and .sfrom \u{2014} SNES game files. Supported US SNES transfers check .sfc or .smc files.",
                ".md, .bin and .gen \u{2014} Genesis / Mega Drive files. Console transfer is not available yet.",
                ".zip and .7z \u{2014} The app looks inside for supported games. Very large, encrypted or unsafe archives may need to be opened first.",
            ])

            heading("Importing from Console")
            bodyText("When available for the connected console, choose Import from Console from the library's three-dot menu. This copies games from the console to the Mac library.")

            heading("Finding Game Details")
            bodyText("The app looks for a matching game when you add a file. Check the name and details, since versions can differ. You can add or change box art separately.")

            heading("Cheat Codes")
            bodyText("Select a game and open Cheat Codes. Turn on the codes you want, then choose Create Cheat Codes Copy. The app adds a separate game marked [Cheat Code] and keeps your original. Connect your console and check the new copy before syncing it. Codes can vary between game versions, so test the copy after syncing.")

            heading("Editing Game Details")
            bodyText("Click any game card in the explorer to select it. The detail panel on the right shows editable fields:")
            bulletList([
                "Name, publisher, genre and release date",
                "Number of players and whether they play at the same time",
                "Description and box art",
            ])
            bodyText("Click \"Save\" in the detail panel to save your changes.")

            heading("Game Details and Box Art")
            bodyText("Select a game and choose Search Metadata to look for its name and other details, or Find Box Art to look for a cover. Review the result before applying it. The built-in game list and box-art search do not need a key; TheGamesDB is an optional source for game details.")

            heading("Downloading from Console")
            bodyText("When Download from Console is available for a selected game, you can choose it to save a copy on your Mac.")

            heading("Removing Games")
            bodyText("Choose Remove Games beside Add Game Files. To remove games from the console, open the console game list, uncheck the games, then complete the three sync steps. Your Mac copies are kept. To remove a game from this app, open the Mac library, select the game, and choose Remove Selected Game. Your original ROM file and installed console games stay unchanged. Remove All Imported Games clears the Mac library and keeps a recoverable copy in Removed Libraries.")
        }
    }

    // MARK: - Syncing Games

    private var syncingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Syncing Games")

            bodyText("Syncing copies your chosen games from the Mac to a supported, prepared console. Choosing games on the Mac does not change the console until you follow the sync steps.")

            heading("Choose Your Games")
            bodyText("Use the checkboxes in the game list to choose the games you want. Included Games are the games that came with the console; Added Games are the files you brought into the app. The Show menu can also display Cheat Codes or games that Need Attention.")
            bodyText("If an added game matches an included game, the app points it out and keeps the included version selected by default. You can review the choice before syncing.")

            heading("Sync a Prepared US SNES")
            numberedList([
                "Connect the console, leave its game menu visible, check the games you want and choose Sync Library.",
                "Review your games, folders, available space and backup. Choose Review Changes and follow the app's backup prompt if one is needed.",
                "Choose Step 1. Copy Games to Console. When it finishes, choose Step 2. Show Updated Games.",
                "Restart the console when the app asks, then test the menu, an added game and an included game.",
                "If they work, follow the app's prompts and choose Step 3. Finish Sync. The app explains which temporary files will be removed.",
            ])
            bodyText("On the SNES, turn off My Game Play Demo and Classic Demo in Options before syncing so a demo does not start during the check. Keep the console connected while the app is working.")

            heading("Folders and Backups")
            bodyText("Choose Folder Structure to change how games are arranged. In Settings > Storage > Backup History, choose Back Up This SNES to save the current library, settings and progress on your Mac. This library backup is separate from the console’s startup software backup.")
            bodyText("Backup History can also compare saved-game files or review a games-and-folders restore. Copying saved progress to a replacement SNES is experimental and has not yet been verified between two consoles. Keep your backups and follow the separate on-screen checks.")
            bodyText("To bring an SNES backup to another Mac, select it in Backup History and choose Copy Backup to Another Mac. On the other Mac, choose Add Backup from Another Mac and select the copied SNES-Library folder. Set up the replacement console separately before reviewing the backup. This process is still being tested.")
            bodyText("If a sync stops or the app reports a problem, leave the console connected and follow the message on screen before trying again. Test games after syncing; copying a game does not guarantee it will play.")
        }
    }

    // MARK: - Extra Features

    private var modulesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Extra Features")
            bodyText("Some classic-console tools offer add-ons for extra game players and features. In this app, support depends on the console and is still being developed. An unavailable or empty list does not necessarily mean the console has no add-ons installed.")
            bodyText("Use only the options the app makes available for your console, and read the review before making changes.")
        }
    }

    // MARK: - Settings

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Settings")

            bodyText("Open Settings from the Hakchi Console Hub menu or press Command-comma.")
            bulletList([
                "General \u{2014} Choose Easy mode for the main tools or Advanced mode for additional technical options.",
                "Updates \u{2014} Check for a newer installer or open the project on GitHub.",
                "Appearance \u{2014} Choose an alternate app icon. The alternate icon appears while the app is running.",
                "Storage \u{2014} Find your copied games, choose where new backups are saved, or open Backup History.",
                "Advanced \u{2014} Set an optional key for online game details or review options for removing saved artwork and added games from this Mac.",
            ])
            bodyText("Choose your console from the menu at the top of the main window. Fill Missing Covers is in the library's three-dot menu. Read the confirmation before removing files.")
        }
    }

    // MARK: - Troubleshooting

    private var troubleshootingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Troubleshooting")

            troubleItem(
                problem: "Console not detected after connecting USB",
                solution: "Check the USB cable and try a different port. Make sure the console is powered on. If the console is playing its demo reel, press a button on the controller to exit it first. Click the \"Connect\" button in the action bar to retry. The status bar at the bottom shows a green dot when connected."
            )

            troubleItem(
                problem: "The app cannot find the console during setup",
                solution: "Follow the preparation steps shown in the app for your console. Check that the cable can transfer data, try another port, and make sure no other app or virtual machine is using the console's USB connection."
            )

            troubleItem(
                problem: "Sync fails or stalls",
                solution: "Read the message in the app. If it may still be changing the console, keep power and USB connected. Follow the app's recovery instructions before restarting or trying again."
            )

            troubleItem(
                problem: "Missing or corrupted cover art",
                solution: "Select the game and choose Find Box Art. To look for covers for several games, use Fill Missing Covers in the library's three-dot menu."
            )

            troubleItem(
                problem: "Games don't appear on the console after sync",
                solution: "Check that you completed Show Updated Games and restarted when the app asked. Look for a More games folder on the console. If the sync stopped, follow the recovery instructions in the app before trying again."
            )

            troubleItem(
                problem: "App won't launch",
                solution: "Hakchi Console Hub requires macOS 14 (Sonoma) or later. Check your macOS version in Apple menu \u{2192} About This Mac."
            )
            troubleItem(
                problem: "Someone asks for troubleshooting information",
                solution: "Choose Tools > Export Troubleshooting Logs, then choose where to save the ZIP file. Logs may contain console identifiers, game names and file paths. Review them before sharing; nothing is sent automatically."
            )
        }
    }

    // MARK: - Reusable components

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.title3.bold())
            .padding(.bottom, 4)
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .padding(.top, 4)
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.secondary)
    }

    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text("\u{2022}")
                        .foregroundStyle(.secondary)
                    Text(item)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, 8)
    }

    private func numberedList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1).")
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .trailing)
                    Text(item)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, 8)
    }

    private func troubleItem(problem: String, solution: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(problem)
                .font(.headline)
            Text(solution)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
    }
}
