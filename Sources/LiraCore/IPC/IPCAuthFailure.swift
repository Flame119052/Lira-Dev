import Darwin
import Foundation

/// Event type recorded when a peer is refused. Later tickets (#36, #47)
/// read this back from the ledger — do not rename it.
public enum IPCEventType {
    public static let authFailed = "ipc.auth_failed"
}

public struct IPCAuthFailedPayload: Codable, Equatable, Sendable {
    public let channel: String
    public let reason: String
    public let observedComponent: String?
    public let expectedComponent: String
    public let peerPID: Int32?
}

enum IPCAuthFailureRecorder {
    static func record(
        on ledger: EventLedger,
        channel: IPCChannel,
        reason: IPCError.RejectionReason,
        observedComponent: ComponentID?,
        peerPID: pid_t?
    ) throws {
        let payload = IPCAuthFailedPayload(
            channel: channel.name,
            reason: reason.rawValue,
            observedComponent: observedComponent?.rawValue,
            expectedComponent: channel.expectedPeer.component.rawValue,
            peerPID: peerPID.map { Int32($0) }
        )
        try ledger.append(
            PendingEvent(
                aggregateKind: .effect,
                aggregateID: channel.aggregateID,
                eventType: IPCEventType.authFailed,
                payloadSchemaVersion: 1,
                provenance: EventProvenance(producer: "lira.ipc"),
                payload: try JSONEncoder().encode(payload)
            )
        )
    }
}
