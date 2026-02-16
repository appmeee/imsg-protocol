import Foundation
import SQLite

// MARK: - MessageStore

/// Thread-safe, read-only accessor for macOS's iMessage database (chat.db).
///
/// Opens `~/Library/Messages/chat.db` in read-only WAL mode and exposes
/// queries for chats, messages, attachments, and reactions.
///
/// - Important: Full Disk Access must be granted to the process.
public final class MessageStore: @unchecked Sendable {

    // MARK: - Constants

    /// Seconds between the Unix epoch (1970-01-01) and Apple's reference date (2001-01-01).
    private static let appleEpochOffset: Int64 = 978_307_200

    /// Apple stores `message.date` in nanoseconds since 2001-01-01.
    private static let nanosPerSecond: Double = 1_000_000_000

    /// Reaction `associated_message_type` range (inclusive).
    private static let reactionTypeRange: ClosedRange<Int> = 2000...3006

    // MARK: - Properties

    /// The resolved file path to the chat.db file.
    public let path: String

    /// Default path for the current user's iMessage database.
    public static var defaultPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Messages/chat.db"
    }

    private let connection: Connection
    private let queue = DispatchQueue(label: "com.appmeee.imsg.messagestore", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()

    // MARK: Column availability flags

    private let hasAttributedBody: Bool
    private let hasReactionColumns: Bool
    private let hasThreadOriginatorGUIDColumn: Bool
    private let hasDestinationCallerID: Bool
    private let hasAttachmentIsSticker: Bool

    // MARK: - Initialization

    /// Opens the iMessage database at the given path in read-only mode.
    ///
    /// - Parameter path: File path to `chat.db`. Defaults to `~/Library/Messages/chat.db`.
    /// - Throws: `AppMeeeIMsgError` if the file cannot be opened or lacks required permissions.
    public init(path: String = MessageStore.defaultPath) throws {
        self.path = path

        do {
            self.connection = try Connection(path, readonly: true)
        } catch {
            throw MessageStore.enhance(error: error, path: path)
        }

        queue.setSpecific(key: queueKey, value: true)

        // WAL mode for concurrent reads while imagent writes
        try connection.execute("PRAGMA journal_mode = WAL")
        try connection.execute("PRAGMA query_only = ON")

        let messageColumns = MessageStore.tableColumns(connection: connection, table: "message")
        let attachmentColumns = MessageStore.tableColumns(connection: connection, table: "attachment")

        self.hasAttributedBody = messageColumns.contains("attributedBody")
        self.hasReactionColumns = MessageStore.reactionColumnsPresent(in: messageColumns)
        self.hasThreadOriginatorGUIDColumn = messageColumns.contains("thread_originator_guid")
        self.hasDestinationCallerID = messageColumns.contains("destination_caller_id")
        self.hasAttachmentIsSticker = attachmentColumns.contains("is_sticker")
    }

    // MARK: - Queue Helper

    /// Executes a closure on the serial queue, ensuring thread-safe database access.
    ///
    /// If the caller is already on the store's queue, the closure runs synchronously
    /// to avoid deadlock.
    private func withConnection<T>(_ work: () throws -> T) throws -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            return try work()
        }

        return try queue.sync {
            try work()
        }
    }

    // MARK: - Public API

    /// Lists chats ordered by most recent message activity.
    ///
    /// - Parameter limit: Maximum number of chats to return.
    /// - Returns: Array of `Chat` values sorted by last message date descending.
    public func listChats(limit: Int) throws -> [Chat] {
        try withConnection {
            let sql = """
                SELECT c.ROWID,
                       IFNULL(c.display_name, c.chat_identifier) AS name,
                       c.chat_identifier,
                       c.service_name,
                       MAX(m.date) AS last_date
                FROM chat c
                JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
                JOIN message m ON m.ROWID = cmj.message_id
                GROUP BY c.ROWID
                ORDER BY last_date DESC
                LIMIT ?
                """

            let stmt = try connection.prepare(sql)
            var chats: [Chat] = []

            for row in try stmt.bind(Int64(limit)) {
                let rowID = int64Value(row[0]) ?? 0
                let name = stringValue(row[1])
                let identifier = stringValue(row[2])
                let service = stringValue(row[3])
                let lastDate = appleDate(from: int64Value(row[4]))

                chats.append(Chat(
                    id: rowID,
                    identifier: identifier,
                    name: name,
                    service: service,
                    lastMessageDate: lastDate
                ))
            }

            return chats
        }
    }

    /// Returns detailed information about a single chat.
    ///
    /// - Parameter chatID: The `ROWID` of the chat in the `chat` table.
    /// - Returns: A `ChatInfo` if the chat exists, or `nil`.
    public func chatInfo(chatID: Int64) throws -> ChatInfo? {
        try withConnection {
            let sql = """
                SELECT c.ROWID,
                       IFNULL(c.chat_identifier, '') AS identifier,
                       IFNULL(c.guid, '') AS guid,
                       IFNULL(c.display_name, c.chat_identifier) AS name,
                       IFNULL(c.service_name, '') AS service
                FROM chat c
                WHERE c.ROWID = ?
                LIMIT 1
                """

            let stmt = try connection.prepare(sql)

            for row in try stmt.bind(chatID) {
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
    ///
    /// - Parameter chatID: The `ROWID` of the chat.
    /// - Returns: Sorted array of handle identifiers (phone numbers or email addresses).
    public func participants(chatID: Int64) throws -> [String] {
        try withConnection {
            let sql = """
                SELECT h.id
                FROM chat_handle_join chj
                JOIN handle h ON h.ROWID = chj.handle_id
                WHERE chj.chat_id = ?
                ORDER BY h.id ASC
                """

            let stmt = try connection.prepare(sql)
            var handles: [String] = []

            for row in try stmt.bind(chatID) {
                handles.append(stringValue(row[0]))
            }

            return handles
        }
    }

    /// Fetches messages for a chat, most recent first.
    ///
    /// - Parameters:
    ///   - chatID: The `ROWID` of the chat.
    ///   - limit: Maximum number of messages to return.
    ///   - filter: Optional filter to restrict messages by date range or text content.
    /// - Returns: Array of `Message` values ordered by date descending.
    public func messages(chatID: Int64, limit: Int, filter: MessageFilter?) throws -> [Message] {
        try withConnection {
            var conditions = ["cmj.chat_id = ?"]
            var bindings: [Binding] = [chatID]

            if let filter = filter {
                if let after = filter.afterDate {
                    let appleNanos = dateToAppleNanos(after)
                    conditions.append("m.date > ?")
                    bindings.append(appleNanos)
                }
                if let before = filter.beforeDate {
                    let appleNanos = dateToAppleNanos(before)
                    conditions.append("m.date < ?")
                    bindings.append(appleNanos)
                }
                if let text = filter.textContains, !text.isEmpty {
                    conditions.append("m.text LIKE ?")
                    bindings.append("%\(text)%")
                }
                if let fromMe = filter.isFromMe {
                    conditions.append("m.is_from_me = ?")
                    bindings.append(Int64(fromMe ? 1 : 0))
                }
            }

            let whereClause = conditions.joined(separator: " AND ")
            let columnList = messageColumnList(includeAttributedBody: hasAttributedBody)

            let sql = """
                SELECT \(columnList)
                FROM message m
                JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
                LEFT JOIN handle h ON m.handle_id = h.ROWID
                WHERE \(whereClause)
                ORDER BY m.date DESC
                LIMIT ?
                """

            bindings.append(Int64(limit))

            let stmt = try connection.prepare(sql)
            var messages: [Message] = []

            for row in try stmt.bind(bindings) {
                messages.append(decodeMessage(from: row))
            }

            return messages
        }
    }

    /// Fetches messages with ROWID greater than the given value, in ascending order.
    ///
    /// Used for polling: call `maxRowID()` to get the current watermark, then
    /// periodically call `messagesAfter(afterRowID:)` to retrieve new messages.
    ///
    /// - Parameters:
    ///   - afterRowID: Only messages with `ROWID > afterRowID` are returned.
    ///   - chatID: Optional chat filter. Pass `nil` to get messages across all chats.
    ///   - limit: Maximum number of messages to return.
    ///   - includeReactions: Whether to include reaction messages in results.
    /// - Returns: Array of `Message` values ordered by ROWID ascending.
    public func messagesAfter(
        afterRowID: Int64,
        chatID: Int64? = nil,
        limit: Int,
        includeReactions: Bool = true
    ) throws -> [Message] {
        try withConnection {
            var conditions = ["m.ROWID > ?"]
            var bindings: [Binding] = [afterRowID]

            if let chatID = chatID {
                conditions.append("cmj.chat_id = ?")
                bindings.append(chatID)
            }

            if !includeReactions, hasReactionColumns {
                conditions.append(
                    "(m.associated_message_type IS NULL OR m.associated_message_type < 2000 OR m.associated_message_type > 3006)"
                )
            }

            let whereClause = conditions.joined(separator: " AND ")

            let sql = """
                SELECT m.ROWID, cmj.chat_id, IFNULL(m.guid, ''), IFNULL(h.id, '') AS sender,
                       m.is_from_me, IFNULL(m.text, '') AS text, m.date, m.service,
                       m.handle_id, m.cache_has_attachments\(reactionColumnSQL())\(threadOriginatorColumnSQL())\(destinationCallerIDColumnSQL())
                FROM message m
                JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
                LEFT JOIN handle h ON m.handle_id = h.ROWID
                WHERE \(whereClause)
                ORDER BY m.ROWID ASC
                LIMIT ?
                """

            bindings.append(Int64(limit))

            let stmt = try connection.prepare(sql)
            var messages: [Message] = []

            for row in try stmt.bind(bindings) {
                messages.append(decodeMessage(from: row))
            }

            return messages
        }
    }

    /// Returns attachment metadata for a given message.
    ///
    /// - Parameter messageID: The `ROWID` of the message.
    /// - Returns: Array of `AttachmentMeta` values.
    public func attachments(for messageID: Int64) throws -> [AttachmentMeta] {
        try withConnection {
            let stickerColumn = hasAttachmentIsSticker ? ", a.is_sticker" : ""
            let sql = """
                SELECT a.filename, a.transfer_name, a.uti, a.mime_type, a.total_bytes\(stickerColumn)
                FROM message_attachment_join maj
                JOIN attachment a ON a.ROWID = maj.attachment_id
                WHERE maj.message_id = ?
                """

            let stmt = try connection.prepare(sql)
            var results: [AttachmentMeta] = []

            for row in try stmt.bind(messageID) {
                let filename = stringValue(row[0])
                let transferName = stringValue(row[1])
                let uti = stringValue(row[2])
                let mimeType = stringValue(row[3])
                let totalBytes = int64Value(row[4]) ?? 0
                let isSticker = hasAttachmentIsSticker ? boolValue(row[5]) : false

                // Resolve ~/Library paths
                let resolvedFilename: String
                if filename.hasPrefix("~") {
                    let home = FileManager.default.homeDirectoryForCurrentUser.path
                    resolvedFilename = filename.replacingOccurrences(of: "~", with: home, range: filename.startIndex..<filename.index(after: filename.startIndex))
                } else {
                    resolvedFilename = filename
                }

                results.append(AttachmentMeta(
                    filename: resolvedFilename,
                    transferName: transferName,
                    uti: uti,
                    mimeType: mimeType,
                    totalBytes: totalBytes,
                    isSticker: isSticker
                ))
            }

            return results
        }
    }

    /// Returns reactions associated with a given message.
    ///
    /// Reactions are stored as separate message rows whose `associated_message_guid`
    /// references the original message's GUID.
    ///
    /// - Parameter messageID: The `ROWID` of the original message.
    /// - Returns: Array of `Reaction` values.
    public func reactions(for messageID: Int64) throws -> [Reaction] {
        guard hasReactionColumns else { return [] }

        return try withConnection {
            // First, get the GUID of the target message
            let guidSQL = "SELECT IFNULL(guid, '') FROM message WHERE ROWID = ? LIMIT 1"
            let guidStmt = try connection.prepare(guidSQL)
            var targetGUID = ""

            for row in try guidStmt.bind(messageID) {
                targetGUID = stringValue(row[0])
            }

            guard !targetGUID.isEmpty else { return [] }

            // Find reaction messages that reference this GUID
            // associated_message_guid format: "p:X/GUID" or "bp:GUID"
            let sql = """
                SELECT m.ROWID, IFNULL(h.id, '') AS sender, m.is_from_me,
                       m.associated_message_type, m.associated_message_guid, m.date
                FROM message m
                LEFT JOIN handle h ON m.handle_id = h.ROWID
                WHERE m.associated_message_type >= 2000
                  AND m.associated_message_type <= 3006
                  AND (m.associated_message_guid LIKE '%/' || ? OR m.associated_message_guid LIKE 'bp:' || ?)
                ORDER BY m.date ASC
                """

            let stmt = try connection.prepare(sql)
            var reactions: [Reaction] = []

            for row in try stmt.bind([targetGUID, targetGUID] as [Binding]) {
                let sender = stringValue(row[1])
                let isFromMe = boolValue(row[2])
                let typeRaw = intValue(row[3]) ?? 0
                let date = appleDate(from: int64Value(row[5]))

                let reactionType = ReactionType.from(associatedMessageType: typeRaw)
                let isRemoval = typeRaw >= 3000

                reactions.append(Reaction(
                    sender: sender,
                    isFromMe: isFromMe,
                    reactionType: reactionType,
                    isRemoval: isRemoval,
                    date: date
                ))
            }

            return reactions
        }
    }

    /// Returns the highest ROWID in the message table.
    ///
    /// Useful as a polling watermark: store this value, then call
    /// `messagesAfter(afterRowID:)` to fetch only new messages.
    ///
    /// - Returns: The maximum `ROWID`, or `0` if the table is empty.
    public func maxRowID() throws -> Int64 {
        try withConnection {
            let sql = "SELECT MAX(ROWID) FROM message"
            let stmt = try connection.prepare(sql)

            for row in stmt {
                return int64Value(row[0]) ?? 0
            }

            return 0
        }
    }
}

// MARK: - Message Decoding

extension MessageStore {

    /// Builds the column list for message queries that include attributedBody.
    private func messageColumnList(includeAttributedBody: Bool) -> String {
        var cols = """
            m.ROWID, cmj.chat_id, IFNULL(m.guid, ''), IFNULL(h.id, '') AS sender,
                       m.is_from_me, IFNULL(m.text, '') AS text, m.date, m.service,
                       m.handle_id, m.cache_has_attachments
            """

        if hasReactionColumns {
            cols += ",\n           m.associated_message_type, m.associated_message_guid"
        }

        if hasThreadOriginatorGUIDColumn {
            cols += ",\n           m.thread_originator_guid"
        }

        if hasDestinationCallerID {
            cols += ",\n           m.destination_caller_id"
        }

        if includeAttributedBody && hasAttributedBody {
            cols += ",\n           m.attributedBody"
        }

        return cols
    }

    /// SQL fragment for reaction columns in messagesAfter queries.
    private func reactionColumnSQL() -> String {
        hasReactionColumns
            ? ",\n           m.associated_message_type, m.associated_message_guid"
            : ""
    }

    /// SQL fragment for thread_originator_guid in messagesAfter queries.
    private func threadOriginatorColumnSQL() -> String {
        hasThreadOriginatorGUIDColumn
            ? ",\n           m.thread_originator_guid"
            : ""
    }

    /// SQL fragment for destination_caller_id in messagesAfter queries.
    private func destinationCallerIDColumnSQL() -> String {
        hasDestinationCallerID
            ? ",\n           m.destination_caller_id"
            : ""
    }

    /// Decodes a message row into a `Message` value.
    ///
    /// Column layout (indices):
    ///   0: ROWID, 1: chat_id, 2: guid, 3: sender, 4: is_from_me,
    ///   5: text, 6: date, 7: service, 8: handle_id, 9: cache_has_attachments
    ///
    /// Optional columns follow in order based on availability flags:
    ///   - associated_message_type, associated_message_guid
    ///   - thread_originator_guid
    ///   - destination_caller_id
    ///   - attributedBody
    private func decodeMessage(from row: [Binding?]) -> Message {
        let rowID = int64Value(row[0]) ?? 0
        let chatID = int64Value(row[1]) ?? 0
        let guid = stringValue(row[2])
        var sender = stringValue(row[3])
        let isFromMe = boolValue(row[4])
        var text = stringValue(row[5])
        let date = appleDate(from: int64Value(row[6]))
        let service = stringValue(row[7])
        let hasAttachments = boolValue(row[9])

        var idx = 10

        /// Safely retrieve a column value, flattening the double-optional from safe subscript.
        func col(_ i: Int) -> Binding? {
            guard i < row.count else { return nil }
            return row[i]
        }

        // Reaction metadata
        var associatedMessageType: Int = 0
        var associatedMessageGUID: String = ""
        var isReaction = false
        var reactionType: ReactionType?
        var isReactionRemoval = false
        var replyToGUID: String?

        if hasReactionColumns {
            associatedMessageType = intValue(col(idx)) ?? 0
            idx += 1
            associatedMessageGUID = stringValue(col(idx))
            idx += 1

            if MessageStore.reactionTypeRange.contains(associatedMessageType) {
                isReaction = true
                reactionType = ReactionType.from(associatedMessageType: associatedMessageType)
                isReactionRemoval = associatedMessageType >= 3000
            }

            // Reply detection: associated_message_guid format "p:X/GUID"
            if !isReaction, !associatedMessageGUID.isEmpty {
                replyToGUID = extractReplyGUID(from: associatedMessageGUID)
            }
        }

        // Thread originator (inline replies in group chats)
        if hasThreadOriginatorGUIDColumn {
            let threadGUID = stringValue(col(idx))
            idx += 1

            if replyToGUID == nil, !threadGUID.isEmpty {
                replyToGUID = threadGUID
            }
        }

        // Destination caller ID (sender for outgoing in group chats)
        if hasDestinationCallerID {
            let destCallerID = stringValue(col(idx))
            idx += 1

            if isFromMe, sender.isEmpty, !destCallerID.isEmpty {
                sender = destCallerID
            }
        }

        // Attributed body fallback for rich text / empty text
        if hasAttributedBody, idx < row.count {
            let bodyData = dataValue(col(idx))
            idx += 1

            if text.isEmpty, !bodyData.isEmpty {
                text = extractPlainText(from: bodyData)
            }
        }

        return Message(
            rowID: rowID,
            chatID: chatID,
            guid: guid,
            sender: sender,
            isFromMe: isFromMe,
            text: text,
            date: date,
            service: service,
            hasAttachments: hasAttachments,
            isReaction: isReaction,
            reactionType: reactionType,
            isReactionRemoval: isReactionRemoval,
            associatedMessageGUID: isReaction ? associatedMessageGUID : nil,
            replyToGUID: replyToGUID
        )
    }

    /// Extracts the target message GUID from an `associated_message_guid` value.
    ///
    /// Formats: `"p:0/GUID"`, `"p:1/GUID"`, or `"bp:GUID"`.
    private func extractReplyGUID(from value: String) -> String? {
        if value.hasPrefix("p:"), let slashIndex = value.firstIndex(of: "/") {
            let guidStart = value.index(after: slashIndex)
            let guid = String(value[guidStart...])
            return guid.isEmpty ? nil : guid
        }

        if value.hasPrefix("bp:") {
            let guid = String(value.dropFirst(3))
            return guid.isEmpty ? nil : guid
        }

        return nil
    }

    /// Best-effort extraction of plain text from an NSAttributedString archived blob.
    ///
    /// The `attributedBody` column stores an `NSKeyedArchiver` plist. We look for
    /// the `NSString` key's value, which contains the plain text content.
    private func extractPlainText(from data: Data) -> String {
        // NSKeyedArchiver format: look for the raw string between known markers
        // The attributed body is an NSKeyedArchiver binary plist containing an NSAttributedString.
        // We do a lightweight extraction: scan for the NSString payload.
        guard let rawString = String(data: data, encoding: .utf8) else {
            // Try as a binary plist
            if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
               let dict = plist as? [String: Any] {
                // Look for $objects array containing the string
                if let objects = dict["$objects"] as? [Any] {
                    for obj in objects {
                        if let str = obj as? String,
                           str != "$null",
                           !str.hasPrefix("NS"),
                           str.count > 1 {
                            return str
                        }
                    }
                }
            }
            return ""
        }

        // For UTF-8 decodable data, try to find meaningful text
        // Strip control characters and return
        let cleaned = rawString.components(separatedBy: .controlCharacters).joined()
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Date Conversion

extension MessageStore {

    /// Converts an Apple epoch nanosecond timestamp to a `Date`.
    ///
    /// Apple's `message.date` stores nanoseconds since 2001-01-01 00:00:00 UTC.
    /// This converts to a standard `Date` (seconds since 1970-01-01).
    ///
    /// - Parameter value: Nanoseconds since Apple epoch, or `nil`.
    /// - Returns: The corresponding `Date`, or `.distantPast` if `nil`.
    private func appleDate(from value: Int64?) -> Date {
        guard let value = value, value > 0 else {
            return .distantPast
        }

        // Older macOS versions stored seconds; newer ones store nanoseconds.
        // Heuristic: if the value is larger than ~1e15, it's nanoseconds.
        let seconds: TimeInterval
        if value > 1_000_000_000_000 {
            seconds = Double(value) / MessageStore.nanosPerSecond
        } else {
            seconds = Double(value)
        }

        let unixSeconds = seconds + Double(MessageStore.appleEpochOffset)
        return Date(timeIntervalSince1970: unixSeconds)
    }

    /// Converts a `Date` to Apple epoch nanoseconds for use in queries.
    private func dateToAppleNanos(_ date: Date) -> Int64 {
        let unixSeconds = date.timeIntervalSince1970
        let appleSeconds = unixSeconds - Double(MessageStore.appleEpochOffset)
        return Int64(appleSeconds * MessageStore.nanosPerSecond)
    }
}

// MARK: - Binding Helpers

extension MessageStore {

    /// Extracts a `String` from a SQLite `Binding` value.
    private func stringValue(_ binding: Binding?) -> String {
        switch binding {
        case let str as String:
            return str
        case let int as Int64:
            return String(int)
        case let dbl as Double:
            return String(dbl)
        default:
            return ""
        }
    }

    /// Extracts an `Int64` from a SQLite `Binding` value.
    private func int64Value(_ binding: Binding?) -> Int64? {
        switch binding {
        case let int as Int64:
            return int
        case let dbl as Double:
            return Int64(dbl)
        case let str as String:
            return Int64(str)
        default:
            return nil
        }
    }

    /// Extracts an `Int` from a SQLite `Binding` value.
    private func intValue(_ binding: Binding?) -> Int? {
        guard let i64 = int64Value(binding) else { return nil }
        return Int(i64)
    }

    /// Extracts a `Bool` from a SQLite `Binding` value.
    ///
    /// SQLite stores booleans as integers: `0` is `false`, anything else is `true`.
    private func boolValue(_ binding: Binding?) -> Bool {
        switch binding {
        case let int as Int64:
            return int != 0
        case let dbl as Double:
            return dbl != 0
        case let str as String:
            return !str.isEmpty && str != "0"
        default:
            return false
        }
    }

    /// Extracts raw `Data` from a SQLite `Binding` value.
    private func dataValue(_ binding: Binding?) -> Data {
        switch binding {
        case let blob as Blob:
            return Data(blob.bytes)
        case let str as String:
            return Data(str.utf8)
        default:
            return Data()
        }
    }
}

// MARK: - Schema Introspection

extension MessageStore {

    /// Returns the set of column names for a given table.
    ///
    /// Uses `PRAGMA table_info(tableName)` to inspect the schema at runtime.
    /// This allows graceful handling of schema differences across macOS versions.
    ///
    /// - Parameters:
    ///   - connection: The database connection.
    ///   - table: The table name to inspect.
    /// - Returns: A set of column name strings.
    static func tableColumns(connection: Connection, table: String) -> Set<String> {
        var columns = Set<String>()
        guard let stmt = try? connection.prepare("PRAGMA table_info(\(table))") else {
            return columns
        }

        for row in stmt {
            // PRAGMA table_info returns: cid, name, type, notnull, dflt_value, pk
            if row.count > 1, let name = row[1] as? String {
                columns.insert(name)
            }
        }

        return columns
    }

    /// Checks if the message table has the columns needed for reaction queries.
    ///
    /// Both `associated_message_type` and `associated_message_guid` must be present.
    static func reactionColumnsPresent(in columns: Set<String>) -> Bool {
        columns.contains("associated_message_type") && columns.contains("associated_message_guid")
    }

    /// Wraps a database error with additional context about file permissions.
    ///
    /// If the error is a permission denial, the wrapper provides actionable
    /// guidance about granting Full Disk Access.
    ///
    /// - Parameters:
    ///   - error: The original error.
    ///   - path: The database file path that failed to open.
    /// - Returns: An `AppMeeeIMsgError` with enhanced diagnostics.
    static func enhance(error: Error, path: String) -> Error {
        let message = error.localizedDescription.lowercased()

        if message.contains("permission") || message.contains("not permitted") || message.contains("operation not allowed") {
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

