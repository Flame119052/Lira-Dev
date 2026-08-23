import Darwin
import Foundation

/// Owned AF_UNIX helpers. No TCP constructors live here — `AF_INET` is
/// intentionally unused so an unauthenticated localhost port cannot be bound.
enum UnixSocket {
    /// `sockaddr_un.sun_path` including the trailing NUL, on Darwin.
    static let maxPathLength = 104

    static func make() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            throw IPCError.listenFailed(errno: errno)
        }
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFD)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
        }
        return fd
    }

    static func setReceiveTimeout(fd: Int32, seconds: TimeInterval) {
        var timeout = timeval(
            tv_sec: __darwin_time_t(seconds),
            tv_usec: suseconds_t((seconds - floor(seconds)) * 1_000_000)
        )
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    static func clearReceiveTimeout(fd: Int32) {
        var timeout = timeval(tv_sec: 0, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    static func preparePath(_ url: URL) throws {
        let path = url.path
        if path.utf8.count >= maxPathLength {
            throw IPCError.socketPathTooLong(path: path)
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        if FileManager.default.fileExists(atPath: path) {
            if isLive(path: url) {
                throw IPCError.alreadyInUse(path: path)
            }
            try FileManager.default.removeItem(at: url)
        }
    }

    /// True when something is still accepting on this Unix path.
    static func isLive(path: URL) -> Bool {
        guard let fd = try? make() else { return false }
        defer { close(fd) }
        do {
            try connect(fd: fd, path: path)
            return true
        } catch {
            return false
        }
    }

    static func unlinkIfOwned(path: URL, listenFD: Int32) {
        guard listenFD >= 0 else { return }
        var fdInfo = Darwin.stat()
        guard fstat(listenFD, &fdInfo) == 0 else { return }
        var pathInfo = Darwin.stat()
        let pathOk = path.path.withCString { cPath in
            lstat(cPath, &pathInfo) == 0
        }
        guard pathOk else { return }
        if fdInfo.st_dev == pathInfo.st_dev, fdInfo.st_ino == pathInfo.st_ino {
            _ = path.path.withCString { Darwin.unlink($0) }
        }
    }

    static func bind(fd: Int32, path: URL) throws {
        try withSockaddr(path) { addr, length in
            if Darwin.bind(fd, addr, length) != 0 {
                throw IPCError.listenFailed(errno: errno)
            }
        }
        _ = Darwin.fchmod(fd, S_IRUSR | S_IWUSR)
    }

    static func listen(fd: Int32, backlog: Int32 = 16) throws {
        if Darwin.listen(fd, backlog) != 0 {
            throw IPCError.listenFailed(errno: errno)
        }
    }

    static func accept(fd: Int32) throws -> Int32 {
        let client = Darwin.accept(fd, nil, nil)
        if client < 0 {
            throw IPCError.listenFailed(errno: errno)
        }
        var on: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setReceiveTimeout(fd: client, seconds: 5)
        return client
    }

    static func connect(fd: Int32, path: URL) throws {
        try withSockaddr(path) { addr, length in
            if Darwin.connect(fd, addr, length) != 0 {
                throw IPCError.connectFailed(errno: errno)
            }
        }
        setReceiveTimeout(fd: fd, seconds: 5)
    }

    static func peerCredential(fd: Int32) throws -> PeerCredential {
        var pid: pid_t = 0
        var pidLength = socklen_t(MemoryLayout<pid_t>.size)
        if getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidLength) != 0 {
            throw IPCError.peerRejected(reason: .credentialUnreadable)
        }

        var token = audit_token_t()
        var tokenLength = socklen_t(MemoryLayout<audit_token_t>.size)
        if getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenLength) == 0 {
            return .auditToken(PeerAuditToken(token))
        }
        return .processID(pid)
    }

    static func close(_ fd: Int32) {
        guard fd >= 0 else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    private static func withSockaddr(
        _ url: URL,
        body: (UnsafePointer<sockaddr>, socklen_t) throws -> Void
    ) throws {
        let path = url.path
        if path.utf8.count >= maxPathLength {
            throw IPCError.socketPathTooLong(path: path)
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let written = path.withCString { cString -> Bool in
            let count = strlen(cString)
            if count >= maxPathLength { return false }
            withUnsafeMutableBytes(of: &addr.sun_path) { dest in
                dest.copyBytes(from: UnsafeRawBufferPointer(start: cString, count: count + 1))
            }
            return true
        }
        guard written else { throw IPCError.socketPathTooLong(path: path) }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        try withUnsafePointer(to: &addr) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                try body(sockaddrPointer, length)
            }
        }
    }
}
