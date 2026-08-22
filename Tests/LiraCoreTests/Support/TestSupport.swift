import Foundation
import GRDB
import XCTest
@testable import LiraCore

/// Shared fixtures and helpers for ledger tests.
enum TestSupport {
    /// A unique, empty directory per call — tests never share database files.
    static func makeTemporaryDatabaseURL(function: String = #function) -> URL {
        let testName = function.prefix(while: { $0 != "(" })
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lira-tests", isDirectory: true)
            .appendingPathComponent("\(testName)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("ledger.sqlite")
    }

    /// Synthetic event whose payload records its intended position
    /// (`{"index": n}`), so survivors of a crash can be checked for
    /// torn or reordered writes.
    static func makeEvent(
        index: Int,
        eventID: UUID = UUID(),
        aggregateKind: AggregateKind = .goal,
        aggregateID: UUID = UUID(),
        eventType: String = "goal.created",
        payloadSchemaVersion: Int = 1,
        occurredAt: Date? = nil,
        provenance: EventProvenance = EventProvenance(producer: "test"),
        payload: Data? = nil
    ) -> PendingEvent {
        let payloadData = payload ?? (try! JSONSerialization.data(
            withJSONObject: ["index": index],
            options: [.sortedKeys]
        ))
        return PendingEvent(
            eventID: eventID,
            aggregateKind: aggregateKind,
            aggregateID: aggregateID,
            eventType: eventType,
            payloadSchemaVersion: payloadSchemaVersion,
            occurredAt: occurredAt ?? Date(),
            provenance: provenance,
            payload: payloadData
        )
    }

    /// Decodable mirror of the probe's synthetic payloads.
    struct ProbePayload: Codable, Equatable {
        let index: Int
    }

    // MARK: - Raw row snapshots

    /// Byte-exact copy of a stored row, read through a plain SQLite
    /// connection. Used to prove migrations never mutate existing events.
    struct RawEventRow: Equatable {
        let sequence: Int64
        let eventID: String
        let aggregateKind: String
        let aggregateID: String
        let eventType: String
        let payloadSchemaVersion: Int64
        let occurredAt: String
        let provenance: String
        let payload: Data
    }

    static func readRawRows(at url: URL) throws -> [RawEventRow] {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM \(LedgerSchema.tableName) ORDER BY sequence ASC"
            ).map { row in
                RawEventRow(
                    sequence: row["sequence"],
                    eventID: row["event_id"],
                    aggregateKind: row["aggregate_kind"],
                    aggregateID: row["aggregate_id"],
                    eventType: row["event_type"],
                    payloadSchemaVersion: row["payload_schema_version"],
                    occurredAt: row["occurred_at"],
                    provenance: row["provenance"],
                    payload: row["payload"]
                )
            }
        }
    }

}

/// Convenience for asserting event order by written position.
extension CommittedEvent {
    var probePayloadIndex: Int? {
        (try? decodedPayload(as: TestSupport.ProbePayload.self))?.index
    }
}

// MARK: - Crash probe locator

enum CrashProbe {
    private final class BundleMarker {}

    /// Locates the `ledger-crash-probe` executable built alongside the test
    /// bundle. Covers the `swift test` layout (`.build/debug/`) and the Xcode
    /// layout (products directory containing both the .xctest bundle and the
    /// executable).
    static func executableURL() throws -> URL {
        let name = "ledger-crash-probe"
        let fileManager = FileManager.default

        var candidates: [URL] = []

        if Bundle(for: BundleMarker.self).bundleURL.pathExtension == "xctest" {
            candidates.append(
                Bundle(for: BundleMarker.self)
                    .bundleURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(name)
            )
        }

        // Walk up from this source file looking for the SwiftPM build dir.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            for configuration in ["debug", "release"] {
                candidates.append(dir.appendingPathComponent(".build/\(configuration)/\(name)"))
                if let entries = try? fileManager.contentsOfDirectory(
                    at: dir.appendingPathComponent(".build"),
                    includingPropertiesForKeys: [.isDirectoryKey]
                ) {
                    for entry in entries where entry.lastPathComponent.contains("apple-macosx") {
                        candidates.append(entry.appendingPathComponent(configuration).appendingPathComponent(name))
                    }
                }
            }
            dir.deleteLastPathComponent()
        }

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw NSError(
            domain: "CrashProbeLocator",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "could not locate '\(name)' executable; looked in:\n\(candidates.map(\.path).joined(separator: "\n"))"]
        )
    }
}
