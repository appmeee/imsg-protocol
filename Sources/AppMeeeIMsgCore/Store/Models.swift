import Foundation

// MARK: - ReactionType

/// Represents iMessage reaction (tapback) types.
///
/// Apple assigns integer codes in the 2000-range for adding reactions
/// and the 3000-range for removing them. This enum normalizes both
/// ranges into a single type-safe representation.
public enum ReactionType: Sendable, Equatable, Hashable {
    case love
    case like
    case dislike
    case laugh
    case emphasis
    case question
    case custom(String)

    // MARK: - Integer Code Initializers

    /// Creates a reaction from an iMessage add-reaction code (2000-2006).
    ///
    /// For custom emojis (2006), pass the emoji string extracted from the message text.
    ///
    /// - Parameters:
    ///   - rawValue: The `associated_message_type` value from the chat.db row.
    ///   - customEmoji: An optional emoji string for code 2006.
    /// - Returns: `nil` if the code is not in the 2000-2006 range.
    public init?(rawValue: Int, customEmoji: String? = nil) {
        switch rawValue {
        case 2000: self = .love
        case 2001: self = .like
        case 2002: self = .dislike
        case 2003: self = .laugh
        case 2004: self = .emphasis
        case 2005: self = .question
        case 2006:
            guard let emoji = customEmoji else { return nil }
            self = .custom(emoji)
        default: return nil
        }
    }

    /// Creates a reaction from an iMessage removal code (3000-3006).
    public static func fromRemoval(_ value: Int, customEmoji: String? = nil) -> ReactionType? {
        return ReactionType(rawValue: value - 1000, customEmoji: customEmoji)
    }

    // MARK: - Range Predicates

    /// Whether the code represents adding a reaction (2000-2006).
    public static func isReactionAdd(_ value: Int) -> Bool {
        value >= 2000 && value <= 2006
    }

    /// Whether the code represents removing a reaction (3000-3006).
    public static func isReactionRemove(_ value: Int) -> Bool {
        value >= 3000 && value <= 3006
    }

    /// Whether the code represents any reaction event (add or remove).
    public static func isReaction(_ value: Int) -> Bool {
        isReactionAdd(value) || isReactionRemove(value)
    }

    // MARK: - Display Properties

    /// A human-readable name for the reaction.
    public var name: String {
        switch self {
        case .love: return "love"
        case .like: return "like"
        case .dislike: return "dislike"
        case .laugh: return "laugh"
        case .emphasis: return "emphasis"
        case .question: return "question"
        case .custom: return "custom"
        }
    }

    /// The emoji representation of the reaction.
    public var emoji: String {
        switch self {
        case .love: return "\u{2764}\u{FE0F}"
        case .like: return "\u{1F44D}"
        case .dislike: return "\u{1F44E}"
        case .laugh: return "\u{1F602}"
        case .emphasis: return "\u{2757}\u{2757}"
        case .question: return "\u{2753}"
        case .custom(let emoji): return emoji
        }
    }

    // MARK: - Associated Message Type Code

    /// The iMessage add-reaction integer code for this reaction.
    public var associatedMessageType: Int {
        switch self {
        case .love: return 2000
        case .like: return 2001
        case .dislike: return 2002
        case .laugh: return 2003
        case .emphasis: return 2004
        case .question: return 2005
        case .custom: return 2006
        }
    }

    /// The iMessage removal-reaction integer code for this reaction.
    public var removalAssociatedMessageType: Int {
        associatedMessageType + 1000
    }

    /// Whether this reaction is a custom emoji type.
    public var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    // MARK: - Factory from Associated Message Type

    /// Creates a reaction from either an add (2000-2006) or removal (3000-3006) code.
    public static func from(associatedMessageType value: Int) -> ReactionType? {
        if isReactionAdd(value) {
            return ReactionType(rawValue: value)
        }
        if isReactionRemove(value) {
            return fromRemoval(value)
        }
        return nil
    }

    // MARK: - String Parsing

    /// Parses a reaction from a human-readable name or emoji string.
    ///
    /// Recognized inputs include name aliases (`"heart"`, `"thumbsup"`, `"haha"`, `"lol"`),
    /// canonical names, and literal emoji characters.
    ///
    /// - Parameter value: The string to parse.
    /// - Returns: The matching reaction type, or `nil` for empty/unrecognized strings.
    public static func parse(_ value: String) -> ReactionType? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch trimmed.lowercased() {
        case "love", "heart":
            return .love
        case "like", "thumbsup", "thumbs-up":
            return .like
        case "dislike", "thumbsdown", "thumbs-down":
            return .dislike
        case "laugh", "haha", "lol":
            return .laugh
        case "emphasis", "emphasize", "exclaim", "exclamation":
            return .emphasis
        case "question", "questionmark", "question-mark":
            return .question
        default:
            break
        }

        switch trimmed {
        case "\u{2764}\u{FE0F}", "\u{2764}":
            return .love
        case "\u{1F44D}":
            return .like
        case "\u{1F44E}":
            return .dislike
        case "\u{1F602}":
            return .laugh
        case "\u{2757}\u{2757}", "\u{2757}":
            return .emphasis
        case "\u{2753}", "?":
            return .question
        default:
            break
        }

        if containsEmoji(trimmed) {
            return .custom(trimmed)
        }

        return nil
    }

    private static func containsEmoji(_ value: String) -> Bool {
        for scalar in value.unicodeScalars {
            if scalar.properties.isEmojiPresentation || scalar.properties.isEmoji {
                return true
            }
        }
        return false
    }
}

// MARK: - Reaction

/// A single deduplicated reaction attached to a message.
public struct Reaction: Sendable, Equatable {
    /// The database ROWID of the reaction message.
    public let rowID: Int64
    /// The type of reaction applied.
    public let reactionType: ReactionType
    /// The handle ID or phone/email of the sender.
    public let sender: String
    /// Whether this device's user sent the reaction.
    public let isFromMe: Bool
    /// When the reaction was created.
    public let date: Date
    /// The ROWID of the message being reacted to.
    public let associatedMessageID: Int64

    public init(
        rowID: Int64,
        reactionType: ReactionType,
        sender: String,
        isFromMe: Bool,
        date: Date,
        associatedMessageID: Int64
    ) {
        self.rowID = rowID
        self.reactionType = reactionType
        self.sender = sender
        self.isFromMe = isFromMe
        self.date = date
        self.associatedMessageID = associatedMessageID
    }
}

// MARK: - ReactionEvent

/// A reaction event represents when someone adds or removes a reaction to a message.
///
/// Unlike `Reaction` (which represents the current deduplicated state),
/// this captures the event itself for streaming in watch mode.
public struct ReactionEvent: Sendable, Equatable {
    /// The ROWID of the reaction message in the database.
    public let rowID: Int64
    /// The chat ID where the reaction occurred.
    public let chatID: Int64
    /// The type of reaction.
    public let reactionType: ReactionType
    /// Whether this is adding (`true`) or removing (`false`) a reaction.
    public let isAdd: Bool
    /// The sender of the reaction (phone number or email).
    public let sender: String
    /// Whether the reaction was sent by the current user.
    public let isFromMe: Bool
    /// When the reaction event occurred.
    public let date: Date
    /// The GUID of the message being reacted to.
    public let reactedToGUID: String
    /// The ROWID of the message being reacted to (if available).
    public let reactedToID: Int64?
    /// The original text of the reaction message (e.g., `"Liked \"hello\""`).
    public let text: String

    public init(
        rowID: Int64,
        chatID: Int64,
        reactionType: ReactionType,
        isAdd: Bool,
        sender: String,
        isFromMe: Bool,
        date: Date,
        reactedToGUID: String,
        reactedToID: Int64?,
        text: String
    ) {
        self.rowID = rowID
        self.chatID = chatID
        self.reactionType = reactionType
        self.isAdd = isAdd
        self.sender = sender
        self.isFromMe = isFromMe
        self.date = date
        self.reactedToGUID = reactedToGUID
        self.reactedToID = reactedToID
        self.text = text
    }
}

// MARK: - Chat

/// A lightweight representation of an iMessage chat (conversation).
public struct Chat: Sendable, Equatable {
    /// The database row identifier.
    public let id: Int64
    /// The chat identifier (e.g., `"chat123456"`).
    public let identifier: String
    /// The display name.
    public let name: String
    /// The messaging service (`"iMessage"` or `"SMS"`).
    public let service: String
    /// The timestamp of the most recent message.
    public let lastMessageAt: Date

    public init(
        id: Int64,
        identifier: String,
        name: String,
        service: String,
        lastMessageAt: Date
    ) {
        self.id = id
        self.identifier = identifier
        self.name = name
        self.service = service
        self.lastMessageAt = lastMessageAt
    }
}

// MARK: - ChatInfo

/// Extended chat metadata including the full GUID.
public struct ChatInfo: Sendable, Equatable {
    /// The database row identifier.
    public let id: Int64
    /// The chat identifier (e.g., `"chat123456"`).
    public let identifier: String
    /// The full chat GUID (e.g., `"iMessage;+;chat123456"`).
    public let guid: String
    /// The display name.
    public let name: String
    /// The messaging service (`"iMessage"` or `"SMS"`).
    public let service: String

    public init(
        id: Int64,
        identifier: String,
        guid: String,
        name: String,
        service: String
    ) {
        self.id = id
        self.identifier = identifier
        self.guid = guid
        self.name = name
        self.service = service
    }
}

// MARK: - Message

/// A single message read from the iMessage chat.db.
public struct Message: Sendable, Equatable {

    /// Routing information for replies and thread tracking.
    public struct RoutingMetadata: Sendable, Equatable {
        /// The GUID of the message being replied to (from `associated_message_guid`).
        public let replyToGUID: String?
        /// The thread originator GUID (for inline replies in group chats).
        public let threadOriginatorGUID: String?
        /// The destination caller ID (sender identification in group chats).
        public let destinationCallerID: String?

        public init(
            replyToGUID: String? = nil,
            threadOriginatorGUID: String? = nil,
            destinationCallerID: String? = nil
        ) {
            self.replyToGUID = replyToGUID
            self.threadOriginatorGUID = threadOriginatorGUID
            self.destinationCallerID = destinationCallerID
        }
    }

    /// Metadata about reaction events on a message row.
    public struct ReactionMetadata: Sendable, Equatable {
        /// Whether this message row represents a reaction event.
        public let isReaction: Bool
        /// The parsed reaction type, if applicable.
        public let reactionType: ReactionType?
        /// Whether this is adding (`true`) or removing (`false`) a reaction.
        public let isReactionAdd: Bool?
        /// The GUID of the message being reacted to.
        public let reactedToGUID: String?

        public init(
            isReaction: Bool = false,
            reactionType: ReactionType? = nil,
            isReactionAdd: Bool? = nil,
            reactedToGUID: String? = nil
        ) {
            self.isReaction = isReaction
            self.reactionType = reactionType
            self.isReactionAdd = isReactionAdd
            self.reactedToGUID = reactedToGUID
        }
    }

    /// The database row identifier.
    public let rowID: Int64
    /// The `ROWID` of the chat this message belongs to.
    public let chatID: Int64
    /// The unique message GUID.
    public let guid: String
    /// The GUID of the message being replied to.
    public let replyToGUID: String?
    /// The thread originator GUID.
    public let threadOriginatorGUID: String?
    /// The handle ID or address of the sender.
    public let sender: String
    /// The message body text.
    public let text: String
    /// When the message was sent or received.
    public let date: Date
    /// Whether this device's user sent the message.
    public let isFromMe: Bool
    /// The messaging service (`"iMessage"` or `"SMS"`).
    public let service: String
    /// The raw handle ROWID from the database.
    public let handleID: Int64?
    /// The number of file attachments (count, not boolean).
    public let attachmentsCount: Int
    /// The `destination_caller_id` from the database.
    public let destinationCallerID: String?

    // Reaction metadata (populated when message is a reaction event)
    /// Whether this message is a reaction event (tapback add/remove).
    public let isReaction: Bool
    /// The type of reaction (only set when `isReaction` is true).
    public let reactionType: ReactionType?
    /// Whether this is adding or removing a reaction (only set when `isReaction` is true).
    public let isReactionAdd: Bool?
    /// The GUID of the message being reacted to (only set when `isReaction` is true).
    public let reactedToGUID: String?

    public init(
        rowID: Int64,
        chatID: Int64,
        sender: String,
        text: String,
        date: Date,
        isFromMe: Bool,
        service: String,
        handleID: Int64?,
        attachmentsCount: Int,
        guid: String = "",
        routing: RoutingMetadata = RoutingMetadata(),
        reaction: ReactionMetadata = ReactionMetadata()
    ) {
        self.rowID = rowID
        self.chatID = chatID
        self.guid = guid
        self.replyToGUID = routing.replyToGUID
        self.threadOriginatorGUID = routing.threadOriginatorGUID
        self.sender = sender
        self.text = text
        self.date = date
        self.isFromMe = isFromMe
        self.service = service
        self.handleID = handleID
        self.attachmentsCount = attachmentsCount
        self.destinationCallerID = routing.destinationCallerID
        self.isReaction = reaction.isReaction
        self.reactionType = reaction.reactionType
        self.isReactionAdd = reaction.isReactionAdd
        self.reactedToGUID = reaction.reactedToGUID
    }

    public init(
        rowID: Int64,
        chatID: Int64,
        sender: String,
        text: String,
        date: Date,
        isFromMe: Bool,
        service: String,
        handleID: Int64?,
        attachmentsCount: Int,
        guid: String = "",
        replyToGUID: String? = nil,
        threadOriginatorGUID: String? = nil,
        destinationCallerID: String? = nil,
        isReaction: Bool = false,
        reactionType: ReactionType? = nil,
        isReactionAdd: Bool? = nil,
        reactedToGUID: String? = nil
    ) {
        self.init(
            rowID: rowID,
            chatID: chatID,
            sender: sender,
            text: text,
            date: date,
            isFromMe: isFromMe,
            service: service,
            handleID: handleID,
            attachmentsCount: attachmentsCount,
            guid: guid,
            routing: RoutingMetadata(
                replyToGUID: replyToGUID,
                threadOriginatorGUID: threadOriginatorGUID,
                destinationCallerID: destinationCallerID
            ),
            reaction: ReactionMetadata(
                isReaction: isReaction,
                reactionType: reactionType,
                isReactionAdd: isReactionAdd,
                reactedToGUID: reactedToGUID
            )
        )
    }
}

// MARK: - AttachmentMeta

/// Metadata about a file attachment on a message.
public struct AttachmentMeta: Sendable, Equatable {
    /// The user-facing filename (e.g., `"photo.heic"`).
    public let filename: String
    /// The transfer-stage filename used during delivery.
    public let transferName: String
    /// The Uniform Type Identifier (e.g., `"public.jpeg"`).
    public let uti: String
    /// The MIME type (e.g., `"image/jpeg"`).
    public let mimeType: String
    /// The file size in bytes.
    public let totalBytes: Int64
    /// Whether the attachment is a sticker.
    public let isSticker: Bool
    /// The resolved filesystem path.
    public let originalPath: String
    /// `true` when the file is referenced but no longer on disk.
    public let missing: Bool

    public init(
        filename: String,
        transferName: String,
        uti: String,
        mimeType: String,
        totalBytes: Int64,
        isSticker: Bool,
        originalPath: String,
        missing: Bool
    ) {
        self.filename = filename
        self.transferName = transferName
        self.uti = uti
        self.mimeType = mimeType
        self.totalBytes = totalBytes
        self.isSticker = isSticker
        self.originalPath = originalPath
        self.missing = missing
    }
}

// MARK: - MessageFilter

/// Predicate for filtering messages in database queries and watch streams.
public struct MessageFilter: Sendable, Equatable {
    /// Only return messages from these participant handles.
    public let participants: [String]
    /// Only return messages after this date.
    public let startDate: Date?
    /// Only return messages before this date.
    public let endDate: Date?
    /// Only return messages whose text contains this substring (case-insensitive).
    public let textContains: String?
    /// Only return messages matching this is_from_me value.
    public let fromMe: Bool?

    public init(
        participants: [String] = [],
        startDate: Date? = nil,
        endDate: Date? = nil,
        textContains: String? = nil,
        fromMe: Bool? = nil
    ) {
        self.participants = participants
        self.startDate = startDate
        self.endDate = endDate
        self.textContains = textContains
        self.fromMe = fromMe
    }

    /// Creates a filter by parsing ISO 8601 date strings.
    public static func fromISO(
        participants: [String] = [],
        startISO: String? = nil,
        endISO: String? = nil,
        textContains: String? = nil,
        fromMe: Bool? = nil
    ) throws -> MessageFilter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let start: Date? = try startISO.map { iso in
            guard let date = formatter.date(from: iso) else {
                throw AppMeeeIMsgError.invalidISODate(iso)
            }
            return date
        }

        let end: Date? = try endISO.map { iso in
            guard let date = formatter.date(from: iso) else {
                throw AppMeeeIMsgError.invalidISODate(iso)
            }
            return date
        }

        return MessageFilter(
            participants: participants,
            startDate: start,
            endDate: end,
            textContains: textContains,
            fromMe: fromMe
        )
    }

    /// Tests whether a message passes this filter.
    public func allows(_ message: Message) -> Bool {
        if let startDate, message.date < startDate { return false }
        if let endDate, message.date >= endDate { return false }
        if let fromMe, message.isFromMe != fromMe { return false }
        if let textContains, !textContains.isEmpty {
            if !message.text.localizedCaseInsensitiveContains(textContains) {
                return false
            }
        }
        if !participants.isEmpty {
            var match = false
            for participant in participants {
                if participant.caseInsensitiveCompare(message.sender) == .orderedSame {
                    match = true
                    break
                }
            }
            if !match { return false }
        }
        return true
    }
}

// MARK: - MessageService

/// The transport service to use when sending a message.
public enum MessageService: String, Sendable, Equatable {
    /// Let the system decide based on the recipient's capabilities.
    case auto = "auto"
    /// Force iMessage delivery.
    case imessage = "iMessage"
    /// Force SMS delivery.
    case sms = "SMS"

    /// Case-insensitive lookup for RPC/CLI input.
    public static func fromRPC(_ value: String) -> MessageService? {
        switch value.lowercased() {
        case "auto": return .auto
        case "imessage": return .imessage
        case "sms": return .sms
        default: return nil
        }
    }
}

// MARK: - MessageSendOptions

/// Parameters for sending a new outgoing message.
public struct MessageSendOptions: Sendable, Equatable {
    /// The recipient handle (phone number or email).
    public let recipient: String
    /// The message body text.
    public let text: String?
    /// An optional file path to attach.
    public let attachmentPath: String?
    /// The service to send through.
    public let service: MessageService
    /// The phone number region code for normalization (e.g., `"US"`).
    public let region: String?
    /// An existing chat identifier to send into.
    public let chatIdentifier: String?
    /// The full chat GUID to target.
    public let chatGUID: String?

    public init(
        recipient: String,
        text: String? = nil,
        attachmentPath: String? = nil,
        service: MessageService = .auto,
        region: String? = nil,
        chatIdentifier: String? = nil,
        chatGUID: String? = nil
    ) {
        self.recipient = recipient
        self.text = text
        self.attachmentPath = attachmentPath
        self.service = service
        self.region = region
        self.chatIdentifier = chatIdentifier
        self.chatGUID = chatGUID
    }
}
