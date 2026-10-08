import CoreFoundation
import Foundation

struct RPCError: Error {
    let code: Int
    let message: String
    init(_ code: Int, _ message: String) { self.code = code; self.message = message }
}

enum MCPJSON {
    static func data(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }
    static func text(_ value: Any) throws -> String { String(decoding: try data(value), as: UTF8.self) }
    static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
    static func isInteger(_ value: Any) -> Bool {
        guard let number = value as? NSNumber, !isBoolean(value) else { return false }
        return number.doubleValue.isFinite && number.doubleValue.rounded() == number.doubleValue
    }
    static func requestID(_ value: Any?) -> Any? {
        guard let value else { return nil }
        return value is String || isInteger(value) ? value : nil
    }

    /// Validate the advertised schema subset before entering the native decoder.
    static func validate(_ value: Any, schema: [String: Any], location: String = "arguments") throws {
        let types = (schema["type"] as? [String]) ?? [schema["type"] as? String ?? ""]
        let actual: String
        if value is NSNull { actual = "null" }
        else if isBoolean(value) { actual = "boolean" }
        else if value is NSNumber { actual = isInteger(value) ? "integer" : "number" }
        else if value is String { actual = "string" }
        else if value is [String: Any] { actual = "object" }
        else if value is [Any] { actual = "array" }
        else { actual = "unknown" }
        guard types.contains(actual) || (actual == "integer" && types.contains("number")) else {
            throw RPCError(-32602, "\(location): expected \(types.joined(separator: " or ")).")
        }
        if actual == "null" { return }
        if let options = schema["enum"] as? [String], let string = value as? String, !options.contains(string) {
            throw RPCError(-32602, "\(location): unsupported value \(string).")
        }
        if actual == "integer" || actual == "number", let number = value as? NSNumber {
            let numeric = number.doubleValue
            guard numeric.isFinite else { throw RPCError(-32602, "\(location): must be finite.") }
            if let min = schema["minimum"] as? NSNumber, numeric < min.doubleValue { throw rangeError(location) }
            if let max = schema["maximum"] as? NSNumber, numeric > max.doubleValue { throw rangeError(location) }
            if let min = schema["exclusiveMinimum"] as? NSNumber, numeric <= min.doubleValue { throw rangeError(location) }
        } else if let object = value as? [String: Any] {
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            let missing = Set(schema["required"] as? [String] ?? []).subtracting(object.keys)
            let unknown = Set(object.keys).subtracting(properties.keys)
            guard missing.isEmpty && unknown.isEmpty else {
                throw RPCError(-32602, "\(location): missing \(missing.sorted()); unknown \(unknown.sorted()).")
            }
            guard object.count >= (schema["minProperties"] as? Int ?? 0) else {
                throw RPCError(-32602, "\(location): provide at least one edit.")
            }
            for key in object.keys.sorted() { try validate(object[key]!, schema: properties[key]!, location: "\(location).\(key)") }
        } else if let array = value as? [Any] {
            guard array.count >= (schema["minItems"] as? Int ?? 0),
                  array.count <= (schema["maxItems"] as? Int ?? MCPStdio.maximumRequestBytes) else {
                throw RPCError(-32602, "\(location): invalid number of items.")
            }
            for (index, member) in array.enumerated() {
                try validate(member, schema: schema["items"] as? [String: Any] ?? [:], location: "\(location)[\(index)]")
            }
        } else if let string = value as? String {
            if schema["format"] as? String == "uuid", UUID(uuidString: string) == nil {
                throw RPCError(-32602, "\(location): provide a UUID.")
            }
            if let pattern = schema["pattern"] as? String,
               string.contains("\0") || string.range(of: pattern, options: .regularExpression) == nil {
                throw RPCError(-32602, "\(location): invalid local path or URL.")
            }
        }
    }
    private static func rangeError(_ location: String) -> RPCError { RPCError(-32602, "\(location): outside the allowed range.") }
}

final class MCPBridge {
    static let protocols = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
    static let projectURI = "screentake://editor/project"
    private(set) var protocolVersion: String?
    let socketPath: String
    init(socketPath: String) { self.socketPath = socketPath }

    func dispatch(_ value: Any) throws -> [String: Any]? {
        guard let request = value as? [String: Any], request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String else {
            throw RPCError(-32600, "Expected a JSON-RPC 2.0 request object.")
        }
        guard let params = (request["params"] ?? [:]) as? [String: Any] else { throw RPCError(-32602, "params must be an object.") }
        // Notifications never produce stdout responses, including unknown methods.
        guard let id = request["id"] else { return nil }
        guard MCPJSON.requestID(id) != nil else { throw RPCError(-32600, "Request id must be a string or integer.") }
        if method == "initialize" {
            guard protocolVersion == nil else { throw RPCError(-32600, "Already initialized.") }
            guard let version = params["protocolVersion"] as? String, params["capabilities"] is [String: Any], params["clientInfo"] is [String: Any] else {
                throw RPCError(-32602, "Provide protocolVersion, capabilities, and clientInfo.")
            }
            let negotiated = Self.protocols.contains(version) ? version : Self.protocols.last!
            protocolVersion = negotiated
            return ["protocolVersion": negotiated, "capabilities": ["tools": ["listChanged": false], "resources": ["subscribe": false, "listChanged": false]],
                    "serverInfo": ["name": "screentake", "version": "1.1.0"],
                    "instructions": "Operate the project open in ScreenTake. Read get_project before editing and pass projectID/expectedRevision. Use stable requestID UUIDs for retriable mutations. Rendering and analysis return jobs; poll get_job. Retrieve preview images with get_preview_frame. ScreenTake must be running with its AI connection enabled."]
        }
        if method == "ping" { return [:] }
        guard let protocolVersion else { throw RPCError(-32600, "Initialize first.") }
        switch method {
        case "tools/list": return ["tools": MCPToolCatalog.tools]
        case "resources/list":
            return ["resources": [["uri": Self.projectURI, "name": "Current editor project", "description": "Live settings and revision from the native editor.", "mimeType": "application/json"]]]
        case "resources/templates/list": return ["resourceTemplates": []]
        case "resources/read":
            guard params["uri"] as? String == Self.projectURI else { throw RPCError(-32602, "Unknown resource URI.") }
            let result = native(["id": UUID().uuidString, "operation": "get_project"])
            guard result["ok"] as? Bool == true, let project = result["project"] else {
                throw RPCError(-32000, (result["error"] as? [String: Any])?["message"] as? String ?? "No project is open.")
            }
            return ["contents": [["uri": Self.projectURI, "mimeType": "application/json", "text": try MCPJSON.text(project)]]]
        case "tools/call":
            guard let name = params["name"] as? String,
                  let tool = MCPToolCatalog.tools.first(where: { $0["name"] as? String == name }) else { throw RPCError(-32602, "Unknown tool.") }
            let supplied = params["arguments"] ?? [String: Any]()
            try MCPJSON.validate(supplied, schema: tool["inputSchema"] as! [String: Any])
            var arguments = supplied as! [String: Any]
            let requestID = arguments.removeValue(forKey: "requestID") ?? UUID().uuidString
            if name == "get_preview_frame" { arguments["artifact"] = "preview_frame" }
            else { arguments["id"] = requestID; arguments["operation"] = name }
            var result = native(arguments)
            var content = [[String: Any]]()
            if result["ok"] as? Bool == true, var frame = result["frame"] as? [String: Any], let data = frame.removeValue(forKey: "data") as? String {
                content.append(["type": "image", "data": data, "mimeType": frame["mimeType"] ?? "image/png"])
                result = ["ok": true, "frame": frame]
            }
            content.insert(["type": "text", "text": try MCPJSON.text(result)], at: 0)
            var response: [String: Any] = ["content": content, "isError": result["ok"] as? Bool != true]
            if protocolVersion >= "2025-06-18" { response["structuredContent"] = result }
            return response
        default: throw RPCError(-32601, "Unknown method: \(method)")
        }
    }

    func native(_ request: [String: Any]) -> [String: Any] {
        do { return try EditorConnection.call(path: socketPath, request: request) }
        catch {
            return ["ok": false, "error": ["code": "connection_unavailable", "message": "\(error.localizedDescription). Start ScreenTake and check ScreenTake → AI Connection. After a connection loss, use the same requestID to retry a mutation; it may already have completed."]]
        }
    }
}
