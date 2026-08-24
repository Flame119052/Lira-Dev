import Foundation
import LiraCore

// Test-only helper for RunLifecycleReconciliationTests. Never shipped.
//
//   lifecycle-crash-probe <db-path> running|awaiting
//
// Leaves a goal/run/step in-flight, prints READY, then sleeps. SIGKILL on
// READY is a crashed process with durable mid-task state.

let usage = "usage: lifecycle-crash-probe <db-path> running|awaiting"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("[lifecycle-crash-probe] \(message)\n".utf8))
    exit(2)
}

guard CommandLine.arguments.count >= 3 else { fail(usage) }
let databasePath = CommandLine.arguments[1]
let mode = CommandLine.arguments[2]

do {
    let ledger = try EventLedger(databaseURL: URL(fileURLWithPath: databasePath))
    let lifecycle = RunLifecycle(ledger: ledger)
    let goal = try lifecycle.createGoal(title: "probe-goal", idempotencyKey: "probe-goal")
    let run = try lifecycle.createRun(goalID: goal, idempotencyKey: "probe-run")
    try lifecycle.start(run, idempotencyKey: "probe-start-run")
    let step = try lifecycle.createStep(runID: run, kind: "model_turn", idempotencyKey: "probe-step")
    try lifecycle.start(step, idempotencyKey: "probe-start-step")
    switch mode {
    case "running":
        try lifecycle.recordModelCall(stepID: step, idempotencyKey: "probe-model")
    case "awaiting":
        try lifecycle.recordModelCall(stepID: step, idempotencyKey: "probe-model")
        try lifecycle.recordToolCall(
            stepID: step, tool: "mail.send", requiresApproval: true, idempotencyKey: "probe-tool"
        )
    default:
        fail(usage)
    }
    print("READY")
    fflush(stdout)
    while true { sleep(60) }
} catch {
    fail("\(error)")
}
