import SwiftUI

/// In-app help window with sidebar navigation and scrollable content sections
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    enum Section: String, CaseIterable, Identifiable {
        case gettingStarted = "Getting Started"
        case flashing = "Flashing the Console"
        case managingGames = "Managing Games"
        case syncing = "Syncing Games"
        case modules = "Modules (hmods)"
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

            bodyText("Hakchi Console Hub manages copied game ROMs on your Mac and can inspect a connected classic console. Available console actions depend on the exact model and software detected. NES library sync and US SNES setup and library sync have passed supervised hardware tests. First-time setup on a stock NES has not been verified. Other console models and games still need testing. Cheat Codes are configured in this app.")

            heading("Requirements")
            bulletList([
                "macOS 14 (Sonoma) or later",
                "A USB-A cable (or USB-C adapter) to connect your console",
                "A compatible classic console for connected features; you can manage a local library without one",
            ])

            heading("Window Layout")
            bodyText("The main window is organized into four areas from top to bottom:")
            numberedList([
                "Action Bar \u{2014} Connection and available console actions across the top",
                "Games Explorer \u{2014} Your ROM library as a grid of cover art cards on the left, with an editable detail panel on the right",
                "Console Game Bar \u{2014} The tray along the bottom labeled \"Desired Console Config\" showing which games will be on your console",
                "Status Bar \u{2014} Connection status and game counts at the very bottom",
            ])

            heading("Basic Workflow")
            numberedList([
                "Import \u{2014} Add supported ROM files or ZIP/7z archives; the app copies extracted ROMs into its managed library and leaves your originals untouched",
                "Edit \u{2014} Review names, metadata and cover art in the Games Explorer",
                "Connect \u{2014} Connect one console over USB and let the app identify its available actions",
                "Back up and review \u{2014} Use the guided review for a supported sync or recovery action before changing the console",
                "Test \u{2014} After a supported sync, check the menu, artwork, game launch and controller on the console",
            ])
        }
    }

    // MARK: - Flashing the Console

    private var flashingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Flashing the Console")

            bodyText("The kernel is the console's startup software. Changing it can enable custom game management, but a firmware operation is separate from copying games. It requires a verified image and recovery backup matched to the exact console. A general installation or factory restore is not yet available for every model.")

            heading("Install Kernel")
            bodyText("Install Kernel would write modified startup software to the console's internal storage so it remains installed after power is turned off. It would first need to identify the console, verify its original kernel backup, and guide you through the installation and recovery steps. It does not add your ROMs by itself. This general installer is disabled while it is being validated for each supported console.")

            heading("Entering FEL Mode")
            bodyText("A guided recovery action may ask you to enter FEL (bootloader) mode. Follow the instructions in that action; the usual NES sequence is:")
            numberedList([
                "Unplug the console from USB to remove power",
                "Make sure the console's power switch is ON",
                "Hold the RESET button on the console",
                "While holding RESET, plug in the USB cable to your Mac",
                "Keep holding RESET for 3 seconds, then release",
            ])
            bodyText("A dark power light and blank display are expected in FEL mode. A USB identifier alone does not prove the console is in FEL mode; the app must verify it before a recovery action.")

            heading("Connect / Disconnect")
            bodyText("For a normal USB connection, start the console without holding RESET and return to its game-selection menu. Choose Connect. If another app or virtual machine is using that USB device, release it there first.")

            heading("Memboot")
            bodyText("Memboot means 'boot from memory.' It would send a temporary system from the Mac to a console in FEL mode for inspection or recovery work. By itself, it does not install firmware or games in the console's internal storage; the temporary system is gone after power is removed. Memboot is disabled in this app while its guided workflow is being validated.")

            heading("Reboot")
            bodyText("Click the \"Reboot\" button in the action bar to restart the console. Only available while connected.")

            heading("Other Kernel Operations")
            bodyText("The Kernel menu contains recovery-related actions, but availability depends on the connected console and verified recovery material:")
            bulletList([
                "Uninstall / Factory Reset \u{2014} Do not assume these are available or that either preserves games and saves; review the enabled action's details first",
                "Shutdown \u{2014} Powers off a supported connected console",
            ])
        }
    }

    // MARK: - Managing Games

    private var managingGamesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Managing Games")

            heading("Adding Game Files")
            bodyText("Click Add Game Files in the Games Explorer and choose ROM files or ZIP/7z archives from your Mac. The app extracts supported ROMs into a temporary area, copies only the ROMs into its managed Games folder, and removes the temporary files. Your original ROMs and archives stay where they are. Open Settings > Storage to find the managed folder. Importing a file does not add it to a console. Current library formats are:")
            bulletList([
                ".nes and .fds \u{2014} NES local library; the tested legacy sync path currently requires raw .nes",
                ".sfc, .smc and .sfrom \u{2014} SNES local library; supported US SNES sync checks raw .sfc or .smc files",
                ".md, .bin and .gen \u{2014} Genesis / Mega Drive local library; console transfer is not available yet",
                ".zip and .7z \u{2014} The app imports supported ROMs inside; unrelated files are skipped. Very large, encrypted or unsafe archives may need manual extraction",
            ])

            heading("Importing from Console")
            bodyText("If your console already has custom games installed, click the \"Import from Console\" button in the Games Explorer header (only available while connected). This copies games from the console into your local library.")

            heading("Auto-Matching")
            bodyText("The app checks its bundled game database when you import a ROM. A matching title and details may be filled in; review them because ROM revisions and regions can differ. You can add or change box art separately.")

            heading("Editing Game Details")
            bodyText("Click any game card in the explorer to select it. The detail panel on the right shows editable fields:")
            bulletList([
                "Name, Publisher, Genre \u{2014} Text fields for game metadata",
                "Release Date \u{2014} In YYYY-MM-DD format",
                "Players \u{2014} Number of players (1\u{2013}4) with a Simultaneous toggle",
                "Command Line \u{2014} The launch command (advanced, usually auto-configured)",
                "Description \u{2014} Free-text description of the game",
            ])
            bodyText("Click \"Save\" in the detail panel to save your changes.")

            heading("Scraper")
            bodyText("For games that weren't auto-matched, select a game and click \"Search Online...\" in the detail panel. This opens the Scraper, which searches TheGamesDB for matching titles. Select the correct result and click \"Apply\" to import the metadata and cover art. Requires a TheGamesDB API key (see Settings).")

            heading("Downloading ROMs from Console")
            bodyText("To save a copy of a game's ROM from the console to your Mac, select the game and click \"Download from Console\" in the detail panel. You'll be prompted to choose a save location.")

            heading("Removing Games")
            bodyText("Choose Remove Games beside Add Game Files. To remove games from the console, open the console game list, uncheck the games, then complete the three sync steps. Your Mac copies are kept. To remove a game from this app, open the Mac library, select the game, and choose Remove Selected Game. Your original ROM file and installed console games stay unchanged. Remove All Imported Games clears the Mac library and keeps a recoverable copy in Removed Libraries.")
        }
    }

    // MARK: - Syncing Games

    private var syncingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Syncing Games")

            bodyText("The Console Game Bar shows your local selection. The connected console does not change until a supported sync review is prepared, transferred, verified and activated. On a supported older NES, use Folder Structure to choose the menu layout, then Sync Library to review changes before transferring them.")

            heading("Folder Structure")
            bodyText("Choose Folder Structure in the action bar to set how games are grouped, sorted and split across console menu pages. Save the layout first; saving it alone does not change the console.")

            heading("Adding Games to the Console Bar")
            bodyText("Drag game cards from the Games Explorer and drop them onto the Console Game Bar at the bottom. A dashed drop target appears when you start dragging. You can also double-click a game in the bar to re-enable it if it was hidden.")

            heading("Removing Games from the Console Bar")
            bodyText("Drag a game card off the Console Game Bar and drop it anywhere in the explorer area above. A \"Remove\" label follows your cursor (or \"Hide\" for stock games), and the game is deselected with a poof animation.")

            heading("Custom Games vs Default Games")
            bodyText("The Console Game Bar has two tabs:")
            bulletList([
                "Custom Games \u{2014} Your imported ROMs that you've dragged to the bar",
                "Default Games \u{2014} The console's built-in stock games",
            ])
            bodyText("Stock games can be hidden by dragging them off the bar, or re-enabled by right-clicking and choosing \"Re-enable\".")

            heading("Sync Library")
            bodyText("Choose Sync Library in the action bar when a supported console is connected. Review the games to add or remove, available space, and backup details before you approve transfer. You can use it again later to update the library. If the button is disabled, connect a supported console and let its library finish loading.")
            bodyText("Checking a game does not use console space immediately. The space summary stays visible while you choose games. Review Sync checks the exact transfer size. A temporary second copy is needed while the new menu is installed and tested. After you test the games and choose Finish Sync, those temporary copies are removed; recovery backups stay on your Mac.")

            heading("Storage Limits")
            bodyText("Use Reclaim Space to review old files left by earlier transfers. It verifies a Mac backup before removing them. The built-in games remain on the console. Use Backup History to restore a previous library from your Mac, and Settings > Storage to choose your Backups Folder.")

            heading("Safety")
            bodyText("Make a verified backup and review additions and removals before a console change. If an operation loses its USB response, inspect the saved transaction state before retrying or power cycling. A successful transfer alone does not prove every game will launch; test the menu and controls afterward.")
        }
    }

    // MARK: - Modules (hmods)

    private var modulesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Modules (hmods)")

            bodyText("Modules (hmods) can add emulator cores and other features. Module installation has not been validated on the tested legacy NES. Browse locally if useful, but use only an enabled, reviewed console action for your device.")

            heading("Opening the Module Manager")
            bodyText("Open the Module Manager from the Modules menu or press Cmd+Shift+M.")

            heading("Browsing & Installing")
            numberedList([
                "Switch to the \"Browse\" tab",
                "Click \"Load Repository\" to fetch the list of available modules",
                "Use the category filter to narrow results",
                "Click \"Install\" next to the module you want",
            ])
            bodyText("You can also install a module from a local .hmod file using the \"Install from File...\" button.")

            heading("Viewing Installed Modules")
            bodyText("The Installed tab requires a supported console connection. An empty or disabled list does not prove no modules are installed on an older console.")

            heading("Removing Modules")
            bodyText("In the \"Installed\" tab, select one or more modules, then click \"Uninstall Selected\".")
        }
    }

    // MARK: - Settings

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Settings")

            bodyText("Open Settings from the Hakchi Console Hub menu or press Cmd+,. Settings include Console, Appearance, Storage and Advanced.")

            heading("Console Tab")
            bulletList([
                "Default Console Type \u{2014} Choose NES Classic, SNES Classic, Famicom Mini, or Super Famicom Mini to match your hardware",
                "TheGamesDB API Key \u{2014} Enter your free API key from thegamesdb.net to enable the Scraper and library enrichment",
                "Fill Missing Covers \u{2014} Looks for missing box art without changing covers you already chose",
            ])

            heading("Storage Tab")
            bulletList([
                "Workspace \u{2014} Shows where the app keeps its managed library, backups and journals",
                "Games folder \u{2014} Shows your copied ROMs, details and art, with Show in Finder",
                "Upload compressed and Max game size \u{2014} Planned controls that are currently disabled",
            ])

            heading("Advanced Tab")
            bulletList([
                "Purge All Cover Art \u{2014} Deletes all cached cover images and re-downloads them from the game database. Useful if artwork appears corrupted.",
                "Purge All Imported Games \u{2014} Removes all imported ROMs, cached data, and cover art from the library. Built-in console games are not affected, and your original ROM files on disk are not deleted.",
            ])
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
                problem: "FEL device not found when trying to flash",
                solution: "Make sure the console is off, then hold RESET before plugging in USB. Keep holding for 3 seconds, then release. The status bar should show an orange dot and \"FEL Device Detected\". If it doesn't appear, try a different USB cable or port."
            )

            troubleItem(
                problem: "Sync fails or stalls",
                solution: "Read the operation's status and saved recovery record. Keep the console connected if a write may be in progress. Use the guided Inspect Recovery action before retrying; do not power cycle an uncertain switch."
            )

            troubleItem(
                problem: "Missing or corrupted cover art",
                solution: "Select the game and click \"Search Online...\" in the detail panel to search for artwork via the Scraper. You can also go to Settings \u{2192} Advanced and click \"Purge & Re-download...\" to re-fetch all cover art."
            )

            troubleItem(
                problem: "Games don't appear on the console after sync",
                solution: "First confirm the sync review was activated and accepted, then check the console's top-level menu and any More games folder. If the operation is uncertain, use its recovery inspection before restarting the console."
            )

            troubleItem(
                problem: "App won't launch",
                solution: "Hakchi Console Hub requires macOS 14 (Sonoma) or later. Check your macOS version in Apple menu \u{2192} About This Mac."
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
