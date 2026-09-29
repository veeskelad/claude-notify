import Foundation

// Unix-socket server for hook messages: one JSON line per connection.
// Fire-and-forget messages close right away; a waiting request keeps its
// connection open until the app replies or the hook process goes away.

final class Connection {
    let fd: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var gotMessage = false
    private(set) var closed = false

    var onMessage: ((Data) -> Void)?
    private var onClose: (() -> Void)?

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    func start() {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        // Strong capture on purpose: the connection lives until finish() cancels the source.
        src.setEventHandler { self.readAvailable() }
        src.setCancelHandler { [fd] in Darwin.close(fd) }
        source = src
        src.resume()
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = Darwin.read(fd, &chunk, chunk.count)
        if n <= 0 {
            if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
            let callback = onClose
            finish()
            if let callback = callback { DispatchQueue.main.async(execute: callback) }
            return
        }
        guard !gotMessage else { return }  // ignore anything after the first line
        buffer.append(contentsOf: chunk[0..<n])
        if let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            gotMessage = true
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeAll()
            onMessage?(line)
        } else if buffer.count > 4 * 1024 * 1024 {
            finish()
        }
    }

    /// Send the reply line and close. Safe to call from any queue, only the first call counts.
    func reply(_ object: [String: Any]) {
        queue.async { [self] in
            guard !closed else { return }
            if var data = try? JSONSerialization.data(withJSONObject: object) {
                data.append(UInt8(ascii: "\n"))
                data.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let w = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                        if w <= 0 { break }
                        offset += w
                    }
                }
            }
            finish()
        }
    }

    func close() { queue.async { [self] in finish() } }

    /// Run `callback` on the main queue when the peer disconnects before we replied
    /// (hook timed out or Claude Code exited). Fires at once if that already happened.
    func whenPeerCloses(_ callback: @escaping () -> Void) {
        queue.async { [self] in
            if closed { DispatchQueue.main.async(execute: callback) } else { onClose = callback }
        }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        onClose = nil
        source?.cancel()
        source = nil
    }
}

final class IPCServer {
    private let path: String
    private let queue = DispatchQueue(label: "claude-notify.ipc")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    /// Called on the main queue with the parsed JSON and its connection.
    var onMessage: (([String: Any], Connection) -> Void)?

    init(path: String) { self.path = path }

    /// True if another notifier instance already answers on the socket.
    static func isAnotherInstanceRunning(path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var addr = IPCServer.address(path)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) == 0 }
        }
    }

    private static func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(dir, 0o700)
        unlink(path)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw posixError("socket") }
        var addr = IPCServer.address(path)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, len) }
        }
        guard bound == 0 else { throw posixError("bind") }
        chmod(path, 0o600)
        guard listen(listenFD, 32) == 0 else { throw posixError("listen") }
        _ = fcntl(listenFD, F_SETFL, O_NONBLOCK)

        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptAll() }
        acceptSource = src
        src.resume()
        log("[ipc] listening on \(path)")
    }

    private func acceptAll() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            // Only the same user may talk to us (the socket is 0600 already; belt and braces).
            var uid: uid_t = 0, gid: gid_t = 0
            if getpeereid(fd, &uid, &gid) != 0 || uid != getuid() {
                Darwin.close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var noSigpipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

            let conn = Connection(fd: fd, queue: queue)
            conn.onMessage = { [weak self, weak conn] line in
                guard let self = self, let conn = conn else { return }
                guard let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                    log("[ipc] bad json (\(line.count) bytes)")
                    conn.close()
                    return
                }
                DispatchQueue.main.async { self.onMessage?(json, conn) }
            }
            conn.start()
        }
    }

    private func posixError(_ what: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "\(what): \(String(cString: strerror(errno)))"])
    }
}
