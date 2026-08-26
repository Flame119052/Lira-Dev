import LiraCore
import SwiftUI

struct EventLogView: View {
    @ObservedObject var session: AppSession

    var body: some View {
        Group {
            switch session.store.state {
            case .empty:
                ContentUnavailableView(
                    "No events yet",
                    systemImage: "text.alignleft",
                    description: Text("The ledger is empty. New goals, runs, steps, and effects will appear here.")
                )
            case .error(let error):
                ContentUnavailableView(
                    errorTitle(error),
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorDetail(error))
                )
            case .loaded(let events):
                List(events, id: \.sequence) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("#\(event.sequence)  \(event.eventType)")
                            .font(.headline)
                        Text("\(event.aggregateKind.rawValue) · \(event.producer)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }

    private func errorTitle(_ error: EventLogError) -> String {
        switch error {
        case .ledgerUnavailable: "Ledger unavailable"
        case .disconnected: "Core dropped"
        case .invalidated: "Session revoked"
        case .timedOut: "Handshake timed out"
        }
    }

    private func errorDetail(_ error: EventLogError) -> String {
        switch error {
        case .ledgerUnavailable:
            "The durable core could not open the event ledger. Lira is still running; the log cannot load until the ledger is available."
        case .disconnected:
            "The connection to the core was dropped. This is not a revoked session and not a handshake timeout."
        case .invalidated:
            "The core revoked this session. Lira will not reconnect as if the socket merely dropped."
        case .timedOut:
            "The IPC handshake timed out before the core authenticated this app."
        }
    }
}
