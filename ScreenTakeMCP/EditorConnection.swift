import Darwin
import Foundation

/// One private, same-user socket connection per command. No network listener.
enum EditorConnection {
    static let maximumResponseBytes = 16 * 1024 * 1024

    static func call(path: String, request: [String: Any]) throws -> [String: Any] {
        let directory = (path as NSString).deletingLastPathComponent
        let directoryFD = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw Failure.system("Open connection directory") }
        defer { close(directoryFD) }
        var info = stat()
        guard fstat(directoryFD, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            throw Failure("The socket directory must be private (0700) and owned by your user")
        }
        guard lstat(path, &info) == 0 else { throw Failure.system("Inspect editor socket") }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid(), info.st_mode & 0o777 == 0o600 else {
            throw Failure("The socket must be private (0600) and owned by your user")
        }
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure("The socket path is too long") }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        var wire = try MCPJSON.data(request)
        wire.append(10)
        guard wire.count <= MCPStdio.maximumRequestBytes else { throw Failure("The native request exceeds 1 MiB") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.system("Create socket") }
        defer { close(fd) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw Failure.system("Configure socket") }
        var yes: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw Failure.system("Configure socket") }
        let deadline = ProcessInfo.processInfo.systemUptime + 125
        let connection = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connection != 0 {
            guard errno == EINPROGRESS else { throw Failure.system("Connect to editor") }
            try wait(fd, events: Int16(POLLOUT), deadline: deadline)
            var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { throw Failure.system("Connect to editor") }
            guard error == 0 else { throw Failure("Connect to editor: \(String(cString: strerror(error)))") }
        }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw Failure("The editor socket peer must be your user") }
        try wire.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try wait(fd, events: Int16(POLLOUT), deadline: deadline)
                let count = send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw Failure.system("Send editor request") }
                offset += count
            }
        }
        var response = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            try wait(fd, events: Int16(POLLIN), deadline: deadline)
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw Failure("The editor closed the connection without a complete response") }
            response.append(contentsOf: buffer.prefix(count))
            guard response.count <= maximumResponseBytes else { throw Failure("Oversized response from the editor") }
            // Earlier chunks have no delimiter. Scan only the newly read bytes
            // so a large preview response takes linear time to frame.
            if let newline = buffer.prefix(count).firstIndex(of: 10) {
                guard newline == count - 1,
                      let result = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                      let ok = result["ok"], MCPJSON.isBoolean(ok) else { throw Failure("Invalid response from the editor") }
                return result
            }
        }
    }

    private static func wait(_ fd: Int32, events: Int16, deadline: Double) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw Failure("The editor connection timed out") }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1000 + 1, Double(Int32.max))))
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw Failure.system("Wait for editor") }
            guard result > 0 else { throw Failure("The editor connection timed out") }
            guard descriptor.revents & Int16(POLLNVAL) == 0 else { throw Failure("The editor connection is invalid") }
            return // HUP/ERR are handled by the next send/recv or SO_ERROR check.
        }
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
        static func system(_ action: String) -> Self { Self("\(action): \(String(cString: strerror(errno)))") }
    }
}
