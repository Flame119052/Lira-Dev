import Darwin
import Foundation

/// Wire constants for the IPC plane. Version is checked in the 6-byte
/// header before any payload is treated as a request.
public enum IPCProtocol {
    public static let currentVersion: UInt8 = 1
    /// Same bound as `EventLedger.maxPayloadBytes` — one runaway helper
    /// cannot balloon a frame without limit.
    public static let maxFramePayloadBytes = 1_048_576
    /// Handshake component names are telemetry plus a claimed identity.
    /// Capped so a rejected peer cannot inflate an `ipc.auth_failed` row
    /// past the ledger payload cap (audit C1).
    public static let maxComponentNameUTF8Count = 128
    /// Pre-auth accept cap. Further connections are closed without a
    /// handler thread or a ledger row.
    public static let maxConcurrentConnections = 16
    /// Sequential rejected handshakes release their slot; this caps how
    /// many `ipc.auth_failed` rows one channel may append inside
    /// `authFailureWindowSeconds` so a drip cannot grow the ledger without
    /// bound. Extra rejections in the window are dropped (not overflow
    /// accepts — those still have no row).
    public static let maxAuthFailureRowsPerWindow = 16
    public static let authFailureWindowSeconds: TimeInterval = 60

    static func clipComponentName(_ raw: String) -> String {
        guard raw.utf8.count > maxComponentNameUTF8Count else { return raw }
        return String(decoding: raw.utf8.prefix(maxComponentNameUTF8Count), as: UTF8.self)
    }
}

enum IPCFrameKind: UInt8, Sendable, Equatable {
    case handshake = 1
    case handshakeAck = 2
    case request = 3
    case response = 4
    case invalidate = 5
}

/// Length-prefixed frame: `[u32be length][u8 version][u8 kind][payload]`.
enum IPCFrame {
    struct Decoded: Equatable, Sendable {
        let version: UInt8
        let kind: IPCFrameKind
        let payload: Data
    }

    static func encode(version: UInt8, kind: IPCFrameKind, payload: Data) throws -> Data {
        if payload.count > IPCProtocol.maxFramePayloadBytes {
            throw IPCError.frameTooLarge(bytes: payload.count)
        }
        var data = Data(capacity: 6 + payload.count)
        let length = UInt32(payload.count)
        data.append(contentsOf: [
            UInt8(truncatingIfNeeded: length >> 24),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length),
            version,
            kind.rawValue,
        ])
        data.append(payload)
        return data
    }

    static func decode(_ data: Data) throws -> Decoded {
        guard data.count >= 6 else { throw IPCError.invalidFrame }
        let header = try parseHeader(data)
        guard data.count == 6 + Int(header.length) else { throw IPCError.invalidFrame }
        return Decoded(
            version: header.version,
            kind: header.kind,
            payload: data.subdata(in: 6..<data.count)
        )
    }

    static func write(to fd: Int32, kind: IPCFrameKind, payload: Data, version: UInt8 = IPCProtocol.currentVersion) throws {
        try writeAll(fd: fd, data: encode(version: version, kind: kind, payload: payload))
    }

    static func read(from fd: Int32) throws -> Decoded {
        let bytes = try readExact(fd: fd, count: 6)
        let header = try parseHeader(bytes)
        let payload = try readExact(fd: fd, count: Int(header.length))
        return Decoded(version: header.version, kind: header.kind, payload: payload)
    }

    private struct Header {
        let length: UInt32
        let version: UInt8
        let kind: IPCFrameKind
    }

    private static func parseHeader(_ data: Data) throws -> Header {
        let length = UInt32(data[0]) << 24
            | UInt32(data[1]) << 16
            | UInt32(data[2]) << 8
            | UInt32(data[3])
        let version = data[4]
        if version != IPCProtocol.currentVersion {
            throw IPCError.unsupportedVersion(version)
        }
        if length > IPCProtocol.maxFramePayloadBytes {
            throw IPCError.frameTooLarge(bytes: Int(length))
        }
        guard let kind = IPCFrameKind(rawValue: data[5]) else {
            throw IPCError.invalidFrame
        }
        return Header(length: length, version: version, kind: kind)
    }
}

func writeAll(fd: Int32, data: Data) throws {
    try data.withUnsafeBytes { raw in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
            if data.isEmpty { return }
            throw IPCError.disconnected
        }
        var sent = 0
        while sent < raw.count {
            let n = Darwin.send(fd, base + sent, raw.count - sent, 0)
            if n <= 0 {
                if errno == EINTR { continue }
                throw IPCError.disconnected
            }
            sent += n
        }
    }
}

func readExact(fd: Int32, count: Int) throws -> Data {
    if count == 0 { return Data() }
    var buffer = Data(count: count)
    var received = 0
    while received < count {
        let n = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.recv(fd, base + received, count - received, 0)
        }
        if n == 0 { throw IPCError.disconnected }
        if n < 0 {
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                throw IPCError.timedOut
            }
            throw IPCError.disconnected
        }
        received += n
    }
    return buffer
}
