import Combine
import LiraCore
import SwiftUI

@main
struct LiraApp: App {
    @StateObject private var session = AppSession()

    var body: some Scene {
        WindowGroup("Lira") {
            EventLogView(session: session)
                .onAppear { session.recordLaunchIfNeeded() }
        }
    }
}

@MainActor
final class AppSession: ObservableObject {
    @Published var store: EventLogStore
    private var host: CoreHost?
    private var didRecordLaunch = false

    func recordLaunchIfNeeded() {
        guard !didRecordLaunch, let host else { return }
        didRecordLaunch = true
        try? host.recordLaunch()
    }

    init() {
        let store = EventLogStore(client: nil)
        self.store = store
        do {
            let host = try CoreHost.start(
                ledgerURL: LiraPaths.ledgerURL(),
                socketURL: LiraPaths.ipcSocketURL(),
                recordLaunch: false
            )
            self.host = host
            let live = EventLogStore(client: host.makeAppClient())
            live.onChange = { [weak self] in
                DispatchQueue.main.async {
                    self?.objectWillChange.send()
                }
            }
            // Keep `live` even when handshake times out. Catching here and
            // forcing the placeholder to `.disconnected` would hide `.timedOut`.
            live.connectAndStartPolling()
            self.store = live
        } catch CoreHostError.ledgerUnavailable {
            store.noteHostFailed(.ledgerUnavailable)
        } catch {
            store.noteHostFailed(.disconnected)
        }
    }
}
