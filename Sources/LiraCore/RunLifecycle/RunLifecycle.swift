import Foundation

/// Sole writer of `goal` / `run` / `step` ledger events (ticket #35).
///
/// Authoritative state is always the ledger. Every command projects from
/// events, validates a transition, and appends — nothing is cached across
/// calls. `init` does not reconcile; the caller must invoke `reconcile()`
/// on launch.
public final class RunLifecycle: @unchecked Sendable {
    private let ledger: EventLedger
    private let clock: LifecycleClock
    private let lock = NSLock()
    private let provenance = EventProvenance(producer: LifecycleProducer.runtime)

    public init(ledger: EventLedger, clock: LifecycleClock = SystemClock()) {
        self.ledger = ledger
        self.clock = clock
    }

    // MARK: - Create

    @discardableResult
    public func createGoal(
        title: String,
        deadline: Date? = nil,
        idempotencyKey: String? = nil
    ) throws -> UUID {
        let title = try requireBounded(
            title, field: "title", max: LifecycleLimits.maxTitleLength, empty: .invalidTitle
        )
        let key = try boundedKey(idempotencyKey)
        return try locked { world in
            if let key, let existing = world.eventMatching(
                type: LifecycleEventType.goalCreated, key: key
            ) {
                return existing.aggregateID
            }
            let id = UUID()
            try world.append(
                id: id,
                kind: .goal,
                type: LifecycleEventType.goalCreated,
                payload: LifecyclePayload(
                    title: title, deadlineAt: deadline, idempotencyKey: key
                )
            )
            return id
        }
    }

    @discardableResult
    public func createRun(
        goalID: UUID,
        deadline: Date? = nil,
        idempotencyKey: String? = nil
    ) throws -> UUID {
        let key = try boundedKey(idempotencyKey)
        return try locked { world in
            if let key, let existing = world.eventMatching(
                type: LifecycleEventType.runCreated, key: key, goalID: goalID
            ) {
                return existing.aggregateID
            }
            guard let parent = world.snapshot(goalID) else {
                throw LifecycleError.unknownAggregate
            }
            guard parent.kind == .goal else { throw LifecycleError.parentNotFound }
            guard !parent.state.isTerminal else { throw LifecycleError.parentIsTerminal }
            let id = UUID()
            try world.append(
                id: id,
                kind: .run,
                type: LifecycleEventType.runCreated,
                payload: LifecyclePayload(
                    goalID: goalID, deadlineAt: deadline, idempotencyKey: key
                )
            )
            return id
        }
    }

    @discardableResult
    public func createStep(
        runID: UUID,
        kind: String,
        deadline: Date? = nil,
        idempotencyKey: String? = nil
    ) throws -> UUID {
        let kind = try requireBounded(
            kind, field: "kind", max: LifecycleLimits.maxKindLength, empty: .invalidKind
        )
        let key = try boundedKey(idempotencyKey)
        return try locked { world in
            if let key, let existing = world.eventMatching(
                type: LifecycleEventType.stepCreated, key: key, runID: runID
            ) {
                return existing.aggregateID
            }
            guard let parent = world.snapshot(runID) else {
                throw LifecycleError.unknownAggregate
            }
            guard parent.kind == .run else { throw LifecycleError.parentNotFound }
            guard !parent.state.isTerminal else { throw LifecycleError.parentIsTerminal }
            let id = UUID()
            try world.append(
                id: id,
                kind: .step,
                type: LifecycleEventType.stepCreated,
                payload: LifecyclePayload(
                    runID: runID, kind: kind, deadlineAt: deadline, idempotencyKey: key
                )
            )
            return id
        }
    }

    // MARK: - Transitions

    public func start(_ id: UUID, idempotencyKey: String? = nil) throws {
        let key = try boundedKey(idempotencyKey)
        try locked { world in
            if let key, world.hasKey(id: id, type: startType(of: world, id: id), key: key) {
                return
            }
            guard let snap = world.snapshot(id) else { throw LifecycleError.unknownAggregate }
            guard snap.state == .pending else {
                throw LifecycleError.illegalTransition(from: snap.state, to: .running)
            }
            switch snap.kind {
            case .goal, .effect:
                throw LifecycleError.cannotStart(snap.kind)
            case .run:
                try world.append(
                    id: id, kind: .run, type: LifecycleEventType.runStarted,
                    payload: LifecyclePayload(idempotencyKey: key)
                )
            case .step:
                guard let parentID = snap.parentID, let parent = world.snapshot(parentID) else {
                    throw LifecycleError.parentNotFound
                }
                // Own run state must be `running` (run.started), not merely derived.
                guard parent.state == .running || parent.state == .awaitingApproval else {
                    throw LifecycleError.parentNotRunning
                }
                try world.append(
                    id: id, kind: .step, type: LifecycleEventType.stepStarted,
                    payload: LifecyclePayload(idempotencyKey: key)
                )
            }
        }
    }

    public func succeed(_ id: UUID, idempotencyKey: String? = nil) throws {
        let key = try boundedKey(idempotencyKey)
        try locked { world in
            guard let snap = world.snapshot(id) else { throw LifecycleError.unknownAggregate }
            let type = lifecycleTerminalEventType(kind: snap.kind, state: .succeeded)
            if let key, world.hasKey(id: id, type: type, key: key) { return }
            try requireTransition(snap.state, to: .succeeded)
            if world.hasLiveChildren(id) { throw LifecycleError.hasNonTerminalChildren }
            try world.append(
                id: id, kind: snap.kind, type: type,
                payload: LifecyclePayload(idempotencyKey: key)
            )
        }
    }

    public func fail(_ id: UUID, reason: String, idempotencyKey: String? = nil) throws {
        let reason = try requireBounded(
            reason, field: "reason", max: LifecycleLimits.maxReasonLength, empty: .emptyField("reason")
        )
        let key = try boundedKey(idempotencyKey)
        try locked { world in
            guard let snap = world.snapshot(id) else { throw LifecycleError.unknownAggregate }
            let type = lifecycleTerminalEventType(kind: snap.kind, state: .failed)
            if let key, world.hasKey(id: id, type: type, key: key) { return }
            if snap.state.isTerminal {
                if snap.state == .failed { return }
                throw LifecycleError.illegalTransition(from: snap.state, to: .failed)
            }
            try requireTransition(snap.state, to: .failed)
            try world.failDownAndUp(id, reason: reason, idempotencyKey: key)
        }
    }

    public func cancel(_ id: UUID, reason: String? = nil, idempotencyKey: String? = nil) throws {
        let reason = try optionalBounded(
            reason, field: "reason", max: LifecycleLimits.maxReasonLength
        )
        let key = try boundedKey(idempotencyKey)
        try locked { world in
            guard let snap = world.snapshot(id) else { throw LifecycleError.unknownAggregate }
            let type = lifecycleTerminalEventType(kind: snap.kind, state: .cancelled)
            if let key, world.hasKey(id: id, type: type, key: key) { return }
            if snap.state.isTerminal {
                if snap.state == .cancelled { return }
                throw LifecycleError.illegalTransition(from: snap.state, to: .cancelled)
            }
            try requireTransition(snap.state, to: .cancelled)
            try world.cancelDownAndUp(id, reason: reason, idempotencyKey: key)
        }
    }

    // MARK: - Turn loop

    public func recordModelCall(
        stepID: UUID,
        provenance: EventProvenance? = nil,
        idempotencyKey: String? = nil
    ) throws {
        let key = try boundedKey(idempotencyKey)
        try locked { world in
            if let key, world.hasKey(
                id: stepID, type: LifecycleEventType.stepModelCalled, key: key
            ) { return }
            _ = try runningStep(world, stepID)
            try world.append(
                id: stepID,
                kind: .step,
                type: LifecycleEventType.stepModelCalled,
                payload: LifecyclePayload(idempotencyKey: key),
                provenance: provenance ?? self.provenance
            )
        }
    }

    public func recordToolCall(
        stepID: UUID,
        tool: String,
        requiresApproval: Bool,
        idempotencyKey: String? = nil
    ) throws {
        let tool = try requireBounded(
            tool, field: "tool", max: LifecycleLimits.maxToolLength, empty: .emptyField("tool")
        )
        let key = try boundedKey(idempotencyKey)
        try locked { world in
            if let key, world.hasKey(
                id: stepID, type: LifecycleEventType.stepToolCalled, key: key
            ) { return }
            _ = try runningStep(world, stepID)
            try world.append(
                id: stepID,
                kind: .step,
                type: LifecycleEventType.stepToolCalled,
                payload: LifecyclePayload(
                    idempotencyKey: key, tool: tool, requiresApproval: requiresApproval
                )
            )
            if requiresApproval {
                try world.append(
                    id: stepID,
                    kind: .step,
                    type: LifecycleEventType.stepAwaitingApproval,
                    payload: LifecyclePayload(idempotencyKey: key, tool: tool)
                )
            }
        }
    }

    public func recordToolResult(
        stepID: UUID,
        tool: String,
        outcome: String,
        idempotencyKey: String? = nil
    ) throws {
        let tool = try requireBounded(
            tool, field: "tool", max: LifecycleLimits.maxToolLength, empty: .emptyField("tool")
        )
        let outcome = try requireBounded(
            outcome, field: "outcome", max: LifecycleLimits.maxOutcomeLength, empty: .emptyField("outcome")
        )
        let key = try boundedKey(idempotencyKey)
        try locked { world in
            if let key, world.hasKey(
                id: stepID, type: LifecycleEventType.stepToolResult, key: key
            ) { return }
            _ = try runningStep(world, stepID)
            try world.append(
                id: stepID,
                kind: .step,
                type: LifecycleEventType.stepToolResult,
                payload: LifecyclePayload(
                    idempotencyKey: key, tool: tool, outcome: outcome
                )
            )
        }
    }

    public func approve(stepID: UUID, idempotencyKey: String? = nil) throws {
        let key = try boundedKey(idempotencyKey)
        try locked { world in
            if let key, world.hasKey(
                id: stepID, type: LifecycleEventType.stepApproved, key: key
            ) { return }
            guard let snap = world.snapshot(stepID), snap.kind == .step else {
                throw LifecycleError.notAStep
            }
            try requireTransition(snap.state, to: .running)
            guard snap.state == .awaitingApproval else {
                throw LifecycleError.illegalTransition(from: snap.state, to: .running)
            }
            try world.append(
                id: stepID,
                kind: .step,
                type: LifecycleEventType.stepApproved,
                payload: LifecyclePayload(idempotencyKey: key)
            )
        }
    }

    public func deny(stepID: UUID, reason: String? = nil, idempotencyKey: String? = nil) throws {
        let reason = try optionalBounded(
            reason, field: "reason", max: LifecycleLimits.maxReasonLength
        ) ?? LifecycleReason.denied
        let key = try boundedKey(idempotencyKey)
        try locked { world in
            if let key, world.hasKey(
                id: stepID, type: LifecycleEventType.stepFailed, key: key
            ) { return }
            guard let snap = world.snapshot(stepID), snap.kind == .step else {
                throw LifecycleError.notAStep
            }
            guard snap.state == .awaitingApproval else {
                throw LifecycleError.illegalTransition(from: snap.state, to: .failed)
            }
            try world.failDownAndUp(stepID, reason: reason, idempotencyKey: key)
        }
    }

    // MARK: - Reconcile / read

    /// Fail in-flight `running` work as `interrupted`, time out crossed
    /// deadlines, leave `pending` / `awaitingApproval` in place. Idempotent:
    /// a second call appends nothing because targets are already terminal.
    /// Interrupt + timeout land in **one** atomic append.
    @discardableResult
    public func reconcile() throws -> ReconciliationReport {
        try locked(processDeadlines: false) { world in
            var interrupted: [UUID] = []
            let runningTargets = world.snapshots.values
                .filter { $0.state == .running && $0.kind != .goal }
                .sorted { left, right in
                    // Steps first so a run failed via cascade is skipped.
                    if left.kind == right.kind { return left.id.uuidString < right.id.uuidString }
                    return left.kind == .step
                }
            for snap in runningTargets {
                if world.snapshot(snap.id)?.state.isTerminal == true { continue }
                try world.failDownAndUp(snap.id, reason: LifecycleReason.interrupted)
                interrupted.append(snap.id)
            }

            var timedOut: [UUID] = []
            let now = clock.now
            let expired = world.snapshots.values
                .filter { snap in
                    guard !snap.state.isTerminal, let deadline = snap.deadline else { return false }
                    return deadline <= now
                }
                .sorted { $0.id.uuidString < $1.id.uuidString }
            for snap in expired {
                if world.snapshot(snap.id)?.state.isTerminal == true { continue }
                try world.failDownAndUp(snap.id, reason: LifecycleReason.timedOut)
                timedOut.append(snap.id)
            }

            let resumed = world.snapshots.values
                .filter { !$0.state.isTerminal }
                .map(\.id)

            return ReconciliationReport(
                interrupted: interrupted,
                timedOut: timedOut,
                resumed: resumed
            )
        }
    }

    public func snapshot(_ id: UUID) throws -> AggregateSnapshot? {
        try read { $0.snapshot(id) }
    }

    public func allSnapshots() throws -> [AggregateSnapshot] {
        try read { Array($0.snapshots.values) }
    }

    // MARK: - Internals

    /// Commands and `reconcile` apply crossed deadlines, then the body, then
    /// deadlines again (a newly created aggregate may already be past due).
    /// Reads do not write.
    private func locked<T>(
        processDeadlines: Bool = true,
        _ body: (inout World) throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        var world = try World.load(from: ledger)
        if processDeadlines {
            try world.applyTimeouts(now: clock.now)
        }
        let result = try body(&world)
        if processDeadlines {
            try world.applyTimeouts(now: clock.now)
        }
        try world.commit(to: ledger)
        return result
    }

    private func read<T>(_ body: (World) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        let world = try World.load(from: ledger)
        return try body(world)
    }

    private func runningStep(_ world: World, _ id: UUID) throws -> AggregateSnapshot {
        guard let snap = world.snapshot(id), snap.kind == .step else {
            throw LifecycleError.notAStep
        }
        guard snap.state == .running else {
            throw LifecycleError.illegalTransition(from: snap.state, to: .running)
        }
        return snap
    }

    private func requireTransition(_ from: LifecycleState, to: LifecycleState) throws {
        let allowed: Set<LifecycleState>
        switch from {
        case .pending:
            allowed = [.running, .cancelled, .failed]
        case .running:
            allowed = [.awaitingApproval, .succeeded, .failed, .cancelled]
        case .awaitingApproval:
            allowed = [.running, .failed, .cancelled]
        case .succeeded, .failed, .cancelled:
            allowed = []
        }
        guard allowed.contains(to) else {
            throw LifecycleError.illegalTransition(from: from, to: to)
        }
    }

    private func startType(of world: World, id: UUID) -> String {
        switch world.snapshot(id)?.kind {
        case .run: return LifecycleEventType.runStarted
        case .step: return LifecycleEventType.stepStarted
        default: return ""
        }
    }

    private func requireBounded(
        _ value: String,
        field: String,
        max: Int,
        empty: LifecycleError
    ) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw empty }
        if trimmed.count > max { throw LifecycleError.fieldTooLong(field: field, max: max) }
        return trimmed
    }

    private func optionalBounded(_ value: String?, field: String, max: Int) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.count > max { throw LifecycleError.fieldTooLong(field: field, max: max) }
        return trimmed
    }

    private func boundedKey(_ key: String?) throws -> String? {
        try optionalBounded(key, field: "idempotencyKey", max: LifecycleLimits.maxIdempotencyKeyLength)
    }
}

// MARK: - Projection (never stored)

private struct World {
    var snapshots: [UUID: AggregateSnapshot] = [:]
    var children: [UUID: [UUID]] = [:]
    var pending: [PendingEvent] = []
    let existing: [CommittedEvent]

    static func load(from ledger: EventLedger) throws -> World {
        let events = try ledger.allEvents()
        var world = World(existing: events)
        world.rebuild(from: events)
        return world
    }

    mutating func rebuild(from events: [CommittedEvent]) {
        snapshots = [:]
        children = [:]
        var own: [UUID: Own] = [:]
        for event in events where event.aggregateKind != .effect {
            var record = own[event.aggregateID] ?? Own(kind: event.aggregateKind)
            record.apply(event)
            own[event.aggregateID] = record
        }
        for (id, record) in own {
            snapshots[id] = record.snapshot(id: id)
            if let parent = record.parentID {
                children[parent, default: []].append(id)
            }
        }
        deriveParents()
    }

    mutating func deriveParents() {
        // Runs first (from steps), then goals (from runs).
        for (id, snap) in snapshots where snap.kind == .run && !snap.state.isTerminal {
            let stepStates = (children[id] ?? []).compactMap { snapshots[$0]?.state }
            if stepStates.contains(.awaitingApproval) {
                snapshots[id] = snap.with(state: .awaitingApproval)
            }
        }
        for (id, snap) in snapshots where snap.kind == .goal && !snap.state.isTerminal {
            let runSnaps = (children[id] ?? []).compactMap { snapshots[$0] }
            let states = runSnaps.map(\.state)
            let derived: LifecycleState
            if states.contains(.awaitingApproval) {
                derived = .awaitingApproval
            } else if !runSnaps.isEmpty {
                derived = .running
            } else {
                derived = .pending
            }
            snapshots[id] = snap.with(state: derived)
        }
    }

    func snapshot(_ id: UUID) -> AggregateSnapshot? { snapshots[id] }

    func hasLiveChildren(_ id: UUID) -> Bool {
        (children[id] ?? []).contains { snapshots[$0]?.state.isTerminal == false }
    }

    func eventMatching(
        type: String,
        key: String,
        goalID: UUID? = nil,
        runID: UUID? = nil
    ) -> CommittedEvent? {
        existing.first { event in
            guard event.eventType == type else { return false }
            let payload = event.lifecyclePayload()
            guard payload?.idempotencyKey == key else { return false }
            if let goalID, payload?.goalID != goalID { return false }
            if let runID, payload?.runID != runID { return false }
            return true
        }
    }

    func hasKey(id: UUID, type: String, key: String) -> Bool {
        existing.contains { event in
            event.aggregateID == id
                && event.eventType == type
                && event.lifecyclePayload()?.idempotencyKey == key
        }
    }

    mutating func append(
        id: UUID,
        kind: AggregateKind,
        type: String,
        payload: LifecyclePayload,
        provenance: EventProvenance? = nil
    ) throws {
        let data = try LifecycleJSON.encoder().encode(payload)
        pending.append(
            PendingEvent(
                aggregateKind: kind,
                aggregateID: id,
                eventType: type,
                payloadSchemaVersion: 1,
                provenance: provenance ?? EventProvenance(producer: LifecycleProducer.runtime),
                payload: data
            )
        )
        applyLocal(id: id, kind: kind, type: type, payload: payload)
    }

    mutating func applyLocal(
        id: UUID,
        kind: AggregateKind,
        type: String,
        payload: LifecyclePayload
    ) {
        var record = Own(kind: kind)
        if let existing = snapshots[id] {
            record.state = existing.state
            record.parentID = existing.parentID
            record.title = existing.title
            record.stepKind = existing.stepKind
            record.deadline = existing.deadline
            record.reason = existing.reason
        }
        record.apply(
            type: type,
            payload: payload,
            kind: kind
        )
        snapshots[id] = record.snapshot(id: id)
        if let parent = record.parentID {
            if children[parent]?.contains(id) != true {
                children[parent, default: []].append(id)
            }
        }
        deriveParents()
    }

    mutating func failDownAndUp(_ id: UUID, reason: String, idempotencyKey: String? = nil) throws {
        try terminateDownAndUp(id, state: .failed, reason: reason, idempotencyKey: idempotencyKey)
    }

    mutating func cancelDownAndUp(_ id: UUID, reason: String?, idempotencyKey: String? = nil) throws {
        try terminateDownAndUp(id, state: .cancelled, reason: reason, idempotencyKey: idempotencyKey)
    }

    mutating func terminateDownAndUp(
        _ id: UUID,
        state: LifecycleState,
        reason: String?,
        idempotencyKey: String?
    ) throws {
        func terminate(_ target: UUID) throws {
            guard let snap = snapshots[target], !snap.state.isTerminal else { return }
            for child in children[target] ?? [] {
                try terminate(child)
            }
            guard let current = snapshots[target], !current.state.isTerminal else { return }
            try append(
                id: target,
                kind: current.kind,
                type: eventType(kind: current.kind, state: state),
                payload: LifecyclePayload(idempotencyKey: idempotencyKey, reason: reason)
            )
        }
        try terminate(id)
        var parent = snapshots[id]?.parentID
        while let p = parent {
            if hasLiveChildren(p) { break }
            guard let snap = snapshots[p], !snap.state.isTerminal else { break }
            try append(
                id: p,
                kind: snap.kind,
                type: eventType(kind: snap.kind, state: state),
                payload: LifecyclePayload(idempotencyKey: idempotencyKey, reason: reason)
            )
            parent = snapshots[p]?.parentID
        }
    }

    mutating func applyTimeouts(now: Date) throws {
        let expired = snapshots.values.filter { snap in
            guard !snap.state.isTerminal, let deadline = snap.deadline else { return false }
            return deadline <= now
        }
        for snap in expired {
            if snapshots[snap.id]?.state.isTerminal == true { continue }
            try failDownAndUp(snap.id, reason: LifecycleReason.timedOut)
        }
    }

    func eventType(kind: AggregateKind, state: LifecycleState) -> String {
        lifecycleTerminalEventType(kind: kind, state: state)
    }

    func commit(to ledger: EventLedger) throws {
        guard !pending.isEmpty else { return }
        _ = try ledger.append(pending)
    }
}

private extension CommittedEvent {
    func lifecyclePayload() -> LifecyclePayload? {
        try? decodedPayload(as: LifecyclePayload.self, decoder: LifecycleJSON.decoder())
    }
}

private struct Own {
    var kind: AggregateKind
    var state: LifecycleState = .pending
    var parentID: UUID?
    var title: String?
    var stepKind: String?
    var deadline: Date?
    var reason: String?

    mutating func apply(_ event: CommittedEvent) {
        let payload = (try? event.decodedPayload(
            as: LifecyclePayload.self,
            decoder: LifecycleJSON.decoder()
        )) ?? LifecyclePayload()
        apply(type: event.eventType, payload: payload, kind: event.aggregateKind)
    }

    mutating func apply(type: String, payload: LifecyclePayload, kind: AggregateKind) {
        self.kind = kind
        if let title = payload.title { self.title = title }
        if let kindName = payload.kind { self.stepKind = kindName }
        if let deadline = payload.deadlineAt { self.deadline = deadline }
        if let reason = payload.reason { self.reason = reason }
        if let goalID = payload.goalID { self.parentID = goalID }
        if let runID = payload.runID { self.parentID = runID }

        switch type {
        case LifecycleEventType.goalCreated,
             LifecycleEventType.runCreated,
             LifecycleEventType.stepCreated:
            state = .pending
        case LifecycleEventType.runStarted, LifecycleEventType.stepStarted,
             LifecycleEventType.stepApproved:
            state = .running
        case LifecycleEventType.stepAwaitingApproval:
            state = .awaitingApproval
        case LifecycleEventType.goalSucceeded,
             LifecycleEventType.runSucceeded,
             LifecycleEventType.stepSucceeded:
            state = .succeeded
        case LifecycleEventType.goalFailed,
             LifecycleEventType.runFailed,
             LifecycleEventType.stepFailed:
            state = .failed
        case LifecycleEventType.goalCancelled,
             LifecycleEventType.runCancelled,
             LifecycleEventType.stepCancelled:
            state = .cancelled
        default:
            break
        }
    }

    func snapshot(id: UUID) -> AggregateSnapshot {
        AggregateSnapshot(
            id: id,
            kind: kind,
            state: state,
            parentID: parentID,
            title: title,
            stepKind: stepKind,
            deadline: deadline,
            reason: reason
        )
    }
}

private extension AggregateSnapshot {
    func with(state: LifecycleState) -> AggregateSnapshot {
        AggregateSnapshot(
            id: id,
            kind: kind,
            state: state,
            parentID: parentID,
            title: title,
            stepKind: stepKind,
            deadline: deadline,
            reason: reason
        )
    }
}
