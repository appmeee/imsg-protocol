import AppMeeeIMsgCore
import Foundation

// MARK: - StdoutWriter

/// Thread-safe namespace for writing line-delimited JSON to stdout.
///
/// All output from the RPC server flows through this writer to prevent
/// interleaved output when multiple tasks attempt concurrent writes.
enum StdoutWriter {
    private static let queue = DispatchQueue(label: "appmeee.imsg.stdout", qos: .userInitiated)

    /// Writes a single line to stdout, appending a newline terminator.
    ///
    /// - Parameter line: The string to write. A trailing `\n` is appended automatically.
    static func writeLine(_ line: String) {
        queue.sync {
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }
    }

    /// Serializes a dictionary as compact JSON and writes it as a single line to stdout.
    ///
    /// - Parameter dict: The dictionary to serialize. Keys are sorted for deterministic output.
    static func writeJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ),
            let line = String(data: data, encoding: .utf8)
        else { return }
        writeLine(line)
    }
}

// MARK: - RPCServer

/// JSON-RPC 2.0 server for the AppMeee iMessage protocol bridge.
///
/// Reads line-delimited JSON requests from stdin, dispatches each to the
/// appropriate handler method, and writes JSON responses to stdout. Designed
/// to be owned by a single async task on the main thread -- not `Sendable`.
///
/// Methods supported:
/// - `chats.list` -- list recent conversations
/// - `messages.history` -- fetch message history for a chat
/// - `watch.subscribe` -- start streaming new messages for a chat
/// - `watch.unsubscribe` -- cancel a watch subscription
/// - `send` -- send a message via iMessage/SMS
/// - `typing.start` / `typing.stop` -- toggle typing indicators
/// - `health` -- liveness check
final class RPCServer {
    let store: MessageStore
    let watcher: MessageWatcher
    let cache: ChatCache
    let subscriptions = SubscriptionStore()
    let sendMessage: (MessageSendOptions) throws -> Void
    let startTyping: (String) throws -> Void
    let stopTyping: (String) throws -> Void

    /// Creates a new RPC server backed by the given message store.
    ///
    /// - Parameters:
    ///   - store: The iMessage database accessor.
    ///   - sendMessage: Closure invoked to send outgoing messages. Defaults to `MessageSender().send(_:)`.
    ///   - startTyping: Closure invoked to begin a typing indicator. Defaults to `TypingIndicator.startTyping(chatIdentifier:)`.
    ///   - stopTyping: Closure invoked to stop a typing indicator. Defaults to `TypingIndicator.stopTyping(chatIdentifier:)`.
    init(
        store: MessageStore,
        sendMessage: @escaping (MessageSendOptions) throws -> Void = { try MessageSender().send($0) },
        startTyping: @escaping (String) throws -> Void = { try TypingIndicator.startTyping(chatIdentifier: $0) },
        stopTyping: @escaping (String) throws -> Void = { try TypingIndicator.stopTyping(chatIdentifier: $0) }
    ) {
        self.store = store
        self.sendMessage = sendMessage
        self.startTyping = startTyping
        self.stopTyping = stopTyping
        self.watcher = MessageWatcher(store: store)
        self.cache = ChatCache(store: store)
    }

    // MARK: - Main Event Loop

    /// Runs the server, reading JSON-RPC requests from stdin until EOF.
    ///
    /// Each non-empty line is parsed and dispatched to the corresponding handler.
    /// When stdin closes, all active watch subscriptions are cancelled before returning.
    func run() async {
        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            await handleLine(trimmed)
        }
        await subscriptions.cancelAll()
    }

    // MARK: - Request Dispatch

    /// Parses a single line of JSON-RPC input and dispatches to the appropriate handler.
    ///
    /// - Parameter line: A single JSON-RPC 2.0 request string.
    func handleLine(_ line: String) async {
        guard let data = line.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = parsed as? [String: Any]
        else {
            sendError(id: nil, error: .parseError("Invalid JSON"))
            return
        }

        guard let method = dict["method"] as? String else {
            let id = dict["id"]
            sendError(id: id, error: .invalidRequest("Missing 'method' field"))
            return
        }

        let params = (dict["params"] as? [String: Any]) ?? [:]
        let id = dict["id"]

        do {
            switch method {
            case "chats.list":
                try await handleChatsList(id: id, params: params)
            case "messages.history":
                try await handleMessagesHistory(id: id, params: params)
            case "watch.subscribe":
                try await handleWatchSubscribe(id: id, params: params)
            case "watch.unsubscribe":
                try await handleWatchUnsubscribe(id: id, params: params)
            case "send":
                try await handleSend(id: id, params: params)
            case "typing.start":
                try await handleTyping(id: id, params: params, start: true)
            case "typing.stop":
                try await handleTyping(id: id, params: params, start: false)
            case "health":
                respond(id: id, result: ["ok": true, "version": "0.1.0"])
            default:
                sendError(id: id, error: .methodNotFound(method))
            }
        } catch let rpcError as RPCError {
            sendError(id: id, error: rpcError)
        } catch let imsgError as AppMeeeIMsgError {
            switch imsgError {
            case .invalidService, .invalidChatTarget:
                sendError(
                    id: id,
                    error: .invalidParams(imsgError.localizedDescription)
                )
            default:
                sendError(
                    id: id,
                    error: .internalError(imsgError.localizedDescription)
                )
            }
        } catch {
            sendError(id: id, error: .internalError(error.localizedDescription))
        }
    }

    // MARK: - Response Helpers

    /// Sends a successful JSON-RPC 2.0 response.
    ///
    /// If `id` is nil (notification request), no response is emitted.
    ///
    /// - Parameters:
    ///   - id: The request identifier from the incoming message.
    ///   - result: The result payload to include in the response.
    func respond(id: Any?, result: Any) {
        guard let id else { return }
        var response: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let intID = id as? Int { response["id"] = intID }
        else if let int64ID = id as? Int64 { response["id"] = int64ID }
        else if let strID = id as? String { response["id"] = strID }
        else { response["id"] = String(describing: id) }
        StdoutWriter.writeJSON(response)
    }

    /// Sends a JSON-RPC 2.0 error response.
    ///
    /// When `id` is nil, `NSNull()` is used per the JSON-RPC spec for parse errors
    /// and invalid requests where the id cannot be determined.
    ///
    /// - Parameters:
    ///   - id: The request identifier, or nil if unknown.
    ///   - error: The structured RPC error to return.
    func sendError(id: Any?, error: RPCError) {
        var response: [String: Any] = ["jsonrpc": "2.0", "error": error.toDictionary()]
        if let id {
            if let intID = id as? Int { response["id"] = intID }
            else if let int64ID = id as? Int64 { response["id"] = int64ID }
            else if let strID = id as? String { response["id"] = strID }
            else { response["id"] = String(describing: id) }
        } else {
            response["id"] = NSNull()
        }
        StdoutWriter.writeJSON(response)
    }

    /// Sends a JSON-RPC 2.0 notification (server-to-client, no id).
    ///
    /// Used for streaming events like new messages from watch subscriptions.
    ///
    /// - Parameters:
    ///   - method: The notification method name.
    ///   - params: The notification payload.
    func sendNotification(method: String, params: [String: Any]) {
        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ]
        StdoutWriter.writeJSON(notification)
    }
}
