import Foundation

/// Client for Slyy Haven (protocol haven.v1): JSON-RPC 2.0 over the local socket that Haven owns.
/// Haven holds model keys and data-source credentials; Mailr only asks for model classes and tools.
///
/// Wire assumptions until the haven.v1 JSON Schema exists (then the generated HavenKit replaces this file):
/// - one JSON object per line (newline-delimited JSON) in both directions,
/// - `chat/stream` returns `{"streamId"}` and the reply arrives as `chat/delta` notifications
///   `{"streamId", "text"?, "toolCalls"?: [{"id","name","arguments"}], "finish"?: "stop"|"tool_calls"|"length"|"error", "error"?}`,
/// - messages use the chat shape `{"role","content","toolCalls"?,"toolCallId"?}`.
public actor HavenClient {
    public static let protocolVersion = "haven.v1"

    public enum Failure: Error, LocalizedError, Equatable {
        case notInstalled
        case protocolMismatch(String)
        case grantDenied(String)
        case forbidden(String)
        case budgetExceeded
        case rpc(code: Int, message: String)
        case closed

        public var errorDescription: String? {
            switch self {
            case .notInstalled: return "Slyy Haven is not installed or not running."
            case .protocolMismatch(let v): return "Slyy Haven needs an update (it speaks \(v))."
            case .grantDenied(let m): return "Slyy Haven did not allow this: \(m)"
            case .forbidden(let m): return "Not allowed: \(m)"
            case .budgetExceeded: return "Mailr has reached its AI budget for this month (Slyy Haven settings)."
            case .rpc(_, let m): return m
            case .closed: return "The connection to Slyy Haven was closed."
            }
        }

        static func from(code: Int, message: String, data: JSONValue?) -> Failure {
            switch data?["code"]?.string ?? message {
            case "PROTOCOL_MISMATCH": return .protocolMismatch(data?["required"]?.string ?? message)
            case "GRANT_DENIED": return .grantDenied(message)
            case "FORBIDDEN": return .forbidden(message)
            case "BUDGET_EXCEEDED": return .budgetExceeded
            default: return .rpc(code: code, message: message)
            }
        }
    }

    public struct Tool: Codable, Hashable, Sendable {
        public var name: String
        public var description: String
        public var inputSchema: JSONValue
        public var mutating: Bool?

        public init(name: String, description: String, inputSchema: JSONValue, mutating: Bool? = nil) {
            self.name = name
            self.description = description
            self.inputSchema = inputSchema
            self.mutating = mutating
        }
    }

    public struct ToolCall: Codable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var arguments: JSONValue

        public init(id: String, name: String, arguments: JSONValue) {
            self.id = id
            self.name = name
            self.arguments = arguments
        }
    }

    public struct Message: Codable, Hashable, Sendable {
        public var role: String
        public var content: String
        public var toolCalls: [ToolCall]?
        public var toolCallId: String?

        public init(role: String, content: String, toolCalls: [ToolCall]? = nil, toolCallId: String? = nil) {
            self.role = role
            self.content = content
            self.toolCalls = toolCalls
            self.toolCallId = toolCallId
        }

        public static func system(_ s: String) -> Message { Message(role: "system", content: s) }
        public static func user(_ s: String) -> Message { Message(role: "user", content: s) }
    }

    public struct Source: Codable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var kind: String?
        public var state: String?
        public var scope: String?
    }

    public enum StreamEvent: Sendable, Equatable {
        case text(String)
        case toolCalls([ToolCall])
        case finished(String)
    }

    private let stream: ByteStream
    private let reader: BufferedStream
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var streams: [String: AsyncThrowingStream<StreamEvent, Error>.Continuation] = [:]
    /// Deltas that arrive before `chat/stream` has returned its stream id.
    private var early: [String: [JSONValue]] = [:]
    private var readTask: Task<Void, Never>?
    private var isClosed = false
    public private(set) var serverInfo: JSONValue?

    public init(stream: ByteStream) {
        self.stream = stream
        self.reader = BufferedStream(stream)
    }

    /// Default socket: `haven.sock` in the shared Slyy app-group container (`<Team ID>.ai.slyy`).
    public static func defaultSocketPath(teamID: String?) -> String? {
        if let override = ProcessInfo.processInfo.environment["SLYY_HAVEN_SOCKET"], !override.isEmpty { return override }
        #if canImport(Darwin)
        guard let teamID, !teamID.isEmpty,
              let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "\(teamID).ai.slyy") else { return nil }
        return dir.appendingPathComponent("haven.sock").path
        #else
        return nil
        #endif
    }

    /// Connects and performs `haven/initialize`. Throws `.notInstalled` when nothing listens on the socket.
    public static func connect(path: String, app: String, version: String) async throws -> HavenClient {
        let s: UnixSocketStream
        do { s = try UnixSocketStream.connect(path: path) } catch { throw Failure.notInstalled }
        let client = HavenClient(stream: s)
        try await client.initialize(app: app, version: version)
        return client
    }

    public func initialize(app: String, version: String) async throws {
        start()
        let r = try await call("haven/initialize", [
            "protocol": .string(Self.protocolVersion),
            "client": ["name": .string(app), "version": .string(version)],
            "capabilities": ["tools": true, "streaming": true],
        ])
        // "haven.v1.3" is fine for a haven.v1 client (minor additions); "haven.v2" is not.
        if let p = r["protocol"]?.string, Self.major(p) != Self.major(Self.protocolVersion) {
            throw Failure.protocolMismatch(p)
        }
        serverInfo = r
    }

    static func major(_ version: String) -> String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }

    public func close() {
        isClosed = true
        readTask?.cancel()
        stream.close()
        failAll(Failure.closed)
    }

    // MARK: API

    public func models() async throws -> JSONValue { try await call("models/list", [:]) }

    public func sources() async throws -> [Source] {
        let r = try await call("sources/list", [:])
        return try (r["sources"] ?? r).decode([Source].self)
    }

    public func tools() async throws -> [Tool] {
        let r = try await call("tools/list", [:])
        return try (r["tools"] ?? r).decode([Tool].self)
    }

    /// Calls a namespaced source tool (`<source>__<tool>`). Writes need Mailr's write grant; Haven asks the user to confirm.
    public func callTool(_ name: String, arguments: JSONValue) async throws -> JSONValue {
        try await call("tools/call", ["name": .string(name), "arguments": arguments])
    }

    /// Starts a completion for a model class (fast, smart, vision, embed) and streams its reply.
    public func chat(class modelClass: String, messages: [Message], tools: [Tool]) async throws -> (id: String, events: AsyncThrowingStream<StreamEvent, Error>) {
        var params: [String: JSONValue] = ["class": .string(modelClass), "messages": try JSONValue.from(messages)]
        if !tools.isEmpty { params["tools"] = try JSONValue.from(tools) }
        let r = try await call("chat/stream", .object(params))
        guard let id = r["streamId"]?.string else { throw Failure.rpc(code: -32603, message: "chat/stream returned no streamId") }
        let (events, cont) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        streams[id] = cont
        cont.onTermination = { [weak self] reason in
            guard case .cancelled = reason else { return }
            Task { await self?.cancel(id) }
        }
        for delta in early.removeValue(forKey: id) ?? [] { deliver(delta) }
        return (id, events)
    }

    public func cancel(_ streamID: String) async {
        streams.removeValue(forKey: streamID)?.finish()
        _ = try? await call("chat/cancel", ["streamId": .string(streamID)])
    }

    // MARK: JSON-RPC plumbing

    private func start() {
        guard readTask == nil else { return }
        readTask = Task { [weak self] in
            guard let self else { return }
            await self.readLoop()
        }
    }

    private func readLoop() async {
        while !Task.isCancelled {
            do {
                let line = try await reader.readLine()
                guard !line.isEmpty, let msg = try? JSONDecoder().decode(JSONValue.self, from: line) else { continue }
                handle(msg)
            } catch {
                failAll(isClosed ? Failure.closed : error)
                return
            }
        }
    }

    private func handle(_ msg: JSONValue) {
        if let id = msg["id"]?.number, msg["method"] == nil {
            guard let cont = pending.removeValue(forKey: Int(id)) else { return }
            if let err = msg["error"] {
                cont.resume(throwing: Failure.from(code: Int(err["code"]?.number ?? 0), message: err["message"]?.string ?? "error", data: err["data"]))
            } else {
                cont.resume(returning: msg["result"] ?? .null)
            }
            return
        }
        if msg["method"]?.string == "chat/delta", let p = msg["params"] {
            deliver(p)
        }
    }

    private func deliver(_ p: JSONValue) {
        guard let id = p["streamId"]?.string else { return }
        guard let cont = streams[id] else {
            early[id, default: []].append(p)
            return
        }
        if let t = p["text"]?.string, !t.isEmpty { cont.yield(.text(t)) }
        if let calls = p["toolCalls"]?.array, !calls.isEmpty {
            let parsed = calls.compactMap { c -> ToolCall? in
                guard let name = c["name"]?.string else { return nil }
                var args = c["arguments"] ?? .object([:])
                if case .string(let s) = args { args = JSONValue.parse(s) ?? .object([:]) } // OpenAI style: JSON text
                return ToolCall(id: c["id"]?.string ?? UUID().uuidString, name: name, arguments: args)
            }
            cont.yield(.toolCalls(parsed))
        }
        if let finish = p["finish"]?.string {
            streams.removeValue(forKey: id)
            if finish == "error" {
                cont.finish(throwing: Failure.rpc(code: -32000, message: p["error"]?["message"]?.string ?? p["error"]?.string ?? "model error"))
            } else {
                cont.yield(.finished(finish))
                cont.finish()
            }
        }
    }

    private func failAll(_ error: Error) {
        for (_, c) in pending { c.resume(throwing: error) }
        pending.removeAll()
        for (_, s) in streams { s.finish(throwing: error) }
        streams.removeAll()
    }

    private func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        if isClosed { throw Failure.closed }
        let id = nextID
        nextID += 1
        let line = JSONValue.object(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]).jsonText + "\n"
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            Task {
                do { try await reader.write(line) } catch { self.failPending(id, error) }
            }
        }
    }

    private func failPending(_ id: Int, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }
}
