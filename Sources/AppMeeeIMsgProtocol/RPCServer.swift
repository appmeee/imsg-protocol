import AppMeeeIMsgCore
import Foundation

// MARK: - StdoutWriter

/// Thread-safe namespace for writing line-delimited JSON to stdout.
enum StdoutWriter {
    private static let queue = DispatchQueue(label: "appmeee.imsg.stdout", qos: .userInitiated)

    static func writeLine(_ line: String) {
        queue.sync {
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }
    }

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
/// appropriate handler method, and writes JSON responses via the `output` writer.
final class RPCServer {
    let store: MessageStore
    let watcher: MessageWatcher
    let output: RPCOutput
    let cache: ChatCache
    let subscriptions = SubscriptionStore()
    let verbose: Bool
    let sendMessage: (MessageSendOptions) throws -> Void
    let sendReaction: (ReactionType, String, String) throws -> Void
    let startTyping: (String) throws -> Void
    let stopTyping: (String) throws -> Void

    init(
        store: MessageStore,
        verbose: Bool = false,
        output: RPCOutput = RPCWriter(),
        sendMessage: @escaping (MessageSendOptions) throws -> Void = { try MessageSender().send($0) },
        sendReaction: @escaping (ReactionType, String, String) throws -> Void = { type, guid, lookup in
            try ReactionSender.send(reactionType: type, chatGUID: guid, chatLookup: lookup)
        },
        startTyping: @escaping (String) throws -> Void = { try TypingIndicator.startTyping(chatIdentifier: $0) },
        stopTyping: @escaping (String) throws -> Void = { try TypingIndicator.stopTyping(chatIdentifier: $0) }
    ) {
        self.store = store
        self.watcher = MessageWatcher(store: store)
        self.cache = ChatCache(store: store)
        self.verbose = verbose
        self.output = output
        self.sendMessage = sendMessage
        self.sendReaction = sendReaction
        self.startTyping = startTyping
        self.stopTyping = stopTyping
    }

    // MARK: - Main Event Loop

    func run() async throws {
        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            await handleLine(trimmed)
        }
        await subscriptions.cancelAll()
    }

    /// Exposed for testing.
    func handleLineForTesting(_ line: String) async {
        await handleLine(line)
    }

    // MARK: - Response Helpers

    func respond(id: Any?, result: Any) {
        guard let id else { return }
        output.sendResponse(id: id, result: result)
    }

    // MARK: - Request Dispatch

    private func handleLine(_ line: String) async {
        guard let data = line.data(using: .utf8) else {
            output.sendError(id: nil, error: .parseError("invalid utf8"))
            return
        }

        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            output.sendError(id: nil, error: .parseError(error.localizedDescription))
            return
        }

        guard let request = json as? [String: Any] else {
            output.sendError(id: nil, error: .invalidRequest("request must be an object"))
            return
        }

        // Validate jsonrpc version if present
        let jsonrpc = request["jsonrpc"] as? String
        if jsonrpc != nil && jsonrpc != "2.0" {
            output.sendError(id: request["id"], error: .invalidRequest("jsonrpc must be 2.0"))
            return
        }

        guard let method = request["method"] as? String, !method.isEmpty else {
            output.sendError(id: request["id"], error: .invalidRequest("method is required"))
            return
        }

        let params = request["params"] as? [String: Any] ?? [:]
        let id = request["id"]

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
                try await handleSend(params: params, id: id)
            case "typing.start":
                try await handleTyping(params: params, id: id, start: true)
            case "typing.stop":
                try await handleTyping(params: params, id: id, start: false)
            case "react":
                try await handleReact(params: params, id: id)
            case "health":
                respond(id: id, result: ["ok": true, "version": "0.2.0"])
            default:
                output.sendError(id: id, error: .methodNotFound(method))
            }
        } catch let err as RPCError {
            output.sendError(id: id, error: err)
        } catch let err as AppMeeeIMsgError {
            switch err {
            case .invalidService, .invalidChatTarget, .invalidReaction:
                output.sendError(id: id, error: .invalidParams(err.localizedDescription))
            default:
                output.sendError(id: id, error: .internalError(err.localizedDescription))
            }
        } catch {
            output.sendError(id: id, error: .internalError(error.localizedDescription))
        }
    }
}
