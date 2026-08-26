import Foundation

public enum EventLogError: Equatable, Sendable {
    case ledgerUnavailable
    case disconnected
    case invalidated
    case timedOut
}

public enum EventLogState: Equatable, Sendable {
    case empty
    case loaded([LedgerEventSummary])
    case error(EventLogError)
}

/// Client-side live log. Talks only through `IPCClient` — never opens GRDB.
public final class EventLogStore: @unchecked Sendable {
    private let client: IPCClient?
    private let io = DispatchQueue(label: "lira.event-log")
    private let lock = NSLock()
    private var events: [LedgerEventSummary] = []
    private var lastSequence: Int64 = 0
    private var timer: DispatchSourceTimer?
    private var _state: EventLogState = .empty

    public var onChange: (() -> Void)?

    public var state: EventLogState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    public init(client: IPCClient?) {
        self.client = client
    }

    public func noteHostFailed(_ error: EventLogError) {
        publish(.error(error))
    }

    public func connect() throws {
        guard let client else {
            publish(.error(.ledgerUnavailable))
            throw CoreHostError.ledgerUnavailable
        }
        do {
            try client.connect()
        } catch let error as IPCError {
            publish(mapIPC(error))
            throw error
        }
        try poll()
    }

    public func startPolling(interval: TimeInterval = 0.25) {
        io.sync {
            timer?.cancel()
            let source = DispatchSource.makeTimerSource(queue: io)
            source.schedule(deadline: .now() + interval, repeating: interval)
            source.setEventHandler { [weak self] in
                try? self?.pollLocked()
            }
            source.resume()
            timer = source
        }
    }

    public func poll() throws {
        try io.sync { try pollLocked() }
    }

    public func stop() {
        io.sync {
            timer?.cancel()
            timer = nil
            client?.close()
        }
    }

    private func pollLocked() throws {
        guard let client else {
            publish(.error(.ledgerUnavailable))
            throw CoreHostError.ledgerUnavailable
        }
        do {
            var reachedEnd = false
            while !reachedEnd {
                let data = try client.send(
                    LedgerIPC.encodeListEvents(afterSequence: lastSequence)
                )
                let page = try LedgerIPC.decodeResponse(data)
                if !page.ok {
                    publish(.error(.ledgerUnavailable))
                    return
                }
                if !page.events.isEmpty {
                    events.append(contentsOf: page.events)
                    lastSequence = page.events.last?.sequence ?? lastSequence
                }
                reachedEnd = page.reachedEnd
            }
            publish(events.isEmpty ? .empty : .loaded(events))
        } catch let error as IPCError {
            publish(mapIPC(error))
            throw error
        }
    }

    private func mapIPC(_ error: IPCError) -> EventLogState {
        switch error {
        case .invalidated:
            return .error(.invalidated)
        case .timedOut:
            return .error(.timedOut)
        case .disconnected:
            return .error(.disconnected)
        default:
            return .error(.disconnected)
        }
    }

    private func publish(_ new: EventLogState) {
        lock.lock()
        _state = new
        lock.unlock()
        onChange?()
    }
}
