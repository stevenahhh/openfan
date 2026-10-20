import Foundation
import OpenFanCore

/// Unix-domain-socket client for the privileged helper.
///
/// A single serial queue owns the socket descriptor; public methods may be called from any queue and
/// hop onto it. Every read carries a receive timeout and the socket sets SO_NOSIGPIPE, so a wedged or
/// dead helper can neither hang the caller nor kill the app with a signal.
final class HelperClient {
    private let queue = DispatchQueue(label: "com.stevenahhh.openfan.helper-client")
    private let path: String

    private let lock = NSLock()
    private var connectedFlag = false
    private var lastStatusValue: HelperStatus?
    private var lastErrorValue: String?

    private var descriptor: Int32 = -1
    private var desiredPreset: Preset?
    private var watchdog = ControlWatchdog()
    private var controlLostFlag = false
    private var backoffSeconds: UInt = 1
    private var nextAttempt = Date.distantPast

    private static let receiveTimeoutSeconds: Int = 2
    private static let maxBackoffSeconds: UInt = 16

    init(path: String = HelperPaths.socketPath) {
        self.path = path
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return connectedFlag
    }

    var lastStatus: HelperStatus? {
        lock.lock(); defer { lock.unlock() }
        return lastStatusValue
    }

    var lastError: String? {
        lock.lock(); defer { lock.unlock() }
        return lastErrorValue
    }

    /// True while the helper keeps reporting Auto although a preset is selected and resending has not helped yet.
    var controlLost: Bool {
        lock.lock(); defer { lock.unlock() }
        return controlLostFlag
    }

    func connect() {
        queue.async { [self] in _ = openIfNeeded() }
    }

    func reconnect() {
        queue.async { [self] in
            closeLocked()
            nextAttempt = .distantPast
            _ = openIfNeeded()
        }
    }

    @discardableResult
    func send(_ line: String) -> String? {
        queue.sync { [self] in
            guard openIfNeeded() else { return nil }
            return transact(line)
        }
    }

    func setCurve(_ preset: Preset) {
        queue.async { [self] in
            desiredPreset = preset
            resetWatchdog()
            guard openIfNeeded() else { return }
            recordReply(transact(Self.command(for: preset)))
        }
    }

    func setAuto() {
        queue.async { [self] in
            desiredPreset = nil
            resetWatchdog()
            guard openIfNeeded() else { return }
            recordReply(transact(HelperCommand.auto.serialized))
        }
    }

    @discardableResult
    func refreshStatus() -> HelperStatus? {
        queue.sync { [self] in
            guard openIfNeeded(), let reply = transact(HelperCommand.status.serialized) else {
                return lastStatusValue
            }
            guard let status = HelperStatus.parse(reply) else { return lastStatusValue }
            setLastStatus(status)
            watch(status)
            return status
        }
    }

    /// Asks for STATUS, which also keeps the helper lease fresh. Does nothing unless a preset is wanted; when the link
    /// has dropped (the helper restarted, say) it reconnects, with backoff, and sends the preset again. When the helper
    /// has fallen back to Auto on its own, the watchdog sends the preset again.
    func keepAlive() {
        queue.async { [self] in
            guard desiredPreset != nil, openIfNeeded(),
                  let reply = transact(HelperCommand.status.serialized),
                  let status = HelperStatus.parse(reply) else { return }
            setLastStatus(status)
            watch(status)
        }
    }

    /// Runs on `queue`.
    private func watch(_ status: HelperStatus) {
        let resend = watchdog.observe(mode: status.mode, presetSelected: desiredPreset != nil,
                                      now: Date().timeIntervalSinceReferenceDate)
        lock.lock(); controlLostFlag = watchdog.isLost; lock.unlock()
        if resend, let preset = desiredPreset {
            recordReply(transact(Self.command(for: preset)))
        }
    }

    /// Runs on `queue`.
    private func resetWatchdog() {
        watchdog.reset()
        lock.lock(); controlLostFlag = false; lock.unlock()
    }

    /// Sends AUTO (when controlling) and closes the socket synchronously, for use right before quit.
    func shutdown() {
        queue.sync { [self] in
            if descriptor >= 0 && desiredPreset != nil {
                _ = transact(HelperCommand.auto.serialized)
            }
            closeLocked()
        }
    }

    private func openIfNeeded() -> Bool {
        if descriptor >= 0 { return true }
        guard Date() >= nextAttempt else { return false }
        guard openSocket() else {
            scheduleBackoff()
            return false
        }
        backoffSeconds = 1
        nextAttempt = .distantPast
        setConnected(true)
        if let preset = desiredPreset {
            recordReply(transact(Self.command(for: preset)))
        }
        return true
    }

    /// A preset with a target holds that temperature; any other preset is a curve.
    private static func command(for preset: Preset) -> String {
        if let target = preset.target {
            return HelperCommand.hold(input: preset.input, target: target).serialized
        }
        return HelperCommand.curve(input: preset.input, points: preset.points).serialized
    }

    private func scheduleBackoff() {
        nextAttempt = Date().addingTimeInterval(TimeInterval(backoffSeconds))
        backoffSeconds = min(backoffSeconds * 2, Self.maxBackoffSeconds)
    }

    private func transact(_ line: String) -> String? {
        guard descriptor >= 0 else { return nil }
        guard writeAll(line + "\n") else { markDisconnected(); return nil }
        guard let reply = readLine() else { markDisconnected(); return nil }
        return reply
    }

    private func markDisconnected() {
        closeLocked()
        scheduleBackoff()
    }

    private func closeLocked() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
        setConnected(false)
    }

    private func openSocket() -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var timeout = timeval(tv_sec: Self.receiveTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            return false
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            return false
        }

        descriptor = fd
        return true
    }

    private func writeAll(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.send(descriptor, base.advanced(by: offset), raw.count - offset, 0)
            }
            if written <= 0 { return false }
            offset += written
        }
        return true
    }

    private func readLine() -> String? {
        var collected = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 256)
        let limit = HelperPaths.maxLineBytes + 1
        while collected.count <= limit {
            let received = chunk.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.recv(descriptor, base, raw.count, 0)
            }
            if received <= 0 { return nil }
            collected.append(contentsOf: chunk.prefix(received))
            if let newline = collected.firstIndex(of: 0x0a) {
                return String(decoding: collected[..<newline], as: UTF8.self)
            }
        }
        return nil
    }

    private func setConnected(_ value: Bool) {
        lock.lock(); connectedFlag = value; lock.unlock()
    }

    private func recordReply(_ reply: String?) {
        guard let reply else { return }
        let error = reply.hasPrefix("ERR") ? String(reply.dropFirst(3)).trimmingCharacters(in: .whitespaces) : nil
        lock.lock(); lastErrorValue = error; lock.unlock()
    }

    private func setLastStatus(_ status: HelperStatus?) {
        lock.lock(); lastStatusValue = status; lock.unlock()
    }
}
