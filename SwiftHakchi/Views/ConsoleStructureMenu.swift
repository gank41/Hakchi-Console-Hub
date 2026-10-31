import SwiftUI
import SwiftHakchiCore

struct ConsoleMenuLimitPicker: View {
    @ObservedObject private var config = AppConfig.shared

    var body: some View {
        Picker(selection: Binding(get: { config.structure(for: .nes).maximumGamesPerPage }, set: { value in
            if (try? config.updateLegacyMenuLimit(value)) != nil { config.save() }
        })) {
            ForEach(ConsoleMenuLimit.allCases) { limit in
                Text(limit.menuTitle).tag(limit)
            }
        } label: {
            Text("Maximum games per page/folder")
        }
        .pickerStyle(.menu)
        .disabled(config.structureLoadIssue != nil)
        .help(config.structureLoadIssue ?? "The limit counts games. Navigation links are additional entries.")
    }
}
