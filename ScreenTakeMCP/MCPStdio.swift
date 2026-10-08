import Darwin
import Foundation

enum MCPStdio {
    static let maximumRequestBytes = 1024 * 1024

    /// Chunked framing bounds memory even when a client never sends a newline.
    static func serve(_ bridge: MCPBridge) throws {
        var frame = Data(), oversized = false
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if count == 0 {
                if oversized { try rejectOversized() }
                else if !frame.isEmpty { try respond(frame, bridge: bridge) }
                return
            }
            for byte in buffer.prefix(count) {
                if byte == 10 {
                    if oversized { try rejectOversized() }
                    else { try respond(frame, bridge: bridge) }
                    frame.removeAll(keepingCapacity: true)
                    oversized = false
                } else if !oversized {
                    frame.append(byte)
                    // Include the delimiter in the 1 MiB wire limit.
                    if frame.count >= maximumRequestBytes { frame.removeAll(keepingCapacity: true); oversized = true }
                }
            }
        }
    }

    private static func rejectOversized() throws {
        try writeJSON(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Request exceeds 1 MiB."]])
    }

    private static func respond(_ data: Data, bridge: MCPBridge) throws {
        var request: [String: Any]?, id: Any = NSNull()
        let response: [String: Any]
        do {
            let value: Any
            do { value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
            catch { throw RPCError(-32700, "Invalid JSON.") }
            request = value as? [String: Any]
            id = MCPJSON.requestID(request?["id"]) ?? NSNull()
            guard let result = try bridge.dispatch(value) else { return }
            response = ["jsonrpc": "2.0", "id": id, "result": result]
        } catch let error as RPCError {
            if let request, request["id"] == nil, request["jsonrpc"] as? String == "2.0", request["method"] is String { return }
            response = ["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]]
        } catch {
            response = ["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "Invalid parameters."]]
        }
        try writeJSON(response)
    }

    static func writeJSON(_ value: [String: Any]) throws {
        var data = try MCPJSON.data(value)
        data.append(10)
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(STDOUT_FILENO, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
    }
}

@main
struct ScreenTakeMCP {
    static func main() {
        // A client closing stdout is a normal disconnect, never a crash.
        signal(SIGPIPE, SIG_IGN)
        var path = "/tmp/screentake-\(getuid())/editor.sock", check = false
        var arguments = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = arguments.next() {
            switch argument {
            case "--socket":
                guard let value = arguments.next(), value.hasPrefix("/"), !value.contains("\0") else { usage(error: true) }
                path = value
            case "--check": check = true
            case "--help", "-h": usage(error: false)
            default: usage(error: true)
            }
        }
        let bridge = MCPBridge(socketPath: path)
        do {
            if check {
                let result = bridge.native(["id": UUID().uuidString, "operation": "get_capabilities"])
                try MCPStdio.writeJSON(result)
                exit(result["ok"] as? Bool == true ? 0 : 1)
            }
            try MCPStdio.serve(bridge)
        } catch let error as POSIXError where error.code == .EPIPE { exit(0) }
        catch {
            fputs("screentake-mcp: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func usage(error: Bool) -> Never {
        fputs("Usage: screentake-mcp [--socket /absolute/editor.sock] [--check]\nScreenTake native stdio MCP bridge. --check performs a read-only connection check.\n", error ? stderr : stdout)
        exit(error ? 2 : 0)
    }
}
