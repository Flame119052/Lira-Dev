import Combine
import LiraCore
import SwiftUI

@main
struct LiraApp: App {
    @StateObject private var session = AppSession()

    var body: some Scene {
        WindowGroup("Lira") {
            EventLogView(session: session)
        }
    }
}

@MainActor
final class AppSession: ObservableObject {
    @Published var store: EventLogStore
    private var host: CoreHost?

    init() {
        let store = EventLogStore(client: nil)
        self.store = store
        do {
            let host = try CoreHost.start(
                ledgerURL: LiraPaths.ledgerURL(),
                socketURL: LiraPaths.ipcSocketURL(),
                recordLaunch: true
            )
            self.host = host
            let live = EventLogStore(client: host.makeAppClient())
            try live.connect()
            live.startPolling()
            live.onChange = { [weak self] in
                DispatchQueue.main.async {
                    self?.objectWillChange.send()
                }
            }
            self.store = live
        } catch CoreHostError.ledgerUnavailable {
            store.noteHostFailed(.ledgerUnavailable)
        } catch {
            store.noteHostFailed(.disconnected)
        }
    }
}
