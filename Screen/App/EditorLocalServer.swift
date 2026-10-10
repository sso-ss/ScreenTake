import AppKit
import Darwin

/// Owns the connection to this app instance. All commands enter the same main-actor
/// dispatcher as native edits; socket I/O never runs on the main actor.
@MainActor
final class EditorLocalServer: ObservableObject {
    static var socketPath: String { "/tmp/screentake-\(getuid())/editor.sock" }
    @Published private(set) var status = "Disabled"
    private var transport: EditorSocketTransport?
    private var connectionID: UUID?
    private let commands: EditorCommandDispatcher
    private let defaults: UserDefaults

    init(commands: EditorCommandDispatcher, defaults: UserDefaults = .standard) {
        self.commands = commands
        self.defaults = defaults
    }

    func startIfEnabled() {
        if defaults.object(forKey: "editorAIConnectionEnabled") as? Bool != false { start() }
    }

    func start() {
        guard transport == nil else { return }
        do {
            let id = UUID()
            let connection = try EditorSocketTransport(path: Self.socketPath) { [weak self] data in
                guard let self, self.connectionID == id else {
                    return Self.error("connection_disabled", "The AI connection is disabled.")
                }
                // Artifact requests can only read a frame belonging to a known job.
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   object["artifact"] as? String == "preview_frame" {
                    guard let idString = object["jobID"] as? String, let id = UUID(uuidString: idString),
                          let index = object["index"] as? Int else {
                        return Self.error("invalid_request", "Provide a jobID and frame index.")
                    }
                    return await self.commands.previewFrameJSON(jobID: id, index: index)
                }
                return await self.commands.executeJSON(data)
            }
            transport = connection
            connectionID = id
            defaults.set(true, forKey: "editorAIConnectionEnabled")
            status = "Ready · app process \(ProcessInfo.processInfo.processIdentifier)"
        } catch { status = error.localizedDescription }
    }

    func stop() {
        connectionID = nil
        transport?.stop()
        transport = nil
        status = "Disabled"
    }

    var isEnabled: Bool { transport != nil }
    private var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/screentake-mcp")
    }
    var helperAvailable: Bool { FileManager.default.isExecutableFile(atPath: helperURL.path) }
    var setupCommand: String { helperURL.path }
    var setupJSON: String? {
        let setup: [String: Any] = ["mcpServers": ["screentake": ["command": setupCommand, "args": [String]()]]]
        guard let data = try? JSONSerialization.data(withJSONObject: setup, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setEnabled(_ enabled: Bool) {
        if enabled { start() }
        else { defaults.set(false, forKey: "editorAIConnectionEnabled"); stop() }
    }

    @discardableResult
    func copySetup() -> Bool {
        guard helperAvailable, let text = setupJSON else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    func showSetup() {
        let alert = NSAlert()
        if let icon = AppBrand.icon { alert.icon = icon }
        alert.messageText = "AI Connection"
        let setupInfo = helperAvailable
            ? "Copy Setup provides the settings to connect your AI client. No additional software is required."
            : "The connection helper is missing. Reinstall ScreenTake to restore AI setup."
        alert.informativeText = "\(status)\n\nConnect an MCP client to edit the project open in this app. Local clients running as your macOS user can read media, edit, save, and export.\n\n\(setupInfo)"
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Copy Setup")
        alert.addButton(withTitle: transport == nil ? "Enable / Retry" : "Disable")
        alert.buttons[1].isEnabled = helperAvailable
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            copySetup()
        case .alertThirdButtonReturn:
            setEnabled(!isEnabled)
        default: break
        }
    }

    private static func error(_ code: String, _ message: String) -> Data {
        try! JSONEncoder().encode(EditorCommandResponse(ok: false, error: .init(code: code, message: message)))
    }
}

/// One bounded newline-delimited command per connection, then EOF. An advisory
/// lock serializes ownership and stale-socket recovery across app instances.
final class EditorSocketTransport {
    typealias Handler = @MainActor (Data) async -> Data
    static let maximumRequestBytes = 1_048_576
    private let queue = DispatchQueue(label: "com.screen.editor.listener")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let clientsLock = NSLock()
    private var clients = Set<Int32>()
    private var stopped = false
    private var listener: Int32 = -1
    private var lockFile: Int32 = -1
    private var source: DispatchSourceRead?
    private let path: String
    private let handler: Handler

    init(path: String, handler: @escaping Handler) throws {
        self.path = path
        self.handler = handler
        queue.setSpecific(key: queueKey, value: true)
        do { try setup() }
        catch { if listener >= 0 { close(listener) }; if lockFile >= 0 { close(lockFile) }; throw error }
        let events = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source = events
        events.setEventHandler { [weak self] in self?.acceptClients() }
        events.resume()
    }

    deinit { stop() }

    func stop() {
        let teardown = { [self] in
            guard listener >= 0 else { return }
            source?.cancel(); source = nil
            close(listener); listener = -1
            clientsLock.lock()
            stopped = true
            for fd in clients { shutdown(fd, SHUT_RDWR) }
            clientsLock.unlock()
            unlink(path)
            close(lockFile); lockFile = -1
        }
        if DispatchQueue.getSpecific(key: queueKey) == true { teardown() }
        else { queue.sync(execute: teardown) }
    }

    private func setup() throws {
        let directory = (path as NSString).deletingLastPathComponent
        guard mkdir(directory, 0o700) == 0 || errno == EEXIST else { throw Failure.system("Create connection directory") }
        let directoryFD = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw Failure.system("Open connection directory") }
        defer { close(directoryFD) }
        var info = stat()
        guard fstat(directoryFD, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            throw Failure.message("The connection directory must belong to you and have mode 0700.")
        }
        lockFile = open(directory + "/editor.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFile >= 0, fstat(lockFile, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600 else {
            throw Failure.message("The connection lock is not a private regular file.")
        }
        guard flock(lockFile, LOCK_EX | LOCK_NB) == 0 else {
            throw Failure.message("Another ScreenTake instance owns the AI connection. Disable it there, then retry here.")
        }
        let address = try Self.address(path)
        if lstat(path, &info) == 0 {
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else {
                throw Failure.message("An unexpected file occupies the connection path.")
            }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            guard probe >= 0 else { throw Failure.system("Create socket") }
            let result = Self.withAddress(address) { connect(probe, $0, $1) }
            let connectionError = errno
            close(probe)
            guard result != 0, connectionError == ECONNREFUSED else {
                throw Failure.message("An active connection already occupies this path.")
            }
            guard unlink(path) == 0 else { throw Failure.system("Recover stale socket") }
        } else if errno != ENOENT { throw Failure.system("Inspect socket") }
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Failure.system("Create socket") }
        guard Self.withAddress(address, { bind(listener, $0, $1) }) == 0 else { throw Failure.system("Bind socket") }
        guard chmod(path, 0o600) == 0, listen(listener, 8) == 0,
              fcntl(listener, F_SETFL, O_NONBLOCK) == 0 else {
            unlink(path)
            throw Failure.system("Listen on socket")
        }
    }

    private func acceptClients() {
        guard listener >= 0 else { return }
        while true {
            let fd = accept(listener, nil, nil)
            if fd < 0 { if errno == EINTR { continue }; return }
            var uid: uid_t = 0, gid: gid_t = 0
            clientsLock.lock()
            let allowed = !stopped && clients.count < 8 && getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
            if allowed { clients.insert(fd) }
            clientsLock.unlock()
            guard allowed else { close(fd); continue }
            // Accepted descriptors are explicitly blocking and have bounded I/O.
            _ = fcntl(fd, F_SETFL, 0)
            var timeout = timeval(tv_sec: 15, tv_usec: 0)
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue.global(qos: .userInitiated).async { [self] in serve(fd) }
        }
    }

    private func serve(_ fd: Int32) {
        defer {
            clientsLock.lock()
            clients.remove(fd)
            close(fd)
            clientsLock.unlock()
        }
        var request = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            request.append(contentsOf: buffer.prefix(count))
            guard request.count <= Self.maximumRequestBytes else { return }
            if let newline = request.firstIndex(of: 10) {
                guard newline == request.count - 1 else { return }
                request.removeLast()
                let result = ResponseBox(), ready = DispatchSemaphore(value: 0)
                let task = Task { @MainActor [handler] in
                    result.set(await handler(request))
                    ready.signal()
                }
                // The main actor remains free while async loading or saving runs.
                guard ready.wait(timeout: .now() + 120) == .success else { task.cancel(); return }
                let response = result.get() + Data([10])
                response.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let written = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                        if written < 0 && errno == EINTR { continue }
                        if written <= 0 { break }
                        offset += written
                    }
                }
                return
            }
        }
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.message("The socket path is too long.") }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    static func withAddress<T>(_ address: sockaddr_un, _ operation: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var address = address
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { operation($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    private final class ResponseBox {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    private enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
        static func system(_ action: String) -> Self { .message("\(action): \(String(cString: strerror(errno)))") }
    }
}
