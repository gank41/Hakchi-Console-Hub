import SwiftUI
import UniformTypeIdentifiers

struct GameGenieCatalogView:View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model:GameGenieCatalogModel
    private let targetSystem:GameGenieSystem?
    private let onChoose:((GameGenieEffect)->Void)?
    @State private var selectedGame:String?
    @State private var selectedRow:String?
    @State private var showDownloadNotice=false
    init(gameName:String,system:GameGenieSystem = .nes,onChoose:((GameGenieEffect)->Void)?=nil) {
        _model=StateObject(wrappedValue:.init(workspace:AppConfig.shared.workspace.root,system:system,gameName:gameName,lockedSystem:onChoose==nil ? nil:system))
        targetSystem=onChoose==nil ? nil:system;self.onChoose=onChoose
    }
    private var rows:[GameGenieOfflineCatalog.Entry] {model.catalog?.entries(game:selectedGame ?? "") ?? []}
    private var selected:GameGenieOfflineCatalog.Entry? {rows.first{$0.id==selectedRow}}
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("Cheat Codes").font(.title2.bold())
                if targetSystem != nil {
                    Text("\(model.system.name) codes").foregroundStyle(.secondary)
                } else {
                    Picker("Console",selection:Binding(get:{model.system},set:{model.selectSystem($0);selectedGame=nil;selectedRow=nil})) {
                        ForEach(GameGenieSystem.allCases){Text($0.name).tag($0)}
                    }.frame(width:200).disabled(model.isDownloading)
                }
                Spacer()
                Button("Close"){model.cancel();dismiss()}.keyboardShortcut(.cancelAction)
            }
            Text("Browse codes for any game, even before adding it to your library. Choose your exact game and version; effects stay off until you enable them.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Search game titles",text:$model.query).textFieldStyle(.roundedBorder)
                if !model.query.isEmpty {Button{model.query=""}label:{Image(systemName:"xmark.circle.fill")}.buttonStyle(.plain).accessibilityLabel("Clear game search")}
                Button(model.catalog==nil ? "Download Codes…":"Update Codes…"){showDownloadNotice=true}.disabled(model.isDownloading || model.pending != nil)
                Button("Import Saved Catalog…"){importCatalog()}.disabled(model.isDownloading)
            }
            if let pending=model.pending {
                VStack(alignment:.leading,spacing:7) {
                    Label("Review downloaded codes",systemImage:"checklist").font(.headline)
                    Text(model.notice ?? "")
                    Text("\(pending.searchGames("").count) games · \(pending.effects.count) effect groups. Pages saved: \(pending.coverage.fetched) of \(pending.coverage.discovered).")
                    if !pending.coverage.failedURLs.isEmpty {
                        Text("Some game pages could not be read. You can keep this partial collection and download again later to resume.")
                        ScrollView{Text(pending.coverage.failedURLs.joined(separator:"\n")).font(.caption).textSelection(.enabled)}.frame(maxHeight:70)
                    }
                    HStack {
                        Button("Keep Current Catalog"){model.discardReview()}
                        Spacer()
                        Button("Save Codes on This Mac"){do{try model.acceptReview();selectFirstMatch()}catch{model.showError(error)}}.buttonStyle(.borderedProminent)
                    }
                }.padding(12).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
            }
            HStack(alignment:.top,spacing:10) {
                List(model.catalog?.searchGames(model.query) ?? [],id:\.self,selection:$selectedGame){Text($0).tag($0)}.frame(width:230)
                VStack(alignment:.leading,spacing:8) {
                    List(rows,selection:$selectedRow){row in
                        VStack(alignment:.leading,spacing:4) {
                            Text(row.title).font(.headline)
                            Text(displayCodes(row)).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                            if !row.reviewReasons.isEmpty {Label("Check game version or source notes",systemImage:"info.circle").font(.caption).foregroundStyle(.secondary)}
                        }.padding(.vertical,4).tag(row.id)
                    }
                    if rows.isEmpty {
                        VStack(alignment:.leading,spacing:6) {
                            Text((model.catalog?.searchGames(model.query).isEmpty ?? true) ? "No matching game title. Try a shorter name, or browse every game.":"Choose a game on the left to see its codes.")
                            Button("Browse All Games"){model.query="";selectedGame=nil;selectedRow=nil}
                        }.font(.callout).foregroundStyle(.secondary)
                    }
                    if let selected {
                        ScrollView {
                            VStack(alignment:.leading,spacing:5) {
                                if !selected.context.isEmpty {Text(selected.context)}
                                ForEach(Array((selected.notes+selected.reviewReasons).enumerated()),id:\.offset){Text($0.element)}
                            }.font(.caption).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled)
                        }.frame(height:110)
                    }
                }
            }.frame(minHeight:180)
            if model.catalog==nil && model.pending==nil {Text("No saved \(model.system.name) codes yet. Download once or import a catalog to browse offline.").foregroundStyle(.secondary)}
            if let error=model.error {Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled)}
            HStack {
                if model.isDownloading {
                    ProgressView().controlSize(.small)
                    Text(model.progress.map{"\($0.completed) of \($0.total) games · \($0.game)"} ?? "Checking the source…").font(.caption)
                    Button("Cancel Download"){model.cancel()}
                } else {Text(model.pending==nil ? (model.notice ?? "Saved catalogs work without an Internet connection."):"Review the collection before saving.").font(.caption).foregroundStyle(.secondary)}
                Spacer()
                Button("Open Codes Folder"){do{NSWorkspace.shared.open(try model.library.folder(create:true))}catch{model.showError(error)}}
                if let onChoose {
                    Button("Add Effect") {
                        guard let selected,let catalog=model.catalog else{return}
                        do{onChoose(try catalog.effect(from:selected));dismiss()}catch{model.showError(error)}
                    }.buttonStyle(.borderedProminent).disabled(selected?.selectableCodes(system:model.system)==nil || targetSystem != model.system)
                }
            }
        }.padding().frame(minWidth:900,idealWidth:1020,minHeight:650,idealHeight:740)
        .onAppear{selectFirstMatch()}
        .onChange(of:selectedGame){_,_ in selectedRow=nil}
        .onChange(of:model.query){_,_ in selectedGame=model.preferredGame;selectedRow=nil}
        .onDisappear{model.cancel()}
        .confirmationDialog("Download once for offline use",isPresented:$showDownloadNotice,titleVisibility:.visible) {
            Button("Download \(model.system.name) Codes"){model.startDownload()}
            Button("Cancel",role:.cancel){}
        } message:{Text("This saves codes on this Mac for offline use. It may take several minutes. You can cancel and resume later. Your current codes stay available until you review and save the new collection.")}
    }
    private func selectFirstMatch(){selectedGame=model.preferredGame}
    private func displayCodes(_ row:GameGenieOfflineCatalog.Entry)->String {
        let groups=row.alternatives.isEmpty ? [row.codes]:row.alternatives
        return (row.dependencies.isEmpty ? "":"Required: "+row.dependencies.joined(separator:" + ")+"\n")+groups.map{$0.joined(separator:" + ")}.joined(separator:" / ")
    }
    private func importCatalog(){
        let panel=NSOpenPanel();panel.allowedContentTypes=[.json];panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {try model.review(model.library.decodeImport(GameGenieCatalogLibrary.read(url)))}catch{model.showError(error)}
    }
}
