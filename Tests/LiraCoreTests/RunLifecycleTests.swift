import Dispatch
import XCTest
@testable import LiraCore

/// Goal/run/step lifecycle (#35). Every assertion reads the ledger — the
/// primary test seam — not an in-memory cache.
final class RunLifecycleCreationTests: XCTestCase {
    func testCreateGoalPersistsPendingEvent() throws {
        let (ledger, lifecycle) = try makeLifecycle()

        let goalID = try lifecycle.createGoal(title: "File taxes")

        let events = try ledger.events(forAggregateID: goalID)
        XCTAssertEqual(events.map(\.eventType), [LifecycleEventType.goalCreated])
        XCTAssertEqual(events[0].aggregateKind, .goal)
        XCTAssertEqual(events[0].payloadSchemaVersion, 1)
        XCTAssertEqual(events[0].provenance.producer, LifecycleProducer.runtime)
        let payload = try events[0].decodedPayload(as: LifecyclePayload.self)
        XCTAssertEqual(payload.title, "File taxes")

        let snap = try XCTUnwrap(lifecycle.snapshot(goalID))
        XCTAssertEqual(snap.state, .pending)
        XCTAssertEqual(snap.kind, .goal)
        XCTAssertEqual(snap.title, "File taxes")
    }

    func testCreateRunAndStepPersistParentLinks() throws {
        let (ledger, lifecycle) = try makeLifecycle()
        let goalID = try lifecycle.createGoal(title: "Goal")
        let runID = try lifecycle.createRun(goalID: goalID)
        let stepID = try lifecycle.createStep(runID: runID, kind: "model_turn")

        let runPayload = try ledger.events(forAggregateID: runID)[0]
            .decodedPayload(as: LifecyclePayload.self)
        XCTAssertEqual(runPayload.goalID, goalID)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(runID)).state, .pending)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(runID)).parentID, goalID)

        let stepPayload = try ledger.events(forAggregateID: stepID)[0]
            .decodedPayload(as: LifecyclePayload.self)
        XCTAssertEqual(stepPayload.runID, runID)
        XCTAssertEqual(stepPayload.kind, "model_turn")
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(stepID)).state, .pending)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(stepID)).parentID, runID)
    }

    func testCreateRunOnUnknownGoalFailsWithoutWriting() throws {
        let (ledger, lifecycle) = try makeLifecycle()
        XCTAssertThrowsError(try lifecycle.createRun(goalID: UUID())) { error in
            XCTAssertEqual(error as? LifecycleError, .unknownAggregate)
        }
        XCTAssertEqual(try ledger.allEvents(), [])
    }

    func testEmptyTitleIsRejected() throws {
        let (ledger, lifecycle) = try makeLifecycle()
        XCTAssertThrowsError(try lifecycle.createGoal(title: "   ")) { error in
            XCTAssertEqual(error as? LifecycleError, .invalidTitle)
        }
        XCTAssertEqual(try ledger.allEvents(), [])
    }

    func testOverlongTitleIsRejected() throws {
        let (ledger, lifecycle) = try makeLifecycle()
        let title = String(repeating: "a", count: LifecycleLimits.maxTitleLength + 1)
        XCTAssertThrowsError(try lifecycle.createGoal(title: title)) { error in
            XCTAssertEqual(
                error as? LifecycleError,
                .fieldTooLong(field: "title", max: LifecycleLimits.maxTitleLength)
            )
        }
        XCTAssertEqual(try ledger.allEvents(), [])
    }
}

final class RunLifecycleTransitionTests: XCTestCase {
    func testStartWalksPendingToRunning() throws {
        let (ledger, lifecycle) = try makeLifecycle()
        let ids = try openPendingStep(lifecycle)

        try lifecycle.start(ids.run)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(ids.run)).state, .running)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(ids.goal)).state, .running)
        XCTAssertEqual(
            try ledger.events(forAggregateID: ids.run).map(\.eventType),
            [LifecycleEventType.runCreated, LifecycleEventType.runStarted]
        )
        // Goal liveness is projected from children — no goal.started event.
        XCTAssertEqual(
            try ledger.events(forAggregateID: ids.goal).map(\.eventType),
            [LifecycleEventType.goalCreated]
        )

        try lifecycle.start(ids.step)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(ids.step)).state, .running)
        XCTAssertEqual(
            try ledger.events(forAggregateID: ids.step).map(\.eventType),
            [LifecycleEventType.stepCreated, LifecycleEventType.stepStarted]
        )
    }

    func testStartOnAGoalIsRejected() throws {
        let (_, lifecycle) = try makeLifecycle()
        let goalID = try lifecycle.createGoal(title: "G")
        XCTAssertThrowsError(try lifecycle.start(goalID)) { error in
            XCTAssertEqual(error as? LifecycleError, .cannotStart(.goal))
        }
    }

    func testSucceedAPendingGoalThrowsAndWritesNothing() throws {
        let (ledger, lifecycle) = try makeLifecycle()
        let goalID = try lifecycle.createGoal(title: "G")
        XCTAssertThrowsError(try lifecycle.succeed(goalID)) { error in
            guard case let LifecycleError.illegalTransition(from, to) = error else {
                return XCTFail("expected illegalTransition, got \(error)")
            }
            XCTAssertEqual(from, .pending)
            XCTAssertEqual(to, .succeeded)
        }
        XCTAssertEqual(
            try ledger.events(forAggregateID: goalID).map(\.eventType),
            [LifecycleEventType.goalCreated]
        )
    }

    func testSucceedRequiresChildrenToBeTerminal() throws {
        let (ledger, lifecycle) = try makeLifecycle()
        let ids = try openRunningStep(lifecycle)
        XCTAssertThrowsError(try lifecycle.succeed(ids.run)) { error in
            XCTAssertEqual(error as? LifecycleError, .hasNonTerminalChildren)
        }
        XCTAssertFalse(
            try ledger.events(forAggregateID: ids.run)
                .contains { $0.eventType == LifecycleEventType.runSucceeded }
        )
    }

    func testExplicitSucceedAtEachLevel() throws {
        let (ledger, lifecycle) = try makeLifecycle()
        let ids = try openRunningStep(lifecycle)

        try lifecycle.succeed(ids.step)
        try lifecycle.succeed(ids.run)
        try lifecycle.succeed(ids.goal)

        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(ids.step)).state, .succeeded)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(ids.run)).state, .succeeded)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(ids.goal)).state, .succeeded)
        XCTAssertEqual(
            try ledger.events(forAggregateID: ids.step).last?.eventType,
            LifecycleEventType.stepSucceeded
        )
        XCTAssertEqual(
            try ledger.events(forAggregateID: ids.run).last?.eventType,
            LifecycleEventType.runSucceeded
        )
        XCTAssertEqual(
            try ledger.events(forAggregateID: ids.goal).last?.eventType,
            LifecycleEventType.goalSucceeded
        )
    }

    func testSecondStartWithoutKeyIsRejected() throws {
        let (ledger, lifecycle) = try makeLifecycle()
        let ids = try openPendingStep(lifecycle)
        try lifecycle.start(ids.run)
        XCTAssertThrowsError(try lifecycle.start(ids.run)) { error in
            guard case let LifecycleError.illegalTransition(from, to) = error else {
                return XCTFail("expected illegalTransition, got \(error)")
            }
            XCTAssertEqual(from, .running)
            XCTAssertEqual(to, .running)
        }
        XCTAssertEqual(
            try ledger.events(forAggregateID: ids.run).filter {
                $0.eventType == LifecycleEventType.runStarted
            }.count,
            1
        )
    }

    func testStartWhileAwaitingApprovalIsRejected() throws {
        let (ledger, lifecycle) = try makeLifecycle()
        let ids = try openRunningStep(lifecycle)
        try lifecycle.recordToolCall(
            stepID: ids.step, tool: "mail.send", requiresApproval: true
        )
        XCTAssertThrowsError(try lifecycle.start(ids.step)) { error in
            guard case let LifecycleError.illegalTransition(from, to) = error else {
                return XCTFail("expected illegalTransition, got \(error)")
            }
            XCTAssertEqual(from, .awaitingApproval)
            XCTAssertEqual(to, .running)
        }
        XCTAssertEqual(
            try ledger.events(forAggregateID: ids.step).filter {
                $0.eventType == LifecycleEventType.stepStarted
            }.count,
            1
        )
    }

    func testStartOfSucceededRunThrows() throws {
        let (_, lifecycle) = try makeLifecycle()
        let ids = try openRunningStep(lifecycle)
        try lifecycle.succeed(ids.step)
        try lifecycle.succeed(ids.run)
        XCTAssertThrowsError(try lifecycle.start(ids.run)) { error in
            guard case let LifecycleError.illegalTransition(from, to) = error else {
                return XCTFail("expected illegalTransition, got \(error)")
            }
            XCTAssertEqual(from, .succeeded)
            XCTAssertEqual(to, .running)
        }
    }
}

final class RunLifecycleCascadeTests: XCTestCase {
    func testCancelRunCascadesToInFlightStepAndZombieGoal() throws {
        let (ledger, lifecycle) = try makeLifecycle()
        let ids = try openRunningStep(lifecycle)

        try lifecycle.cancel(ids.run)

        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(ids.step)).state, .cancelled)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(ids.run)).state, .cancelled)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(ids.goal)).state, .cancelled)
        XCTAssertEqual(
            try ledger.events(forAggregateID: ids.step).last?.eventType,
            LifecycleEventType.stepCancelled
        )
        XCTAssertEqual(
            try ledger.events(forAggregateID: ids.goal).last?.eventType,
            LifecycleEventType.goalCancelled
        )
    }

    func testTwoInstancesCannotCommitContradictoryTerminals() throws {
        // Repeat: macOS flock is process-wide, so a single lucky pass can
        // hide two in-process instances racing past LOCK_EX.
        for round in 1...25 {
            let url = TestSupport.makeTemporaryDatabaseURL()
            let ledger = try EventLedger(databaseURL: url)
            let setup = RunLifecycle(ledger: ledger)
            let goal = try setup.createGoal(title: "G")
            let run = try setup.createRun(goalID: goal)
            try setup.start(run)

            let left = RunLifecycle(ledger: try EventLedger(databaseURL: url))
            let right = RunLifecycle(ledger: try EventLedger(databaseURL: url))
            let ready = DispatchGroup()
            ready.enter()
            ready.enter()
            let start = DispatchSemaphore(value: 0)
            let queue = DispatchQueue(label: "lira.lifecycle.race.\(round)", attributes: .concurrent)
            queue.async {
                ready.leave()
                start.wait()
                try? left.succeed(run)
            }
            queue.async {
                ready.leave()
                start.wait()
                try? right.cancel(run)
            }
            ready.wait()
            start.signal()
            start.signal()
            queue.sync(flags: .barrier) {}

            let terminals = try ledger.events(forAggregateID: run).map(\.eventType).filter {
                $0 == LifecycleEventType.runSucceeded || $0 == LifecycleEventType.runCancelled
            }
            XCTAssertEqual(terminals.count, 1, "round \(round) absorbing terminal: \(terminals)")
            let snap = try XCTUnwrap(RunLifecycle(ledger: ledger).snapshot(run))
            XCTAssertTrue(snap.state.isTerminal)
        }
    }

    func testSymlinkAliasCannotBypassLifecycleLock() throws {
        for round in 1...25 {
            let real = TestSupport.makeTemporaryDatabaseURL()
            let realLedger = try EventLedger(databaseURL: real)
            let setup = RunLifecycle(ledger: realLedger)
            let goal = try setup.createGoal(title: "G")
            let run = try setup.createRun(goalID: goal)
            try setup.start(run)

            let aliasDir = real.deletingLastPathComponent()
                .appendingPathComponent("alias-\(round)", isDirectory: true)
            try FileManager.default.createDirectory(at: aliasDir, withIntermediateDirectories: true)
            let alias = aliasDir.appendingPathComponent("ledger.sqlite")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)

            let left = RunLifecycle(ledger: try EventLedger(databaseURL: real))
            let right = RunLifecycle(ledger: try EventLedger(databaseURL: alias))
            let ready = DispatchGroup()
            ready.enter()
            ready.enter()
            let start = DispatchSemaphore(value: 0)
            let queue = DispatchQueue(label: "lira.lifecycle.alias.\(round)", attributes: .concurrent)
            queue.async {
                ready.leave()
                start.wait()
                try? left.succeed(run)
            }
            queue.async {
                ready.leave()
                start.wait()
                try? right.cancel(run)
            }
            ready.wait()
            start.signal()
            start.signal()
            queue.sync(flags: .barrier) {}

            let terminals = try realLedger.events(forAggregateID: run).map(\.eventType).filter {
                $0 == LifecycleEventType.runSucceeded || $0 == LifecycleEventType.runCancelled
            }
            XCTAssertEqual(
                terminals.count, 1,
                "round \(round) alias bypass: \(terminals)"
            )
        }
    }

    func testCancelOneRunWithSiblingPendingDoesNotCancelGoal() throws {
        let (ledger, lifecycle) = try makeLifecycle()
        let goalID = try lifecycle.createGoal(title: "G")
        let runA = try lifecycle.createRun(goalID: goalID)
        let runB = try lifecycle.createRun(goalID: goalID)
        try lifecycle.start(runA)

        try lifecycle.cancel(runA)

        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(runA)).state, .cancelled)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(runB)).state, .pending)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(goalID)).state, .running)
        XCTAssertFalse(
            try ledger.events(forAggregateID: goalID)
                .contains { $0.eventType == LifecycleEventType.goalCancelled }
        )
    }

    func testFailStepCascadesWhenItIsTheOnlyLiveChild() throws {
        let (ledger, lifecycle) = try makeLifecycle()
        let ids = try openRunningStep(lifecycle)
        try lifecycle.fail(ids.step, reason: "model_error")
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(ids.step)).state, .failed)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(ids.run)).state, .failed)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(ids.goal)).state, .failed)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(ids.step)).reason, "model_error")
        XCTAssertEqual(
            try ledger.events(forAggregateID: ids.step).last?.eventType,
            LifecycleEventType.stepFailed
        )
        XCTAssertEqual(
            try ledger.events(forAggregateID: ids.run).last?.eventType,
            LifecycleEventType.runFailed
        )
        XCTAssertEqual(
            try ledger.events(forAggregateID: ids.goal).last?.eventType,
            LifecycleEventType.goalFailed
        )
    }
}

final class RunLifecycleTurnLoopTests: XCTestCase {
    func testModelThenToolThenResultStayRunning() throws {
        let (ledger, lifecycle) = try makeLifecycle()
        let ids = try openRunningStep(lifecycle)

        try lifecycle.recordModelCall(stepID: ids.step)
        try lifecycle.recordToolCall(stepID: ids.step, tool: "fs.write", requiresApproval: false)
        try lifecycle.recordToolResult(stepID: ids.step, tool: "fs.write", outcome: "ok")

        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(ids.step)).state, .running)
        XCTAssertEqual(
            try ledger.events(forAggregateID: ids.step).map(\.eventType),
            [
                LifecycleEventType.stepCreated,
                LifecycleEventType.stepStarted,
                LifecycleEventType.stepModelCalled,
                LifecycleEventType.stepToolCalled,
                LifecycleEventType.stepToolResult,
            ]
        )
        // Parents do not get their own awaiting/running events for the turn loop.
        XCTAssertEqual(
            try ledger.events(forAggregateID: ids.run).map(\.eventType),
            [LifecycleEventType.runCreated, LifecycleEventType.runStarted]
        )
    }

    func testToolCallRequiringApprovalWaitsAndApproveResumes() throws {
        let (ledger, lifecycle) = try makeLifecycle()
        let ids = try openRunningStep(lifecycle)

        try lifecycle.recordToolCall(
            stepID: ids.step,
            tool: "mail.send",
            requiresApproval: true
        )

        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(ids.step)).state, .awaitingApproval)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(ids.run)).state, .awaitingApproval)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(ids.goal)).state, .awaitingApproval)
        XCTAssertEqual(
            try ledger.events(forAggregateID: ids.step).map(\.eventType).suffix(2).map { $0 },
            [LifecycleEventType.stepToolCalled, LifecycleEventType.stepAwaitingApproval]
        )
        XCTAssertFalse(
            try ledger.events(forAggregateID: ids.run)
                .contains { $0.eventType.contains("awaiting") }
        )

        try lifecycle.approve(stepID: ids.step)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(ids.step)).state, .running)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(ids.run)).state, .running)
        XCTAssertEqual(
            try ledger.events(forAggregateID: ids.step).last?.eventType,
            LifecycleEventType.stepApproved
        )

        try lifecycle.recordToolResult(stepID: ids.step, tool: "mail.send", outcome: "sent")
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(ids.step)).state, .running)
    }

    func testDenyFailsTheStep() throws {
        let (ledger, lifecycle) = try makeLifecycle()
        let ids = try openRunningStep(lifecycle)
        try lifecycle.recordToolCall(
            stepID: ids.step,
            tool: "mail.send",
            requiresApproval: true
        )
        try lifecycle.deny(stepID: ids.step)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(ids.step)).state, .failed)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(ids.step)).reason, LifecycleReason.denied)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(ids.run)).state, .failed)
        XCTAssertEqual(
            try ledger.events(forAggregateID: ids.step).last?.eventType,
            LifecycleEventType.stepFailed
        )
        let payload = try XCTUnwrap(ledger.events(forAggregateID: ids.step).last)
            .decodedPayload(as: LifecyclePayload.self, decoder: LifecycleJSON.decoder())
        XCTAssertEqual(payload.reason, LifecycleReason.denied)
    }

    func testToolResultWithoutACallIsRejected() throws {
        let (ledger, lifecycle) = try makeLifecycle()
        let ids = try openRunningStep(lifecycle)
        XCTAssertThrowsError(
            try lifecycle.recordToolResult(stepID: ids.step, tool: "mail.send", outcome: "sent")
        ) { error in
            XCTAssertEqual(error as? LifecycleError, .unmatchedToolResult)
        }
        XCTAssertFalse(
            try ledger.events(forAggregateID: ids.step)
                .contains { $0.eventType == LifecycleEventType.stepToolResult }
        )
    }

    func testDenyOnARunningStepIsRejected() throws {
        let (ledger, lifecycle) = try makeLifecycle()
        let ids = try openRunningStep(lifecycle)
        XCTAssertThrowsError(try lifecycle.deny(stepID: ids.step))
        XCTAssertFalse(
            try ledger.events(forAggregateID: ids.step)
                .contains { $0.eventType == LifecycleEventType.stepFailed }
        )
    }

    func testRecordModelCallOnPendingStepThrows() throws {
        let (ledger, lifecycle) = try makeLifecycle()
        let ids = try openPendingStep(lifecycle)
        XCTAssertThrowsError(try lifecycle.recordModelCall(stepID: ids.step))
        XCTAssertEqual(
            try ledger.events(forAggregateID: ids.step).map(\.eventType),
            [LifecycleEventType.stepCreated]
        )
    }
}

final class RunLifecycleTimeoutTests: XCTestCase {
    func testCrossedDeadlineFailsWithTimedOut() throws {
        let clock = TestClock()
        let (ledger, lifecycle) = try makeLifecycle(clock: clock)
        let deadline = clock.now.addingTimeInterval(10)
        let goalID = try lifecycle.createGoal(title: "G", deadline: deadline)
        let runID = try lifecycle.createRun(goalID: goalID, deadline: deadline)
        try lifecycle.start(runID)

        clock.advance(by: 11)
        // Next command observes the crossed deadline. No background timer.
        _ = try lifecycle.createGoal(title: "unrelated")

        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(runID)).state, .failed)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(runID)).reason, LifecycleReason.timedOut)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(goalID)).state, .failed)
        XCTAssertEqual(
            try ledger.events(forAggregateID: runID).last?.eventType,
            LifecycleEventType.runFailed
        )
    }

    func testThrowingCommandAfterDeadlineStillPersistsTimeout() throws {
        let clock = TestClock()
        let (ledger, lifecycle) = try makeLifecycle(clock: clock)
        let deadline = clock.now.addingTimeInterval(10)
        let goalID = try lifecycle.createGoal(title: "deadline", deadline: deadline)
        let runID = try lifecycle.createRun(goalID: goalID, deadline: deadline)
        try lifecycle.start(runID)
        let stepID = try lifecycle.createStep(runID: runID, kind: "model_turn", deadline: deadline)
        try lifecycle.start(stepID)
        try lifecycle.recordModelCall(stepID: stepID)
        clock.advance(by: 11)

        XCTAssertThrowsError(
            try lifecycle.recordToolCall(
                stepID: stepID, tool: "fs.write", requiresApproval: false
            )
        )
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(stepID)).state, .failed)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(stepID)).reason, LifecycleReason.timedOut)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(runID)).state, .failed)
        XCTAssertEqual(
            try ledger.events(forAggregateID: runID).last?.eventType,
            LifecycleEventType.runFailed
        )
    }

    func testCancelEndsInTerminalState() throws {
        let (ledger, lifecycle) = try makeLifecycle()
        let ids = try openRunningStep(lifecycle)
        try lifecycle.cancel(ids.goal)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(ids.goal)).state, .cancelled)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(ids.run)).state, .cancelled)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(ids.step)).state, .cancelled)
        XCTAssertEqual(
            try ledger.events(forAggregateID: ids.goal).last?.eventType,
            LifecycleEventType.goalCancelled
        )
        XCTAssertEqual(
            try ledger.events(forAggregateID: ids.run).last?.eventType,
            LifecycleEventType.runCancelled
        )
        XCTAssertEqual(
            try ledger.events(forAggregateID: ids.step).last?.eventType,
            LifecycleEventType.stepCancelled
        )
    }
}

final class RunLifecycleIdempotencyTests: XCTestCase {
    func testCreateGoalReplaysTheSameKeyWithoutASecondEvent() throws {
        let (ledger, lifecycle) = try makeLifecycle()
        let first = try lifecycle.createGoal(title: "G", idempotencyKey: "create-g")
        let second = try lifecycle.createGoal(title: "G", idempotencyKey: "create-g")
        XCTAssertEqual(first, second)
        XCTAssertEqual(try ledger.allEvents().count, 1)
    }

    func testCreateRunKeyIsScopedToTheParentGoal() throws {
        let (ledger, lifecycle) = try makeLifecycle()
        let goalA = try lifecycle.createGoal(title: "A")
        let goalB = try lifecycle.createGoal(title: "B")
        let runA = try lifecycle.createRun(goalID: goalA, idempotencyKey: "shared")
        let runB = try lifecycle.createRun(goalID: goalB, idempotencyKey: "shared")
        XCTAssertNotEqual(runA, runB)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(runA)).parentID, goalA)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(runB)).parentID, goalB)
        XCTAssertEqual(
            try ledger.allEvents().filter { $0.eventType == LifecycleEventType.runCreated }.count,
            2
        )
        let replay = try lifecycle.createRun(goalID: goalA, idempotencyKey: "shared")
        XCTAssertEqual(replay, runA)
        XCTAssertEqual(
            try ledger.allEvents().filter { $0.eventType == LifecycleEventType.runCreated }.count,
            2
        )
    }

    func testCreateStepKeyIsScopedToTheParentRun() throws {
        let (ledger, lifecycle) = try makeLifecycle()
        let goal = try lifecycle.createGoal(title: "G")
        let runA = try lifecycle.createRun(goalID: goal)
        let runB = try lifecycle.createRun(goalID: goal)
        let stepA = try lifecycle.createStep(runID: runA, kind: "model_turn", idempotencyKey: "shared")
        let stepB = try lifecycle.createStep(runID: runB, kind: "model_turn", idempotencyKey: "shared")
        XCTAssertNotEqual(stepA, stepB)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(stepA)).parentID, runA)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(stepB)).parentID, runB)
        let replay = try lifecycle.createStep(runID: runA, kind: "model_turn", idempotencyKey: "shared")
        XCTAssertEqual(replay, stepA)
        XCTAssertEqual(
            try ledger.allEvents().filter { $0.eventType == LifecycleEventType.stepCreated }.count,
            2
        )
    }

    func testStartReplaysTheSameKey() throws {
        let (ledger, lifecycle) = try makeLifecycle()
        let ids = try openPendingStep(lifecycle)
        try lifecycle.start(ids.run, idempotencyKey: "start-run")
        try lifecycle.start(ids.run, idempotencyKey: "start-run")
        XCTAssertEqual(
            try ledger.events(forAggregateID: ids.run).filter {
                $0.eventType == LifecycleEventType.runStarted
            }.count,
            1
        )
    }
}

final class RunLifecycleInProcessReconciliationTests: XCTestCase {
    func testReconcileFailsARunningStepAsInterrupted() throws {
        let url = TestSupport.makeTemporaryDatabaseURL()
        let ledger = try EventLedger(databaseURL: url)
        let original = RunLifecycle(ledger: ledger)
        let ids = try openRunningStep(original)
        try original.recordModelCall(stepID: ids.step)

        // Process death: drop the in-memory object. Ledger is the authority.
        let relaunched = RunLifecycle(ledger: try EventLedger(databaseURL: url))
        XCTAssertEqual(
            try XCTUnwrap(relaunched.snapshot(ids.step)).state,
            .running,
            "init must not reconcile as a side effect"
        )

        let report = try relaunched.reconcile()
        XCTAssertTrue(report.interrupted.contains(ids.step))
        XCTAssertEqual(try XCTUnwrap(relaunched.snapshot(ids.step)).state, .failed)
        XCTAssertEqual(try XCTUnwrap(relaunched.snapshot(ids.step)).reason, LifecycleReason.interrupted)
        XCTAssertEqual(try XCTUnwrap(relaunched.snapshot(ids.run)).state, .failed)
        XCTAssertEqual(try XCTUnwrap(relaunched.snapshot(ids.goal)).state, .failed)

        let before = try ledger.allEvents().map(\.eventID)
        let second = try relaunched.reconcile()
        XCTAssertEqual(second.interrupted, [])
        XCTAssertEqual(try ledger.allEvents().map(\.eventID), before)
    }

    func testReconcileResumesAwaitingApproval() throws {
        let url = TestSupport.makeTemporaryDatabaseURL()
        let ledger = try EventLedger(databaseURL: url)
        let original = RunLifecycle(ledger: ledger)
        let ids = try openRunningStep(original)
        try original.recordToolCall(
            stepID: ids.step,
            tool: "mail.send",
            requiresApproval: true
        )
        let before = try ledger.allEvents().map(\.eventID)

        let relaunched = RunLifecycle(ledger: try EventLedger(databaseURL: url))
        _ = try relaunched.reconcile()
        XCTAssertEqual(try ledger.allEvents().map(\.eventID), before)
        XCTAssertEqual(try XCTUnwrap(relaunched.snapshot(ids.step)).state, .awaitingApproval)
        XCTAssertEqual(try XCTUnwrap(relaunched.snapshot(ids.run)).state, .awaitingApproval)

        try relaunched.approve(stepID: ids.step)
        XCTAssertEqual(try XCTUnwrap(relaunched.snapshot(ids.step)).state, .running)
        XCTAssertEqual(
            try ledger.events(forAggregateID: ids.step).last?.eventType,
            LifecycleEventType.stepApproved
        )
    }

    func testReconcileResumesPending() throws {
        let url = TestSupport.makeTemporaryDatabaseURL()
        let ledger = try EventLedger(databaseURL: url)
        let original = RunLifecycle(ledger: ledger)
        let goalID = try original.createGoal(title: "G")
        let runID = try original.createRun(goalID: goalID)
        let before = try ledger.allEvents().map(\.eventID)

        let relaunched = RunLifecycle(ledger: try EventLedger(databaseURL: url))
        let report = try relaunched.reconcile()
        XCTAssertEqual(try ledger.allEvents().map(\.eventID), before)
        XCTAssertTrue(report.resumed.contains(goalID))
        XCTAssertTrue(report.resumed.contains(runID))
        XCTAssertEqual(try XCTUnwrap(relaunched.snapshot(runID)).state, .pending)
        try relaunched.start(runID)
        XCTAssertEqual(try XCTUnwrap(relaunched.snapshot(runID)).state, .running)
        XCTAssertEqual(
            try ledger.events(forAggregateID: runID).last?.eventType,
            LifecycleEventType.runStarted
        )
    }
}

final class RunLifecycleSoleWriterTests: XCTestCase {
    func testOnlyRunLifecycleWritesGoalRunStepAggregates() throws {
        let liraCore = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LiraCore")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: liraCore.path),
            "expected LiraCore sources at \(liraCore.path)"
        )

        var hits: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: liraCore,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let relative = url.path.replacingOccurrences(of: liraCore.path + "/", with: "")
            if relative.hasPrefix("RunLifecycle/") { continue }
            if url.lastPathComponent == "DomainEvent.swift" { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if trimmed.contains("aggregateKind: .goal")
                    || trimmed.contains("aggregateKind: .run")
                    || trimmed.contains("aggregateKind: .step")
                    || trimmed.contains("aggregateKind:.goal")
                    || trimmed.contains("aggregateKind:.run")
                    || trimmed.contains("aggregateKind:.step")
                {
                    hits.append("\(relative):\(index + 1): \(trimmed)")
                }
            }
        }
        XCTAssertEqual(
            hits, [],
            "only RunLifecycle may write goal/run/step aggregates: \(hits)"
        )
    }
}

// MARK: - Harness

private struct IDs {
    let goal: UUID
    let run: UUID
    let step: UUID
}

private func makeLifecycle(
    clock: LifecycleClock = SystemClock(),
    function: String = #function
) throws -> (EventLedger, RunLifecycle) {
    let ledger = try EventLedger(
        databaseURL: TestSupport.makeTemporaryDatabaseURL(function: function)
    )
    return (ledger, RunLifecycle(ledger: ledger, clock: clock))
}

private func openPendingStep(_ lifecycle: RunLifecycle) throws -> IDs {
    let goal = try lifecycle.createGoal(title: "G")
    let run = try lifecycle.createRun(goalID: goal)
    let step = try lifecycle.createStep(runID: run, kind: "model_turn")
    return IDs(goal: goal, run: run, step: step)
}

private func openRunningStep(_ lifecycle: RunLifecycle) throws -> IDs {
    let ids = try openPendingStep(lifecycle)
    try lifecycle.start(ids.run)
    try lifecycle.start(ids.step)
    return ids
}
