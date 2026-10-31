import SwiftUI
import UniformTypeIdentifiers

struct FoldersManagerView: View {
    @ObservedObject var model: ConsoleStructureViewModel
    let games: [Game]
    let artworkDirectory: URL
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var error: String?

    private var folders: [ConsoleStructure.CustomFolderTree.Folder] {
        model.draft.custom?.folders ?? []
    }
    private var visibleGames: [Game] {
        games.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { ($0.name, $0.code) < ($1.name, $1.code) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Folders").font(.title2.bold())
            Text("Every included game must appear once. Move games among folders, then review the exact console preview before saving.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Add Folder") { model.addFolder() }
                Button("Reset to Automatic") { model.resetToAutomatic(); dismiss() }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            if let error { Text(error).foregroundStyle(.red) }
            if let issue = model.previewIssue {
                Text(issue).foregroundStyle(.orange).font(.callout)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Folders").font(.headline)
                    ForEach(folders, id: \.id) { folder in
                        folderRow(folder)
                    }
                    Divider()
                    TextField("Search games", text: $search)
                        .textFieldStyle(.roundedBorder)
                    ForEach(visibleGames, id: \.code) { game in
                        HStack {
                            Text(game.name + (game.isStock ? " (built-in)" : ""))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Picker("Location", selection: Binding(get: {
                                folders.first(where: { $0.gameCodes.contains(game.code) })?.id ?? ""
                            }, set: { target in model.assignGame(game.code, to: target.isEmpty ? nil : target) })) {
                                Text("Root screen").tag("")
                                ForEach(folders, id: \.id) { folder in
                                    Text(folder.title).tag(folder.id)
                                }
                            }
                            .labelsHidden().frame(width: 210)
                            .accessibilityLabel("Folder for " + game.name)
                        }
                    }
                }
            }
        }
        .padding(24).frame(minWidth: 740, minHeight: 620)
    }

    private func folderRow(_ folder: ConsoleStructure.CustomFolderTree.Folder) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Folder name", text: Binding(get: { folder.title },
                    set: { model.renameFolder(folder.id, to: $0) }))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Name for folder " + folder.id)
                Text("\(folder.gameCodes.count) games").font(.caption).foregroundStyle(.secondary)
                Button("Up") { model.moveFolder(folder.id, by: -1) }
                Button("Down") { model.moveFolder(folder.id, by: 1) }
                Button("Remove") { model.removeFolder(folder.id) }
            }
            HStack {
                Picker("Parent", selection: Binding(get: { folder.parentID },
                    set: { model.setParent(folder.id, to: $0) })) {
                    Text("Root screen").tag(nil as String?)
                    ForEach(folders.filter { $0.id != folder.id }, id: \.id) { other in
                        Text(other.title).tag(Optional(other.id))
                    }
                }
                .frame(width: 260)
                Button("Choose Folder Image…") { chooseImage(for: folder.id) }
                if let key = folder.artKey {
                    Text(key).font(.caption).foregroundStyle(.secondary)
                    Button("Use Classic Image") { model.setFolderArtwork(folder.id, key: nil) }
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func chooseImage(for id: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a PNG for this console folder. The app will keep a managed copy."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            let data = try GameArtworkStore.png(from: Data(contentsOf: source))
            try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
            let key = UUID().uuidString + ".png"
            try data.write(to: artworkDirectory.appendingPathComponent(key), options: .atomic)
            model.setFolderArtwork(id, key: key)
            model.setFolderArt(.custom)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
