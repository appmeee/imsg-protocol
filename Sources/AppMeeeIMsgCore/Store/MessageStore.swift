import Foundation
import SQLite

// MARK: - MessageStore

/// Thread-safe, read-only accessor for macOS's iMessage database (chat.db).
///
/// Opens `~/Library/Messages/chat.db` in read-only WAL mode and exposes
/// queries for chats, messages, attachments, reactions, and reaction events.
///
/// - Important: Full Disk Access must be granted to the process.
public final class MessageStore: @unchecked Sendable {

    // MARK: - Constants

    /// Seconds between the Unix epoch (1970-01-01) and Apple's reference date (2001-01-01).
    static let appleEpochOffset: TimeInterval = 978_307_200

    // MARK: - Properties

    /// The resolved file path to the chat.db file.
    public let path: String

    /// Default path for the current user's iMessage database.
    public static var defaultPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return NSString(string: home).appendingPathComponent("Library/Messages/chat.db")
    }

    private let connection: Connection
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()

    // MARK: Column availability flags

    let hasAttributedBody: Bool
    let hasReactionColumns: Bool
    let hasThreadOriginatorGUIDColumn: Bool
    let hasDestinationCallerID: Bool
    let hasAudioMessageColumn: Bool
    let hasAttachmentUserInfo: Bool
    private let hasAttachmentIsSticker: Bool

    // MARK: - Initialization

    /// Opens the iMessage database at the given path in read-only mode.
    ///
    /// - Parameter path: File path to `chat.db`. Defaults to `~/Library/Messages/chat.db`.
    /// - Throws: `AppMeeeIMsgError` if the file cannot be opened or lacks required permissions.
    public init(path: String = MessageStore.defaultPath) throws {
        let normalized = NSString(string: path).expandingTildeInPath
        self.path = normalized
        self.queue = DispatchQueue(label: "com.appmeee.imsg.messagestore", qos: .userInitiated)
        self.queue.setSpecific(key: queueKey, value: ())

        do {
            self.connection = try Connection(normalized, readonly: true)
            self.connection.busyTimeout = 5
        } catch {
            throw MessageStore.enhance(error: error, path: normalized)
        }

        let messageColumns = MessageStore.tableColumns(connection: connection, table: "message")
        let attachmentColumns = MessageStore.tableColumns(connection: connection, table: "attachment")

        self.hasAttributedBody = messageColumns.contains("attributedbody")
        self.hasReactionColumns = MessageStore.reactionColumnsPresent(in: messageColumns)
        self.hasThreadOriginatorGUIDColumn = messageColumns.contains("thread_originator_guid")
        self.hasDestinationCallerID = messageColumns.contains("destination_caller_id")
        self.hasAudioMessageColumn = messageColumns.contains("is_audio_message")
        self.hasAttachmentUserInfo = attachmentColumns.contains("user_info")
        self.hasAttachmentIsSticker = attachmentColumns.contains("is_sticker")
    }

    /// Test-friendly initializer that accepts a pre-opened connection.
    init(
        connection: Connection,
        path: String,
        hasAttributedBody: Bool? = nil,
        hasReactionColumns: Bool? = nil,
        hasThreadOriginatorGUIDColumn: Bool? = nil,
        hasDestinationCallerID: Bool? = nil,
        hasAudioMessageColumn: Bool? = nil,
        hasAttachmentUserInfo: Bool? = nil
    ) throws {
        self.path = path
        self.queue = DispatchQueue(label: "com.appmeee.imsg.messagestore.test", qos: .userInitiated)
        self.queue.setSpecific(key: queueKey, value: ())
        self.connection = connection
        self.connection.busyTimeout = 5

        let messageColumns = MessageStore.tableColumns(connection: connection, table: "message")
        let attachmentColumns = MessageStore.tableColumns(connection: connection, table: "attachment")

        self.hasAttributedBody = hasAttributedBody ?? messageColumns.contains("attributedbody")
        self.hasReactionColumns = hasReactionColumns ?? MessageStore.reactionColumnsPresent(in: messageColumns)
        self.hasThreadOriginatorGUIDColumn = hasThreadOriginatorGUIDColumn ?? messageColumns.contains("thread_originator_guid")
        self.hasDestinationCallerID = hasDestinationCallerID ?? messageColumns.contains("destination_caller_id")
        self.hasAudioMessageColumn = hasAudioMessageColumn ?? messageColumns.contains("is_audio_message")
        self.hasAttachmentUserInfo = hasAttachmentUserInfo ?? attachmentColumns.contains("user_info")
        self.hasAttachmentIsSticker = attachmentColumns.contains("is_sticker")
    }

    // MARK: - Queue Helper

    /// Executes a closure on the serial queue, ensuring thread-safe database access.
    func withConnection<T>(_ block: (Connection) throws -> T) throws -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try block(connection)
        }
        return try queue.sync {
            try block(connection)
        }
    }

    // MARK: - Public API: Chats

    /// Lists chats ordered by most recent message activity.
    public func listChats(limit: Int) throws -> [Chat] {
        let sql = """
            SELECT c.ROWID, IFNULL(c.display_name, c.chat_identifier) AS name,
                   c.chat_identifier, c.service_name, MAX(m.date) AS last_date
            FROM chat c
            JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
            JOIN message m ON m.ROWID = cmj.message_id
            GROUP BY c.ROWID
            ORDER BY last_date DESC
            LIMIT ?
            """
        return try withConnection { db in
            var chats: [Chat] = []
            for row in try db.prepare(sql, limit) {
                let id = int64Value(row[0]) ?? 0
                let name = stringValue(row[1])
                let identifier = stringValue(row[2])
                let service = stringValue(row[3])
                let lastDate = appleDate(from: int64Value(row[4]))
                chats.append(Chat(
                    id: id, identifier: identifier, name: name,
                    service: service, lastMessageAt: lastDate
                ))
            }
            return chats
        }
    }

    /// Returns detailed information about a single chat.
    public func chatInfo(chatID: Int64) throws -> ChatInfo? {
        let sql = """
            SELECT c.ROWID, IFNULL(c.chat_identifier, '') AS identifier,
                   IFNULL(c.guid, '') AS guid,
                   IFNULL(c.display_name, c.chat_identifier) AS name,
                   IFNULL(c.service_name, '') AS service
            FROM chat c
            WHERE c.ROWID = ?
            LIMIT 1
            """
        return try withConnection { db in
            for row in try db.prepare(sql, chatID) {
                return ChatInfo(
                    id: int64Value(row[0]) ?? chatID,
                    identifier: stringValue(row[1]),
                    guid: stringValue(row[2]),
                    name: stringValue(row[3]),
                    service: stringValue(row[4])
                )
            }
            return nil
        }
    }

    /// Returns the participant handle IDs for a chat.
    public func participants(chatID: Int64) throws -> [String] {
        let sql = """
            SELECT h.id
            FROM chat_handle_join chj
            JOIN handle h ON h.ROWID = chj.handle_id
            WHERE chj.chat_id = ?
            ORDER BY h.id ASC
            """
        return try withConnection { db in
            var results: [String] = []
            var seen = Set<String>()
            for row in try db.prepare(sql, chatID) {
                let handle = stringValue(row[0])
                if handle.isEmpty { continue }
                if seen.insert(handle).inserted {
                    results.append(handle)
                }
            }
            return results
        }
    }

    /// Returns the highest ROWID in the message table.
    public func maxRowID() throws -> Int64 {
        try withConnection { db in
            let value = try db.scalar("SELECT MAX(ROWID) FROM message")
            return int64Value(value) ?? 0
        }
    }
}

// MARK: - Message Queries

extension MessageStore {

    /// Fetches messages for a chat, most recent first.
    public func messages(chatID: Int64, limit: Int) throws -> [Message] {
        try messages(chatID: chatID, limit: limit, filter: nil)
    }

    /// Fetches messages for a chat with optional filtering.
    public func messages(chatID: Int64, limit: Int, filter: MessageFilter?) throws -> [Message] {
        let bodyColumn = hasAttributedBody ? "m.attributedBody" : "NULL"
        let guidColumn = hasReactionColumns ? "m.guid" : "NULL"
        let associatedGuidColumn = hasReactionColumns ? "m.associated_message_guid" : "NULL"
        let associatedTypeColumn = hasReactionColumns ? "m.associated_message_type" : "NULL"
        let destinationCallerColumn = hasDestinationCallerID ? "m.destination_caller_id" : "NULL"
        let audioMessageColumn = hasAudioMessageColumn ? "m.is_audio_message" : "0"
        let threadOriginatorColumn = hasThreadOriginatorGUIDColumn ? "m.thread_originator_guid" : "NULL"
        let reactionFilter = hasReactionColumns
            ? " AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000 OR m.associated_message_type > 3006)"
            : ""

        var sql = """
            SELECT m.ROWID, m.handle_id, h.id, IFNULL(m.text, '') AS text, m.date, m.is_from_me, m.service,
                   \(audioMessageColumn) AS is_audio_message, \(destinationCallerColumn) AS destination_caller_id,
                   \(guidColumn) AS guid, \(associatedGuidColumn) AS associated_guid, \(associatedTypeColumn) AS associated_type,
                   (SELECT COUNT(*) FROM message_attachment_join maj WHERE maj.message_id = m.ROWID) AS attachments,
                   \(bodyColumn) AS body,
                   \(threadOriginatorColumn) AS thread_originator_guid
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE cmj.chat_id = ?\(reactionFilter)
            """
        var bindings: [Binding?] = [chatID]

        if let filter {
            if let startDate = filter.startDate {
                sql += " AND m.date >= ?"
                bindings.append(MessageStore.appleEpoch(startDate))
            }
            if let endDate = filter.endDate {
                sql += " AND m.date < ?"
                bindings.append(MessageStore.appleEpoch(endDate))
            }
            if !filter.participants.isEmpty {
                let placeholders = Array(repeating: "?", count: filter.participants.count).joined(separator: ",")
                sql += " AND COALESCE(NULLIF(h.id,''), \(destinationCallerColumn)) COLLATE NOCASE IN (\(placeholders))"
                for participant in filter.participants {
                    bindings.append(participant)
                }
            }
            if let fromMe = filter.fromMe {
                sql += " AND m.is_from_me = ?"
                bindings.append(fromMe ? 1 : 0)
            }
        }

        // text_contains is applied post-decode because macOS often stores
        // message text in attributedBody rather than m.text. Over-fetch to
        // compensate for post-filtering.
        let hasTextFilter = filter?.textContains != nil && !filter!.textContains!.isEmpty
        let sqlLimit = hasTextFilter ? limit * 10 : limit

        sql += " ORDER BY m.date DESC LIMIT ?"
        bindings.append(sqlLimit)

        let columns = MessageRowColumns(
            rowID: 0, chatID: nil, handleID: 1, sender: 2, text: 3,
            date: 4, isFromMe: 5, service: 6, isAudioMessage: 7,
            destinationCallerID: 8, guid: 9, associatedGUID: 10,
            associatedType: 11, attachments: 12, body: 13, threadOriginatorGUID: 14
        )

        return try withConnection { db in
            var messages: [Message] = []
            for row in try db.prepare(sql, bindings) {
                let decoded = try decodeMessageRow(row, columns: columns, fallbackChatID: chatID)
                let replyToGUID = self.replyToGUID(
                    associatedGuid: decoded.associatedGUID,
                    associatedType: decoded.associatedType
                )
                messages.append(Message(
                    rowID: decoded.rowID,
                    chatID: decoded.chatID,
                    sender: decoded.sender,
                    text: decoded.text,
                    date: decoded.date,
                    isFromMe: decoded.isFromMe,
                    service: decoded.service,
                    handleID: decoded.handleID,
                    attachmentsCount: decoded.attachments,
                    guid: decoded.guid,
                    routing: Message.RoutingMetadata(
                        replyToGUID: replyToGUID,
                        threadOriginatorGUID: decoded.threadOriginatorGUID.isEmpty ? nil : decoded.threadOriginatorGUID,
                        destinationCallerID: decoded.destinationCallerID.isEmpty ? nil : decoded.destinationCallerID
                    )
                ))
            }
            if hasTextFilter, let textContains = filter?.textContains {
                return Array(messages.filter {
                    $0.text.localizedCaseInsensitiveContains(textContains)
                }.prefix(limit))
            }
            return messages
        }
    }

    /// Fetches messages with ROWID greater than the given value, in ascending order.
    public func messagesAfter(afterRowID: Int64, chatID: Int64?, limit: Int) throws -> [Message] {
        try messagesAfter(afterRowID: afterRowID, chatID: chatID, limit: limit, includeReactions: false)
    }

    /// Fetches messages after a ROWID with optional reaction inclusion.
    public func messagesAfter(
        afterRowID: Int64,
        chatID: Int64?,
        limit: Int,
        includeReactions: Bool
    ) throws -> [Message] {
        let bodyColumn = hasAttributedBody ? "m.attributedBody" : "NULL"
        let guidColumn = hasReactionColumns ? "m.guid" : "NULL"
        let associatedGuidColumn = hasReactionColumns ? "m.associated_message_guid" : "NULL"
        let associatedTypeColumn = hasReactionColumns ? "m.associated_message_type" : "NULL"
        let destinationCallerColumn = hasDestinationCallerID ? "m.destination_caller_id" : "NULL"
        let audioMessageColumn = hasAudioMessageColumn ? "m.is_audio_message" : "0"
        let threadOriginatorColumn = hasThreadOriginatorGUIDColumn ? "m.thread_originator_guid" : "NULL"

        let reactionFilter: String
        if includeReactions || !hasReactionColumns {
            reactionFilter = ""
        } else {
            reactionFilter = " AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000 OR m.associated_message_type > 3006)"
        }

        var sql = """
            SELECT m.ROWID, cmj.chat_id, m.handle_id, h.id, IFNULL(m.text, '') AS text, m.date, m.is_from_me, m.service,
                   \(audioMessageColumn) AS is_audio_message, \(destinationCallerColumn) AS destination_caller_id,
                   \(guidColumn) AS guid, \(associatedGuidColumn) AS associated_guid, \(associatedTypeColumn) AS associated_type,
                   (SELECT COUNT(*) FROM message_attachment_join maj WHERE maj.message_id = m.ROWID) AS attachments,
                   \(bodyColumn) AS body,
                   \(threadOriginatorColumn) AS thread_originator_guid
            FROM message m
            LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE m.ROWID > ?\(reactionFilter)
            """
        var bindings: [Binding?] = [afterRowID]

        if let chatID {
            sql += " AND cmj.chat_id = ?"
            bindings.append(chatID)
        }
        sql += " ORDER BY m.ROWID ASC LIMIT ?"
        bindings.append(limit)

        let columns = MessageRowColumns(
            rowID: 0, chatID: 1, handleID: 2, sender: 3, text: 4,
            date: 5, isFromMe: 6, service: 7, isAudioMessage: 8,
            destinationCallerID: 9, guid: 10, associatedGUID: 11,
            associatedType: 12, attachments: 13, body: 14, threadOriginatorGUID: 15
        )

        return try withConnection { db in
            var messages: [Message] = []
            for row in try db.prepare(sql, bindings) {
                let decoded = try decodeMessageRow(row, columns: columns, fallbackChatID: chatID)
                let replyToGUID = self.replyToGUID(
                    associatedGuid: decoded.associatedGUID,
                    associatedType: decoded.associatedType
                )
                let reaction = decodeReaction(
                    associatedType: decoded.associatedType,
                    associatedGUID: decoded.associatedGUID,
                    text: decoded.text
                )
                messages.append(Message(
                    rowID: decoded.rowID,
                    chatID: decoded.chatID,
                    sender: decoded.sender,
                    text: decoded.text,
                    date: decoded.date,
                    isFromMe: decoded.isFromMe,
                    service: decoded.service,
                    handleID: decoded.handleID,
                    attachmentsCount: decoded.attachments,
                    guid: decoded.guid,
                    routing: Message.RoutingMetadata(
                        replyToGUID: replyToGUID,
                        threadOriginatorGUID: decoded.threadOriginatorGUID.isEmpty ? nil : decoded.threadOriginatorGUID,
                        destinationCallerID: decoded.destinationCallerID.isEmpty ? nil : decoded.destinationCallerID
                    ),
                    reaction: Message.ReactionMetadata(
                        isReaction: reaction.isReaction,
                        reactionType: reaction.reactionType,
                        isReactionAdd: reaction.isReactionAdd,
                        reactedToGUID: reaction.reactedToGUID
                    )
                ))
            }
            return messages
        }
    }
}

// MARK: - Attachments

extension MessageStore {

    /// Returns attachment metadata for a given message.
    public func attachments(for messageID: Int64) throws -> [AttachmentMeta] {
        let sql = """
            SELECT a.filename, a.transfer_name, a.uti, a.mime_type, a.total_bytes, a.is_sticker
            FROM message_attachment_join maj
            JOIN attachment a ON a.ROWID = maj.attachment_id
            WHERE maj.message_id = ?
            """
        return try withConnection { db in
            var metas: [AttachmentMeta] = []
            for row in try db.prepare(sql, messageID) {
                let filename = stringValue(row[0])
                let transferName = stringValue(row[1])
                let uti = stringValue(row[2])
                let mimeType = stringValue(row[3])
                let totalBytes = int64Value(row[4]) ?? 0
                let isSticker = boolValue(row[5])
                let resolved = AttachmentResolver.resolve(filename)
                metas.append(AttachmentMeta(
                    filename: filename,
                    transferName: transferName,
                    uti: uti,
                    mimeType: mimeType,
                    totalBytes: totalBytes,
                    isSticker: isSticker,
                    originalPath: resolved.resolved,
                    missing: resolved.missing
                ))
            }
            return metas
        }
    }

    /// Extracts audio transcription from the attachment's `user_info` binary plist.
    func audioTranscription(for messageID: Int64) throws -> String? {
        guard hasAttachmentUserInfo else { return nil }
        let sql = """
            SELECT a.user_info
            FROM message_attachment_join maj
            JOIN attachment a ON a.ROWID = maj.attachment_id
            WHERE maj.message_id = ?
            LIMIT 1
            """
        return try withConnection { db in
            for row in try db.prepare(sql, messageID) {
                let info = dataValue(row[0])
                guard !info.isEmpty else { continue }
                if let transcription = parseAudioTranscription(from: info) {
                    return transcription
                }
            }
            return nil
        }
    }

    private func parseAudioTranscription(from data: Data) -> String? {
        do {
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            guard
                let dict = plist as? [String: Any],
                let transcription = dict["audio-transcription"] as? String,
                !transcription.isEmpty
            else {
                return nil
            }
            return transcription
        } catch {
            return nil
        }
    }
}

// MARK: - Reactions (Deduplicated)

extension MessageStore {

    /// Returns deduplicated reactions for a given message.
    ///
    /// When a person changes their tapback (e.g., switches from like to love),
    /// the old reaction is removed and only the latest is returned.
    public func reactions(for messageID: Int64) throws -> [Reaction] {
        guard hasReactionColumns else { return [] }

        let bodyColumn = hasAttributedBody ? "r.attributedBody" : "NULL"
        let sql = """
            SELECT r.ROWID, r.associated_message_type, h.id, r.is_from_me, r.date, IFNULL(r.text, '') as text,
                   \(bodyColumn) AS body
            FROM message m
            JOIN message r ON r.associated_message_guid = m.guid
              OR r.associated_message_guid LIKE '%/' || m.guid
            LEFT JOIN handle h ON r.handle_id = h.ROWID
            WHERE m.ROWID = ?
              AND m.guid IS NOT NULL
              AND m.guid != ''
              AND r.associated_message_type >= 2000
              AND r.associated_message_type <= 3006
            ORDER BY r.date ASC
            """
        return try withConnection { db in
            var reactions: [Reaction] = []
            var reactionIndex: [ReactionKey: Int] = [:]

            for row in try db.prepare(sql, messageID) {
                let rowID = int64Value(row[0]) ?? 0
                let typeValue = intValue(row[1]) ?? 0
                let sender = stringValue(row[2])
                let isFromMe = boolValue(row[3])
                let date = appleDate(from: int64Value(row[4]))
                let text = stringValue(row[5])
                let body = dataValue(row[6])
                let resolvedText = text.isEmpty ? TypedStreamParser.parseAttributedBody(body) : text

                // Handle removal events
                if ReactionType.isReactionRemove(typeValue) {
                    let customEmoji = typeValue == 3006 ? extractCustomEmoji(from: resolvedText) : nil
                    let reactionType = ReactionType.fromRemoval(typeValue, customEmoji: customEmoji)
                    if let reactionType {
                        let key = ReactionKey(sender: sender, isFromMe: isFromMe, reactionType: reactionType)
                        if let index = reactionIndex.removeValue(forKey: key) {
                            reactions.remove(at: index)
                            reactionIndex = ReactionKey.reindex(reactions: reactions)
                        }
                        continue
                    }
                    // Fallback: remove any custom reaction from this sender
                    if typeValue == 3006 {
                        if let index = reactions.firstIndex(where: {
                            $0.sender == sender && $0.isFromMe == isFromMe && $0.reactionType.isCustom
                        }) {
                            reactions.remove(at: index)
                            reactionIndex = ReactionKey.reindex(reactions: reactions)
                        }
                    }
                    continue
                }

                // Handle add events
                let customEmoji: String? = typeValue == 2006 ? extractCustomEmoji(from: resolvedText) : nil
                guard let reactionType = ReactionType(rawValue: typeValue, customEmoji: customEmoji) else {
                    continue
                }

                let key = ReactionKey(sender: sender, isFromMe: isFromMe, reactionType: reactionType)
                if let index = reactionIndex[key] {
                    reactions[index] = Reaction(
                        rowID: rowID, reactionType: reactionType,
                        sender: sender, isFromMe: isFromMe,
                        date: date, associatedMessageID: messageID
                    )
                } else {
                    reactionIndex[key] = reactions.count
                    reactions.append(Reaction(
                        rowID: rowID, reactionType: reactionType,
                        sender: sender, isFromMe: isFromMe,
                        date: date, associatedMessageID: messageID
                    ))
                }
            }
            return reactions
        }
    }
}

// MARK: - Reaction Events (Streaming)

extension MessageStore {

    /// Fetch reaction events (add/remove) after a given rowID.
    ///
    /// Unlike `reactions(for:)` which returns deduplicated state,
    /// this returns raw events for streaming in watch mode.
    public func reactionEventsAfter(afterRowID: Int64, chatID: Int64?, limit: Int) throws -> [ReactionEvent] {
        guard hasReactionColumns else { return [] }

        let bodyColumn = hasAttributedBody ? "m.attributedBody" : "NULL"
        let destinationCallerColumn = hasDestinationCallerID ? "m.destination_caller_id" : "NULL"

        var sql = """
            SELECT m.ROWID, cmj.chat_id, m.associated_message_type, m.associated_message_guid,
                   m.handle_id, h.id, m.is_from_me, m.date, IFNULL(m.text, '') AS text,
                   \(destinationCallerColumn) AS destination_caller_id,
                   \(bodyColumn) AS body,
                   orig.ROWID AS orig_rowid
            FROM message m
            LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            LEFT JOIN message orig ON (orig.guid = m.associated_message_guid
              OR m.associated_message_guid LIKE '%/' || orig.guid)
            WHERE m.ROWID > ?
              AND m.associated_message_type >= 2000
              AND m.associated_message_type <= 3006
            """
        var bindings: [Binding?] = [afterRowID]

        if let chatID {
            sql += " AND cmj.chat_id = ?"
            bindings.append(chatID)
        }
        sql += " ORDER BY m.ROWID ASC LIMIT ?"
        bindings.append(limit)

        return try withConnection { db in
            var events: [ReactionEvent] = []
            for row in try db.prepare(sql, bindings) {
                let rowID = int64Value(row[0]) ?? 0
                let resolvedChatID = int64Value(row[1]) ?? chatID ?? 0
                let typeValue = intValue(row[2]) ?? 0
                let associatedGUID = stringValue(row[3])
                var sender = stringValue(row[5])
                let isFromMe = boolValue(row[6])
                let date = appleDate(from: int64Value(row[7]))
                let text = stringValue(row[8])
                let destinationCallerID = stringValue(row[9])
                let body = dataValue(row[10])
                let origRowID = int64Value(row[11])

                if sender.isEmpty && !destinationCallerID.isEmpty {
                    sender = destinationCallerID
                }

                let resolvedText = text.isEmpty ? TypedStreamParser.parseAttributedBody(body) : text
                let decoded = decodeReaction(
                    associatedType: typeValue,
                    associatedGUID: associatedGUID,
                    text: resolvedText
                )
                guard let reactionType = decoded.reactionType, let isAdd = decoded.isReactionAdd else {
                    continue
                }

                events.append(ReactionEvent(
                    rowID: rowID,
                    chatID: resolvedChatID,
                    reactionType: reactionType,
                    isAdd: isAdd,
                    sender: sender,
                    isFromMe: isFromMe,
                    date: date,
                    reactedToGUID: decoded.reactedToGUID ?? "",
                    reactedToID: origRowID,
                    text: resolvedText
                ))
            }
            return events
        }
    }
}

// MARK: - Message Decoding Helpers

private struct MessageRowColumns {
    let rowID: Int
    let chatID: Int?
    let handleID: Int
    let sender: Int
    let text: Int
    let date: Int
    let isFromMe: Int
    let service: Int
    let isAudioMessage: Int
    let destinationCallerID: Int
    let guid: Int
    let associatedGUID: Int
    let associatedType: Int
    let attachments: Int
    let body: Int
    let threadOriginatorGUID: Int
}

private struct DecodedMessageRow {
    let rowID: Int64
    let chatID: Int64
    let handleID: Int64?
    let sender: String
    let text: String
    let date: Date
    let isFromMe: Bool
    let service: String
    let destinationCallerID: String
    let guid: String
    let associatedGUID: String
    let associatedType: Int?
    let attachments: Int
    let threadOriginatorGUID: String
}

extension MessageStore {

    fileprivate struct DecodedReaction: Sendable {
        let isReaction: Bool
        let reactionType: ReactionType?
        let isReactionAdd: Bool?
        let reactedToGUID: String?
    }

    fileprivate func decodeMessageRow(
        _ row: [Binding?],
        columns: MessageRowColumns,
        fallbackChatID: Int64?
    ) throws -> DecodedMessageRow {
        let rowID = int64Value(row[columns.rowID]) ?? 0
        let resolvedChatID = columns.chatID.flatMap { int64Value(row[$0]) } ?? fallbackChatID ?? 0
        let handleID = int64Value(row[columns.handleID])
        let sender = stringValue(row[columns.sender])
        let text = stringValue(row[columns.text])
        let date = appleDate(from: int64Value(row[columns.date]))
        let isFromMe = boolValue(row[columns.isFromMe])
        let service = stringValue(row[columns.service])
        let isAudioMessage = boolValue(row[columns.isAudioMessage])
        let destinationCallerID = stringValue(row[columns.destinationCallerID])
        let guid = stringValue(row[columns.guid])
        let associatedGUID = stringValue(row[columns.associatedGUID])
        let associatedType = intValue(row[columns.associatedType])
        let attachments = intValue(row[columns.attachments]) ?? 0
        let body = dataValue(row[columns.body])
        let threadOriginatorGUID = stringValue(row[columns.threadOriginatorGUID])

        // Resolve text: prefer raw text, fall back to TypedStreamParser, then audio transcription
        var resolvedText = text.isEmpty ? TypedStreamParser.parseAttributedBody(body) : text
        if isAudioMessage, let transcription = try audioTranscription(for: rowID) {
            resolvedText = transcription
        }

        var resolvedSender = sender
        if resolvedSender.isEmpty && !destinationCallerID.isEmpty {
            resolvedSender = destinationCallerID
        }

        return DecodedMessageRow(
            rowID: rowID,
            chatID: resolvedChatID,
            handleID: handleID,
            sender: resolvedSender,
            text: resolvedText,
            date: date,
            isFromMe: isFromMe,
            service: service,
            destinationCallerID: destinationCallerID,
            guid: guid,
            associatedGUID: associatedGUID,
            associatedType: associatedType,
            attachments: attachments,
            threadOriginatorGUID: threadOriginatorGUID
        )
    }

    fileprivate func normalizeAssociatedGUID(_ guid: String) -> String {
        guard !guid.isEmpty else { return "" }
        guard let slash = guid.lastIndex(of: "/") else { return guid }
        let nextIndex = guid.index(after: slash)
        guard nextIndex < guid.endIndex else { return guid }
        return String(guid[nextIndex...])
    }

    fileprivate func replyToGUID(associatedGuid: String, associatedType: Int?) -> String? {
        let normalized = normalizeAssociatedGUID(associatedGuid)
        guard !normalized.isEmpty else { return nil }
        if let type = associatedType, ReactionType.isReaction(type) {
            return nil
        }
        return normalized
    }

    fileprivate func decodeReaction(
        associatedType: Int?,
        associatedGUID: String,
        text: String
    ) -> DecodedReaction {
        guard let typeValue = associatedType, ReactionType.isReaction(typeValue) else {
            return DecodedReaction(isReaction: false, reactionType: nil, isReactionAdd: nil, reactedToGUID: nil)
        }

        let isAdd = ReactionType.isReactionAdd(typeValue)
        let rawType = isAdd ? typeValue : typeValue - 1000
        let customEmoji = (rawType == 2006) ? extractCustomEmoji(from: text) : nil
        guard let reactionType = ReactionType(rawValue: rawType, customEmoji: customEmoji) else {
            return DecodedReaction(
                isReaction: true, reactionType: nil,
                isReactionAdd: isAdd, reactedToGUID: normalizeAssociatedGUID(associatedGUID)
            )
        }

        return DecodedReaction(
            isReaction: true, reactionType: reactionType,
            isReactionAdd: isAdd, reactedToGUID: normalizeAssociatedGUID(associatedGUID)
        )
    }

    /// Extract custom emoji from reaction message text like `Reacted 🎉 to "original message"`.
    func extractCustomEmoji(from text: String) -> String? {
        guard
            let reactedRange = text.range(of: "Reacted "),
            let toRange = text.range(of: " to ", range: reactedRange.upperBound..<text.endIndex)
        else {
            return extractFirstEmoji(from: text)
        }
        let emoji = String(text[reactedRange.upperBound..<toRange.lowerBound])
        return emoji.isEmpty ? extractFirstEmoji(from: text) : emoji
    }

    private func extractFirstEmoji(from text: String) -> String? {
        for character in text {
            if character.unicodeScalars.contains(where: {
                $0.properties.isEmojiPresentation || $0.properties.isEmoji
            }) {
                return String(character)
            }
        }
        return nil
    }
}

// MARK: - Reaction Deduplication Key

extension MessageStore {

    fileprivate struct ReactionKey: Hashable {
        let sender: String
        let isFromMe: Bool
        let reactionType: ReactionType

        static func reindex(reactions: [Reaction]) -> [ReactionKey: Int] {
            var index: [ReactionKey: Int] = [:]
            for (offset, reaction) in reactions.enumerated() {
                let key = ReactionKey(
                    sender: reaction.sender,
                    isFromMe: reaction.isFromMe,
                    reactionType: reaction.reactionType
                )
                index[key] = offset
            }
            return index
        }
    }
}

// MARK: - Date Conversion

extension MessageStore {

    func appleDate(from value: Int64?) -> Date {
        guard let value else {
            return Date(timeIntervalSince1970: MessageStore.appleEpochOffset)
        }
        return Date(
            timeIntervalSince1970: (Double(value) / 1_000_000_000) + MessageStore.appleEpochOffset
        )
    }

    static func appleEpoch(_ date: Date) -> Int64 {
        let seconds = date.timeIntervalSince1970 - MessageStore.appleEpochOffset
        return Int64(seconds * 1_000_000_000)
    }
}

// MARK: - Binding Helpers

extension MessageStore {

    func stringValue(_ binding: Binding?) -> String {
        binding as? String ?? ""
    }

    func int64Value(_ binding: Binding?) -> Int64? {
        if let value = binding as? Int64 { return value }
        if let value = binding as? Int { return Int64(value) }
        if let value = binding as? Double { return Int64(value) }
        return nil
    }

    func intValue(_ binding: Binding?) -> Int? {
        if let value = binding as? Int { return value }
        if let value = binding as? Int64 { return Int(value) }
        if let value = binding as? Double { return Int(value) }
        return nil
    }

    func boolValue(_ binding: Binding?) -> Bool {
        if let value = binding as? Bool { return value }
        if let value = intValue(binding) { return value != 0 }
        return false
    }

    func dataValue(_ binding: Binding?) -> Data {
        if let blob = binding as? Blob {
            return Data(blob.bytes)
        }
        return Data()
    }
}

// MARK: - Schema Introspection

extension MessageStore {

    static func tableColumns(connection: Connection, table: String) -> Set<String> {
        do {
            let rows = try connection.prepare("PRAGMA table_info(\(table))")
            var columns = Set<String>()
            for row in rows {
                if let name = row[1] as? String {
                    columns.insert(name.lowercased())
                }
            }
            return columns
        } catch {
            return []
        }
    }

    static func reactionColumnsPresent(in columns: Set<String>) -> Bool {
        columns.contains("guid")
            && columns.contains("associated_message_guid")
            && columns.contains("associated_message_type")
    }

    static func enhance(error: Error, path: String) -> Error {
        let message = String(describing: error).lowercased()

        if message.contains("out of memory") || message.contains("authorization denied")
            || message.contains("unable to open database") || message.contains("cannot open")
            || message.contains("permission") || message.contains("not permitted")
            || message.contains("operation not allowed")
        {
            return AppMeeeIMsgError.permissionDenied(
                path: path,
                detail: "Full Disk Access required. Grant access in System Settings > Privacy & Security > Full Disk Access."
            )
        }

        if message.contains("no such file") || message.contains("does not exist") {
            return AppMeeeIMsgError.databaseNotFound(path: path)
        }

        return AppMeeeIMsgError.databaseError(
            detail: "Failed to open \(path): \(error.localizedDescription)"
        )
    }
}
