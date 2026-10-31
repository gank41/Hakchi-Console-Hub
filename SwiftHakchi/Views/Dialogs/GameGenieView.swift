import SwiftUI

struct GameGenieView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    let game: Game
    @State private var session: GameGenieSession?
    @State private var profile = GameGenieProfile(romSHA256: "")
    @State private var effectName = ""
    @State private var codeText = ""
    @State private var message: String?
    @State private var error: String?
    @State private var exported: URL?
    @State private var showCatalog = false
    @State private var hasManagedCopy = false
    @State private var sourceGameName = ""
    @State private var copyNotice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("CHEAT CODES", systemImage: "memorychip").font(.title2.bold())
                    .padding(12).background(.yellow.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading) {
                    Text(game.name).font(.headline)
                    Text("\(session?.system.name ?? GameGenieSystem(console:game.consoleType)?.name ?? "") · Optional Cheat Codes copy").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let copyNotice {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Saved on this Mac", systemImage: "checkmark.circle.fill")
                            .font(.title3.bold()).foregroundStyle(.green)
                        Text(copyNotice).font(.body)
                        Text(session?.system == .nes ? "To play these changes on your console:" : "Your Cheat Codes copy is ready on this Mac.").font(.headline)
                        Text(session?.system == .nes ? "1. Close this window and connect your console.\n\n2. Choose Sync Library and follow the steps to copy and show your updated games.\n\n3. Test the game, then choose Finish Sync." : "SNES and Genesis console setup and game transfers are still being developed. This copy stays in your Mac library until that support is ready. You can change its codes and update the same copy here.")
                            .font(.body)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }
                HStack {
                    Button("Edit Cheats") { self.copyNotice = nil }
                    Spacer()
                    Button("Back to Library") { dismiss() }.buttonStyle(.borderedProminent)
                }
            } else {
            Text(hasManagedCopy
                 ? "Choose the cheats you want, then update this game's Cheat Codes copy. Your original game stays unchanged."
                 : "Choose the cheats you want, then create a Cheat Codes copy of this game. It appears in your library with [Cheat Code] in its name. Your original game stays unchanged.")
                .font(.callout)
            Text("To change or remove cheats later, update the same copy, then use Sync Library. Turning all effects off restores its original ROM bytes. The copy keeps its Cheat Code! cover. This is not an in-game switch. Codes must match the game's version; gameplay still needs testing.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach($profile.effects) { $effect in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Toggle("Use in Cheat Codes copy", isOn: $effect.enabled).labelsHidden().accessibilityLabel("Use \(effect.name) in Cheat Codes copy").help("Choose Update Cheat Codes Copy and then Sync Library to apply this choice to the console.")
                            TextField("Effect name", text: $effect.name)
                            Button("Remove") { profile.effects.removeAll { $0.id == effect.id } }
                        }
                        Text(effect.codes.joined(separator: " + ")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }.padding(.vertical, 4)
                }
            }.overlay {
                if profile.effects.isEmpty { Text("No cheats selected yet. Choose Browse Code Catalog to find saved codes, or enter your own below.").foregroundStyle(.secondary) }
            }.frame(minHeight: 150)
            HStack {
                TextField("Effect name, e.g. Infinite lives", text: $effectName).textFieldStyle(.roundedBorder)
                TextField("Cheat codes separated by spaces", text: $codeText).textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Button("Add Effect") { addEffect() }.disabled(session == nil || effectName.isEmpty || codeText.isEmpty)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Button("Browse Code Catalog…") { showCatalog = true }
                Button("Save Codes Only") { perform { session in try session.saveProfile(profile, manager: appState.gameManager); message = "Codes saved. No game copy was created or updated." } }
                Spacer()
                Button(hasManagedCopy ? "Update Cheat Codes Copy" : "Create Cheat Codes Copy") {
                    perform { session in
                        let copy = try GameGenieVariantStore.save(session: session, profile: profile, manager: appState.gameManager)
                        let wasUpdate = hasManagedCopy
                        hasManagedCopy = true
                        let count = profile.effects.filter(\.enabled).count
                        copyNotice = (wasUpdate ? "Updated " : "Created ") + copy.name
                            + (count == 0 ? " with cheats turned off."
                               : " with \(count) enabled \(count == 1 ? "cheat" : "cheats").")
                            + " Your console has not changed yet."
                    }
                }.buttonStyle(.borderedProminent)
                    .disabled(profile.enabledCodes.isEmpty && !hasManagedCopy)
            }.disabled(session == nil)
            DisclosureGroup("Advanced exports") {
            HStack {
                if let exported { Button("Show Export") { NSWorkspace.shared.activateFileViewerSelecting([exported]) } }
                Button("Export Runtime Cheats…") { perform { session in
                    let url = try session.exportRetroArch(profile, manager: appState.gameManager)
                    exported = url; message = "Runtime .cht, manifest and instructions exported to \(url.deletingLastPathComponent().path). All options start OFF. Console deployment is not performed."
                } }.disabled(profile.effects.isEmpty || session?.system != .nes)
                Button("Preview Patch") { perform { session in
                    let result = try session.preview(profile, manager: appState.gameManager)
                    message = "\(profile.enabledCodes.count) code(s) target \(result.offsets.count) program byte(s). Export creates a separate copy."
                } }.disabled(profile.enabledCodes.isEmpty)
                Button("Export Patched Copy…") { perform { session in
                    let url = try session.export(profile, manager: appState.gameManager)
                    exported = url; message = "Exported ROM and checksum manifest to \(url.deletingLastPathComponent().path). Not synced or imported automatically."
                } }.disabled(profile.enabledCodes.isEmpty)
            }.disabled(session == nil)
            }
            }
        }.padding().frame(width: 980, height: 630)
        .sheet(isPresented: $showCatalog) {
            GameGenieCatalogView(gameName: sourceGameName.isEmpty ? game.name : sourceGameName,system:session?.system ?? .nes) { effect in
                var candidate = profile
                guard !candidate.effects.contains(where: { Set($0.codes.map{$0.uppercased()}) == Set(effect.codes.map{$0.uppercased()}) }) else { message="This code group is already in this game’s effects.";return }
                candidate.effects.append(effect)
                do { try candidate.validate(sha256: profile.romSHA256); _ = try candidate.encodedForStorage(); profile = candidate }
                catch { self.error = error.localizedDescription }
            }
        }
        .onAppear {
            do {
                let opened = try GameGenieWorkflow.open(game: game, manager: appState.gameManager)
                profile = try opened.loadProfile(); session = opened
                hasManagedCopy = try GameGenieVariantStore.existing(session: opened, manager: appState.gameManager) != nil
                sourceGameName = appState.gameManager.games.first(where: { $0.code == opened.target.code })?.name ?? game.name
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: profile) { _, _ in message = nil; error = nil; exported = nil; copyNotice = nil }
    }
    private func addEffect() {
        var candidate = profile
        candidate.effects.append(GameGenieEffect(name: effectName.trimmingCharacters(in: .whitespacesAndNewlines), codes: GameGenieEffect.codes(from: codeText)))
        do { try candidate.validate(sha256: profile.romSHA256); _ = try candidate.encodedForStorage(); profile = candidate; effectName = ""; codeText = "" }
        catch { self.error = error.localizedDescription }
    }
    private func perform(_ action: (GameGenieSession) throws -> Void) {
        guard let session else { return }
        error = nil; message = nil; copyNotice = nil
        do { try action(session) } catch { self.error = error.localizedDescription }
    }
}
