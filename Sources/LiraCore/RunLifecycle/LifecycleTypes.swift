import Foundation

/// Lifecycle states for goal, run, and step. Timeout is `failed` with
/// reason `timedOut` — not a seventh state.
public enum LifecycleState: String, Codable, Sendable, Equatable {
    case pending
    case running
    case awaitingApproval
    case succeeded
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: true
        case .pending, .running, .awaitingApproval: false
        }
    }
}

/// Frozen v1 event-type strings. Additive only after merge — #36/#37/#41/#42
/// will match these literally. Do not rename.
public enum LifecycleEventType {
    public static let goalCreated = "goal.created"
    public static let goalSucceeded = "goal.succeeded"
    public static let goalFailed = "goal.failed"
    public static let goalCancelled = "goal.cancelled"

    public static let runCreated = "run.created"
    public static let runStarted = "run.started"
    public static let runSucceeded = "run.succeeded"
    public static let runFailed = "run.failed"
    public static let runCancelled = "run.cancelled"

    public static let stepCreated = "step.created"
    public static let stepStarted = "step.started"
    public static let stepModelCalled = "step.model_called"
    public static let stepToolCalled = "step.tool_called"
    public static let stepToolResult = "step.tool_result"
    public static let stepAwaitingApproval = "step.awaiting_approval"
    public static let stepApproved = "step.approved"
    public static let stepSucceeded = "step.succeeded"
    public static let stepFailed = "step.failed"
    public static let stepCancelled = "step.cancelled"
}

public enum LifecycleProducer {
    public static let runtime = "lira.runtime"
}

public enum LifecycleReason {
    public static let timedOut = "timedOut"
    public static let interrupted = "interrupted"
    public static let denied = "denied"
}

public enum LifecycleLimits {
    public static let maxTitleLength = 512
    public static let maxKindLength = 128
    public static let maxReasonLength = 256
    public static let maxToolLength = 128
    public static let maxOutcomeLength = 4096
    public static let maxIdempotencyKeyLength = 128
}

/// Payload schema version 1. Keys are additive and forward-only; existing
/// rows are never reinterpreted.
public struct LifecyclePayload: Codable, Equatable, Sendable {
    public var title: String?
    public var goalID: UUID?
    public var runID: UUID?
    public var kind: String?
    public var deadlineAt: Date?
    public var idempotencyKey: String?
    public var tool: String?
    public var requiresApproval: Bool?
    public var outcome: String?
    public var reason: String?

    public init(
        title: String? = nil,
        goalID: UUID? = nil,
        runID: UUID? = nil,
        kind: String? = nil,
        deadlineAt: Date? = nil,
        idempotencyKey: String? = nil,
        tool: String? = nil,
        requiresApproval: Bool? = nil,
        outcome: String? = nil,
        reason: String? = nil
    ) {
        self.title = title
        self.goalID = goalID
        self.runID = runID
        self.kind = kind
        self.deadlineAt = deadlineAt
        self.idempotencyKey = idempotencyKey
        self.tool = tool
        self.requiresApproval = requiresApproval
        self.outcome = outcome
        self.reason = reason
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(goalID, forKey: .goalID)
        try container.encodeIfPresent(runID, forKey: .runID)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encodeIfPresent(deadlineAt, forKey: .deadlineAt)
        try container.encodeIfPresent(idempotencyKey, forKey: .idempotencyKey)
        try container.encodeIfPresent(tool, forKey: .tool)
        try container.encodeIfPresent(requiresApproval, forKey: .requiresApproval)
        try container.encodeIfPresent(outcome, forKey: .outcome)
        try container.encodeIfPresent(reason, forKey: .reason)
    }
}

public struct AggregateSnapshot: Equatable, Sendable {
    public let id: UUID
    public let kind: AggregateKind
    public let state: LifecycleState
    public let parentID: UUID?
    public let title: String?
    public let stepKind: String?
    public let deadline: Date?
    public let reason: String?
}

public struct ReconciliationReport: Equatable, Sendable {
    /// Aggregates failed with reason `interrupted` this pass.
    public let interrupted: [UUID]
    /// Aggregates failed with reason `timedOut` this pass.
    public let timedOut: [UUID]
    /// Non-terminal aggregates left as-is (`pending` / `awaitingApproval`).
    public let resumed: [UUID]
}

public enum LifecycleError: Error, Equatable {
    case illegalTransition(from: LifecycleState, to: LifecycleState)
    case unknownAggregate
    case parentNotFound
    case parentIsTerminal
    case parentNotRunning
    case hasNonTerminalChildren
    case invalidTitle
    case invalidKind
    case emptyField(String)
    case fieldTooLong(field: String, max: Int)
    case notAStep
    case cannotStart(AggregateKind)
}

func lifecycleTerminalEventType(kind: AggregateKind, state: LifecycleState) -> String {
    switch (kind, state) {
    case (.goal, .succeeded): return LifecycleEventType.goalSucceeded
    case (.goal, .failed): return LifecycleEventType.goalFailed
    case (.goal, .cancelled): return LifecycleEventType.goalCancelled
    case (.run, .succeeded): return LifecycleEventType.runSucceeded
    case (.run, .failed): return LifecycleEventType.runFailed
    case (.run, .cancelled): return LifecycleEventType.runCancelled
    case (.step, .succeeded): return LifecycleEventType.stepSucceeded
    case (.step, .failed): return LifecycleEventType.stepFailed
    case (.step, .cancelled): return LifecycleEventType.stepCancelled
    default: return ""
    }
}

enum LifecycleJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
