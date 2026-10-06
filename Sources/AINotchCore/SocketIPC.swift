// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Where the app listens for `ainotch-hook`.
public enum AINotchPaths {
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["AINOTCH_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if os(macOS)
        return home.appendingPathComponent("Library/Application Support/AINotch", isDirectory: true)
        #else
        return home.appendingPathComponent(".ainotch", isDirectory: true)
        #endif
    }

    public static var socket: URL { supportDirectory.appendingPathComponent("hook.sock") }

    /// Claude Code's config folder, honouring `CLAUDE_CONFIG_DIR`.
    public static var claudeDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }
}

private func makeAddress(_ path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    #if canImport(Darwin)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: bytes)
        buffer[bytes.count] = 0
    }
    return address
}

private func streamSocket() -> Int32 {
    #if canImport(Glibc)
    return socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #else
    return socket(AF_UNIX, SOCK_STREAM, 0)
    #endif
}

/// Writes all of `data`, retrying short writes.
@discardableResult
private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
        guard var pointer = raw.baseAddress else { return true }
        var remaining = raw.count
        while remaining > 0 {
            let written = write(fd, pointer, remaining)
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { return false }
            remaining -= written
            pointer += written
        }
        return true
    }
}

/// Reads up to the first newline (or EOF), capped at `limit` bytes.
private func readLine(_ fd: Int32, limit: Int = 8 << 20) -> Data? {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 << 10)
    while data.count < limit {
        let count = read(fd, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { break }
        if let newline = buffer[0..<count].firstIndex(of: 0x0A) {
            data.append(contentsOf: buffer[0..<newline])
            return data
        }
        data.append(contentsOf: buffer[0..<count])
    }
    return data.isEmpty ? nil : data
}

/// Answers one hook call. A blocking hook waits on the other end until
/// `send` runs; Claude Code continues once it does.
public final class HookResponder: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32

    init(fd: Int32) { self.fd = fd }

    deinit { send(nil) }

    /// Sends the hook's stdout (nil or empty for "no opinion") and closes.
    public func send(_ stdout: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        let reply = (try? JSONSerialization.data(withJSONObject: ["stdout": stdout ?? ""])) ?? Data("{}".utf8)
        writeAll(fd, reply + Data([0x0A]))
        close(fd)
        fd = -1
    }

    /// True once the hook process went away (Claude Code timed it out, or
    /// the person pressed Esc), so a stale pop-up can be closed.
    public var isAbandoned: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return true }
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 0) > 0 else { return false }
        if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return true }
        var byte: UInt8 = 0
        return recv(fd, &byte, 1, Int32(MSG_PEEK)) == 0
    }
}

/// The app side: accepts hook connections on a Unix socket.
public final class HookServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HookMessage, HookResponder) -> Void

    private let path: String
    private let handler: Handler
    private var listener: Int32 = -1
    private let queue = DispatchQueue(label: "ainotch.hook-server", attributes: .concurrent)

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        signal(SIGPIPE, SIG_IGN)
        unlink(path)
        guard var address = makeAddress(path) else { throw POSIXError(.ENAMETOOLONG) }
        let fd = streamSocket()
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(fd)
            throw POSIXError(code)
        }
        chmod(path, 0o600)
        listener = fd
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "ainotch.hook-accept"
        thread.start()
    }

    public func stop() {
        guard listener >= 0 else { return }
        shutdown(listener, Int32(SHUT_RDWR))
        close(listener)
        listener = -1
        unlink(path)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            #if canImport(Darwin)
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif
            queue.async { [handler] in
                let responder = HookResponder(fd: client)
                guard let line = readLine(client), let message = HookMessage.decode(line) else {
                    responder.send(nil)
                    return
                }
                handler(message, responder)
                if !message.wantsReply { responder.send(nil) }
            }
        }
    }
}

/// The hook side: forwards one message and, when asked, waits for the reply.
public enum HookClient {
    /// Returns the stdout the hook should print, or nil when the app is not
    /// running or did not answer — in which case Claude Code carries on as usual.
    public static func send(_ message: HookMessage, socketPath: String, timeout: TimeInterval) -> String? {
        guard var address = makeAddress(socketPath) else { return nil }
        let fd = streamSocket()
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0, writeAll(fd, message.encoded()) else { return nil }
        guard message.wantsReply else { return nil }
        var limit = timeval(tv_sec: Int(max(1, timeout)), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        guard let line = readLine(fd),
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let stdout = object["stdout"] as? String, !stdout.isEmpty else { return nil }
        return stdout
    }
}
