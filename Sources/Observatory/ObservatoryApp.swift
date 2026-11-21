import AppKit
import Combine
import Network
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = DashboardStore()
    private var observers = Set<AnyCancellable>()
    private let network = NWPathMonitor()
    private var wasOffline = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in self?.store.suspendRequests() }
            .store(in: &observers)
        workspace.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.store.refreshOnWakeOrLaunch() }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: .providerCredentialsChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let store = self?.store, let provider = note.object as? String else { return }
                store.credentialsChanged(provider)
            }.store(in: &observers)
        Timer.publish(every: 60, tolerance: 10, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.store.refreshDue() }
            .store(in: &observers)
        network.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor in
                guard let self else { return }
                if self.wasOffline && !offline { self.store.retryAfterReconnect() }
                self.wasOffline = offline
            }
        }
        network.start(queue: DispatchQueue(label: "Observatory.connectivity"))
        store.refreshOnWakeOrLaunch()
    }

    func applicationDidBecomeActive(_ notification: Notification) { store.refreshDue() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        network.cancel()
        store.suspendRequests()
        CodexClient.shutdown()
    }
}

private enum DashboardSheet: Identifiable {
    case add, providers(Credential?), track(String, Reading), edit(Monitor)

    var id: String {
        switch self {
        case .add: return "add"
        case .providers(let credential): return "keys-" + (credential?.rawValue ?? "all")
        case .track: return "track"
        case .edit(let monitor): return monitor.id.uuidString
        }
    }
}

private struct DashboardWindow: View {
    @ObservedObject var store: DashboardStore
    @AppStorage("boardTheme") private var theme = BoardTheme.evergreen
    @State private var sheet: DashboardSheet?
    var body: some View {
        DashboardView(store: store, add: { sheet = .add }, settings: { sheet = .providers(nil) },
                      connect: { sheet = .providers($0) }, track: { sheet = .track($0, $1) },
                      edit: { sheet = .edit($0) })
            .sheet(item: $sheet) { selection in
                switch selection {
                case .add: AddMonitorView(onSave: store.add)
                case .providers(let credential):
                    ProviderSettingsView(provider: credential)
                case .track(let question, let answer):
                    ScheduledFeedSheet(draft: FeedProposal(tracking: question), editing: false) { monitor in
                        if monitor.prompt == question {
                            store.add(monitor, initialReading: answer)
                        } else {
                            store.add(monitor)
                        }
                    }
                case .edit(let original):
                    ScheduledFeedSheet(draft: FeedProposal(editing: original), editing: true, onSave: store.update)
                }
            }
            .environment(\.boardPalette, theme.palette)
            .preferredColorScheme(theme.scheme)
            .tint(theme.palette.accent)
            .alert("Local storage", isPresented: Binding(get: { store.storageMessage != nil },
                                                        set: { if !$0 { store.storageMessage = nil } })) {
                Button("OK") { store.storageMessage = nil }
            } message: { Text(store.storageMessage ?? "") }
            .focusedSceneValue(\.addMonitorAction, { sheet = .add })
            .focusedSceneValue(\.providerSettingsAction, { sheet = .providers(nil) })
    }
}

private struct AddMonitorAction: FocusedValueKey { typealias Value = () -> Void }
private struct ProviderSettingsAction: FocusedValueKey { typealias Value = () -> Void }
private extension FocusedValues {
    var addMonitorAction: (() -> Void)? {
        get { self[AddMonitorAction.self] }
        set { self[AddMonitorAction.self] = newValue }
    }
    var providerSettingsAction: (() -> Void)? {
        get { self[ProviderSettingsAction.self] }
        set { self[ProviderSettingsAction.self] = newValue }
    }
}

private struct BoardCommands: Commands {
    let store: DashboardStore
    @FocusedValue(\.addMonitorAction) private var add
    @FocusedValue(\.providerSettingsAction) private var settings
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Feed…") { add?() }.disabled(add == nil).keyboardShortcut("n")
            Button("Refresh Feeds") { store.refreshAll() }.keyboardShortcut("r")
        }
        CommandGroup(replacing: .appSettings) {
            Button("Provider Settings…") { settings?() }.disabled(settings == nil).keyboardShortcut(",")
        }
    }
}

@main
struct ObservatoryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window("Observatory", id: "dashboard") {
            DashboardWindow(store: delegate.store)
                .frame(minWidth: 820, minHeight: 590)
        }
        .defaultSize(width: 1120, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands { BoardCommands(store: delegate.store) }
    }
}
