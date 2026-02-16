import Foundation
import AppMeeeIMsgCore

// MARK: - RPCError

/// A JSON-RPC 2.0 error with a numeric code and human-readable message.
struct RPCError: Error, Sendable {
    let code: Int
    let message: String

    static func parseError(_ message: String) -> RPCError {
        RPCError(code: -32700, message: message)
    }

    static func invalidRequest(_ message: String) -> RPCError {
        RPCError(code: -32600, message: message)
    }

    static func methodNotFound(_ message: String) -> RPCError {
        RPCError(code: -32601, message: message)
    }

    static func invalidParams(_ message: String) -> RPCError {
        RPCError(code: -32602, message: message)
    }

    static func internalError(_ message: String) -> RPCError {
        RPCError(code: -32603, message: message)
    }

    func toDictionary() -> [String: Any] {
        ["code": code, "message": message]
    }
}

// MARK: - SubscriptionStore

/// Actor-isolated store for managing active watch subscription tasks.
actor SubscriptionStore {
    private var nextID: Int = 1
    private var tasks: [Int: Task<Void, Never>] = [:]

    /// Returns the next available subscription ID and increments the counter.
    func allocateID() -> Int {
        let id = nextID
        nextID += 1
        return id
    }

    /// Stores a background task for the given subscription ID.
    func insert(_ task: Task<Void, Never>, for id: Int) {
        tasks[id] = task
    }

    /// Removes and returns the task for the given subscription ID.
    @discardableResult
    func remove(_ id: Int) -> Task<Void, Never>? {
        tasks.removeValue(forKey: id)
    }

    /// Cancels every active subscription and clears the store.
    func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
    }
}

// MARK: - ChatCache

/// Actor-isolated cache for chat metadata and participant lists.
///
/// Avoids repeated SQLite queries for the same chat during a single
/// server session by caching results from `MessageStore`.
actor ChatCache {
    private let store: MessageStore
    private var infoCache: [Int64: ChatInfo?] = [:]
    private var participantsCache: [Int64: [String]] = [:]

    init(store: MessageStore) {
        self.store = store
    }

    /// Returns cached chat info, or queries the store on first access.
    func info(chatID: Int64) throws -> ChatInfo? {
        if let cached = infoCache[chatID] {
            return cached
        }
        let result = try store.chatInfo(chatID: chatID)
        infoCache[chatID] = result
        return result
    }

    /// Returns cached participant list, or queries the store on first access.
    func participants(chatID: Int64) throws -> [String] {
        if let cached = participantsCache[chatID] {
            return cached
        }
        let result = try store.participants(chatID: chatID)
        participantsCache[chatID] = result
        return result
    }
}

// MARK: - ISO8601Formatter

/// Namespace for thread-safe ISO 8601 date formatting.
enum ISO8601Formatter {
    private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Formats a `Date` as an ISO 8601 string with fractional seconds.
    static func format(_ date: Date) -> String {
        formatter.string(from: date)
    }
}

// MARK: - Payload Builders

/// Builds a JSON-compatible dictionary representing a chat.
func chatPayload(
    id: Int64,
    identifier: String,
    guid: String,
    name: String?,
    service: String,
    lastMessageDate: Date?,
    participants: [String]
) -> [String: Any] {
    let isGroup = identifier.contains(";+;") || guid.contains(";+;")

    var dict: [String: Any] = [
        "id": id,
        "identifier": identifier,
        "guid": guid,
        "service": service,
        "participants": participants,
        "is_group": isGroup,
    ]

    dict["name"] = name as Any? ?? NSNull()

    if let date = lastMessageDate {
        dict["last_message_at"] = ISO8601Formatter.format(date)
    } else {
        dict["last_message_at"] = NSNull()
    }

    return dict
}

/// Builds a JSON-compatible dictionary representing a message with all related data.
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

    let dict: [String: Any] = [
        "id": message.rowID,
        "chat_id": message.chatID,
        "guid": message.guid,
        "sender": message.sender,
        "is_from_me": message.isFromMe,
        "text": message.text as Any? ?? NSNull(),
        "created_at": ISO8601Formatter.format(message.date),
        "service": message.service,
        "has_attachments": message.hasAttachments,
        "is_reaction": message.isReaction,
        "reaction_type": message.reactionType?.name as Any? ?? NSNull(),
        "reaction_emoji": message.reactionType?.emoji as Any? ?? NSNull(),
        "is_reaction_removal": message.isReactionRemoval,
        "associated_message_guid": message.associatedMessageGUID as Any? ?? NSNull(),
        "reply_to_guid": message.replyToGUID as Any? ?? NSNull(),
        "chat_identifier": chatIdentifier,
        "chat_guid": chatGUID,
        "chat_name": chatInfo?.name as Any? ?? NSNull(),
        "participants": participants,
        "is_group": isGroup,
        "attachments": attachments.map { attachmentPayload($0) },
        "reactions": reactions.map { reactionPayload($0) },
    ]

    return dict
}

/// Builds a JSON-compatible dictionary representing an attachment.
func attachmentPayload(_ meta: AttachmentMeta) -> [String: Any] {
    [
        "filename": meta.filename as Any? ?? NSNull(),
        "transfer_name": meta.transferName as Any? ?? NSNull(),
        "uti": meta.uti as Any? ?? NSNull(),
        "mime_type": meta.mimeType as Any? ?? NSNull(),
        "total_bytes": meta.totalBytes,
        "is_sticker": meta.isSticker,
        "original_path": meta.originalPath as Any? ?? NSNull(),
        "missing": meta.missing,
    ]
}

/// Builds a JSON-compatible dictionary representing a reaction.
func reactionPayload(_ reaction: Reaction) -> [String: Any] {
    [
        "type": reaction.reactionType?.name as Any? ?? NSNull(),
        "emoji": reaction.reactionType?.emoji as Any? ?? NSNull(),
        "sender": reaction.sender,
        "is_from_me": reaction.isFromMe,
        "is_removal": reaction.isRemoval,
        "created_at": ISO8601Formatter.format(reaction.date),
    ]
}

// MARK: - Parameter Extraction Helpers

/// Extracts a `String` from a loosely-typed JSON parameter value.
func stringParam(_ value: Any?) -> String? {
    guard let value else { return nil }
    if let s = value as? String { return s }
    if let i = value as? Int { return String(i) }
    if let i = value as? Int64 { return String(i) }
    if let d = value as? Double { return String(d) }
    if let b = value as? Bool { return b ? "true" : "false" }
    return nil
}

/// Extracts an `Int` from a loosely-typed JSON parameter value.
func intParam(_ value: Any?) -> Int? {
    guard let value else { return nil }
    if let i = value as? Int { return i }
    if let i = value as? Int64 { return Int(exactly: i) }
    if let d = value as? Double { return Int(exactly: d) }
    if let s = value as? String { return Int(s) }
    return nil
}

/// Extracts an `Int64` from a loosely-typed JSON parameter value.
func int64Param(_ value: Any?) -> Int64? {
    guard let value else { return nil }
    if let i = value as? Int64 { return i }
    if let i = value as? Int { return Int64(i) }
    if let d = value as? Double { return Int64(exactly: d) }
    if let s = value as? String { return Int64(s) }
    return nil
}

/// Extracts a `Bool` from a loosely-typed JSON parameter value.
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
