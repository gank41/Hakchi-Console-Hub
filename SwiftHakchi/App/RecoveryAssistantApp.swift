import SwiftUI
import AppKit

@MainActor
final class RecoveryAssistantDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var model: RecoveryAssistantModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { model?.busy == true ? .terminateCancel : .terminateNow }
    func windowShouldClose(_ sender: NSWindow) -> Bool { model?.busy != true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
private struct RecoveryWindowGuard: NSViewRepresentable {
    let delegate: RecoveryAssistantDelegate
    func makeNSView(context: Context) -> NSView { GuardView(delegate:delegate) }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class GuardView: NSView {
        let guardDelegate: RecoveryAssistantDelegate
        init(delegate:RecoveryAssistantDelegate) { guardDelegate = delegate; super.init(frame:.zero) }
        required init?(coder:NSCoder) { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.delegate = guardDelegate; window?.tabbingMode = .disallowed }
    }
}
#if RECOVERY_ASSISTANT
@main
struct RecoveryAssistantApp: App {
    @NSApplicationDelegateAdaptor(RecoveryAssistantDelegate.self) private var delegate
    @StateObject private var model = RecoveryAssistantModel(demonstration:CommandLine.arguments.contains("--demo"))
    private var workspace: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of:"--workspace"), args.indices.contains(i+1), args[i+1].hasPrefix("/") else { return nil }
        return URL(fileURLWithPath:args[i+1])
    }
    init() { NSApplication.shared.setActivationPolicy(.regular); NSApplication.shared.activate(ignoringOtherApps:true) }
    var body: some Scene {
        Window("NES Recovery Assistant",id:"recovery") {
            RecoveryAssistantView(model:model,workspace:workspace)
                .background(RecoveryWindowGuard(delegate:delegate).frame(width:0,height:0))
                .onAppear { delegate.model = model }
        }.defaultSize(width:740,height:820)
            .commands { CommandGroup(replacing:.newItem) {} }
    }
}
#endif
