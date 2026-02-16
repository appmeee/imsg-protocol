import Foundation
import AppMeeeIMsgCore

// MARK: - RPCOutput Protocol

/// Abstraction for JSON-RPC output, enabling testability.
protocol RPCOutput: Sendable {
    func sendResponse(id: Any, result: Any)
    func sendError(id: Any?, error: RPCError)
    func sendNotification(method: String, params: Any)
}

// MARK: - RPCWriter

/// Default `RPCOutput` implementation that writes to stdout.
final class RPCWriter: RPCOutput, Sendable {
    func sendResponse(id: Any, result: Any) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func sendError(id: Any?, error: RPCError) {
        send([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": error.toDictionary(),
        ])
    }

    func sendNotification(method: String, params: Any) {
        send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func send(_ object: Any) {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            if let output = String(data: data, encoding: .utf8) {
                StdoutWriter.writeLine(output)
            }
        } catch {
            StdoutWriter.writeLine(
                "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"write failed\"}}"
            )
        }
    }
}

// MARK: - RPCError

/// A JSON-RPC 2.0 error with a numeric code and human-readable message.
struct RPCError: Error, Sendable {
    let code: Int
    let message: String
    let data: String?

    init(code: Int, message: String, data: String? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    static func parseError(_ message: String) -> RPCError {
        RPCError(code: -32700, message: "Parse error", data: message)
    }

    static func invalidRequest(_ message: String) -> RPCError {
        RPCError(code: -32600, message: "Invalid Request", data: message)
    }

    static func methodNotFound(_ method: String) -> RPCError {
        RPCError(code: -32601, message: "Method not found", data: method)
    }

    static func invalidParams(_ message: String) -> RPCError {
        RPCError(code: -32602, message: "Invalid params", data: message)
    }

    static func internalError(_ message: String) -> RPCError {
        RPCError(code: -32603, message: "Internal error", data: message)
    }

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = ["code": code, "message": message]
        if let data { dict["data"] = data }
        return dict
    }
}

// MARK: - SubscriptionStore

/// Actor-isolated store for managing active watch subscription tasks.
actor SubscriptionStore {
    private var nextID: Int = 1
    private var tasks: [Int: Task<Void, Never>] = [:]

    func allocateID() -> Int {
        let id = nextID
        nextID += 1
        return id
    }

    func insert(_ task: Task<Void, Never>, for id: Int) {
        tasks[id] = task
    }

    @discardableResult
    func remove(_ id: Int) -> Task<Void, Never>? {
        tasks.removeValue(forKey: id)
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }
}

// MARK: - ChatCache

/// Actor-isolated cache for chat metadata and participant lists.
actor ChatCache {
    private let store: MessageStore
    private var infoCache: [Int64: ChatInfo] = [:]
    private var participantsCache: [Int64: [String]] = [:]

    init(store: MessageStore) {
        self.store = store
    }

    func info(chatID: Int64) throws -> ChatInfo? {
        if let cached = infoCache[chatID] { return cached }
        if let info = try store.chatInfo(chatID: chatID) {
            infoCache[chatID] = info
            return info
        }
        return nil
    }

    func participants(chatID: Int64) throws -> [String] {
        if let cached = participantsCache[chatID] { return cached }
        let participants = try store.participants(chatID: chatID)
        participantsCache[chatID] = participants
        return participants
    }
}

// MARK: - ISO8601Formatter

enum ISO8601Formatter {
    private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func format(_ date: Date) -> String {
        formatter.string(from: date)
    }
}

// MARK: - Payload Builders

func chatPayload(
    id: Int64,
    identifier: String,
    guid: String,
    name: String,
    service: String,
    lastMessageAt: Date,
    participants: [String]
) -> [String: Any] {
    let isGroup = identifier.contains(";+;") || guid.contains(";+;")
    return [
        "id": id,
        "identifier": identifier,
        "guid": guid,
        "name": name,
        "service": service,
        "participants": participants,
        "is_group": isGroup,
        "last_message_at": ISO8601Formatter.format(lastMessageAt),
    ]
}

func messagePayload(
    message: Message,
    chatInfo: ChatInfo?,
    participants: [String],
    attachments: [AttachmentMeta],
    reactions: [Reaction]
) -> [String: Any] {
    let chatIdentifier = chatInfo?.identifier ?? ""
    let chatGUID = chatInfo?.guid ?? ""
    let isGroup = chatIdentifier.contains(";+;") || chatGUID.contains(";+;")

    return [
        "id": message.rowID,
        "chat_id": message.chatID,
        "guid": message.guid,
        "sender": message.sender,
        "is_from_me": message.isFromMe,
        "text": message.text,
        "created_at": ISO8601Formatter.format(message.date),
        "service": message.service,
        "handle_id": message.handleID as Any? ?? NSNull(),
        "attachments_count": message.attachmentsCount,
        "is_reaction": message.isReaction,
        "reaction_type": message.reactionType?.name as Any? ?? NSNull(),
        "reaction_emoji": message.reactionType?.emoji as Any? ?? NSNull(),
        "is_reaction_add": message.isReactionAdd as Any? ?? NSNull(),
        "reacted_to_guid": message.reactedToGUID as Any? ?? NSNull(),
        "reply_to_guid": message.replyToGUID as Any? ?? NSNull(),
        "thread_originator_guid": message.threadOriginatorGUID as Any? ?? NSNull(),
        "destination_caller_id": message.destinationCallerID as Any? ?? NSNull(),
        "chat_identifier": chatIdentifier,
        "chat_guid": chatGUID,
        "chat_name": chatInfo?.name as Any? ?? NSNull(),
        "participants": participants,
        "is_group": isGroup,
        "attachments": attachments.map { attachmentPayload($0) },
        "reactions": reactions.map { reactionPayload($0) },
    ]
}

func attachmentPayload(_ meta: AttachmentMeta) -> [String: Any] {
    [
        "filename": meta.filename,
        "transfer_name": meta.transferName,
        "uti": meta.uti,
        "mime_type": meta.mimeType,
        "total_bytes": meta.totalBytes,
        "is_sticker": meta.isSticker,
        "original_path": meta.originalPath,
        "missing": meta.missing,
    ]
}

func reactionPayload(_ reaction: Reaction) -> [String: Any] {
    [
        "row_id": reaction.rowID,
        "type": reaction.reactionType.name,
        "emoji": reaction.reactionType.emoji,
        "sender": reaction.sender,
        "is_from_me": reaction.isFromMe,
        "associated_message_id": reaction.associatedMessageID,
        "created_at": ISO8601Formatter.format(reaction.date),
    ]
}

func reactionEventPayload(_ event: ReactionEvent) -> [String: Any] {
    [
        "row_id": event.rowID,
        "chat_id": event.chatID,
        "type": event.reactionType.name,
        "emoji": event.reactionType.emoji,
        "is_add": event.isAdd,
        "sender": event.sender,
        "is_from_me": event.isFromMe,
        "reacted_to_guid": event.reactedToGUID,
        "reacted_to_id": event.reactedToID as Any? ?? NSNull(),
        "text": event.text,
        "created_at": ISO8601Formatter.format(event.date),
    ]
}

// MARK: - Parameter Extraction Helpers

func stringParam(_ value: Any?) -> String? {
    guard let value else { return nil }
    if let s = value as? String { return s }
    if let i = value as? Int { return String(i) }
    if let i = value as? Int64 { return String(i) }
    if let d = value as? Double { return String(d) }
    if let b = value as? Bool { return b ? "true" : "false" }
    return nil
}

func stringArrayParam(_ value: Any?) -> [String] {
    guard let array = value as? [Any] else { return [] }
    return array.compactMap { stringParam($0) }
}

func intParam(_ value: Any?) -> Int? {
    guard let value else { return nil }
    if let i = value as? Int { return i }
    if let i = value as? Int64 { return Int(exactly: i) }
    if let d = value as? Double { return Int(exactly: d) }
    if let s = value as? String { return Int(s) }
    return nil
}

func int64Param(_ value: Any?) -> Int64? {
    guard let value else { return nil }
    if let i = value as? Int64 { return i }
    if let i = value as? Int { return Int64(i) }
    if let d = value as? Double { return Int64(exactly: d) }
    if let s = value as? String { return Int64(s) }
    return nil
}

func boolParam(_ value: Any?) -> Bool? {
    guard let value else { return nil }
    if let b = value as? Bool { return b }
    if let i = value as? Int { return i != 0 }
    if let i = value as? Int64 { return i != 0 }
    if let d = value as? Double { return d != 0 }
    if let s = value as? String {
        switch s.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }
    return nil
}
