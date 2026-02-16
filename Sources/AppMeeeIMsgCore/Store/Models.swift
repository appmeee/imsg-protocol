import Foundation

// MARK: - ReactionType

/// Represents iMessage reaction (tapback) types.
///
/// Apple assigns integer codes in the 2000-range for adding reactions
/// and the 3000-range for removing them. This enum normalizes both
/// ranges into a single type-safe representation.
public enum ReactionType: Sendable, Equatable {
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
        case 2006: self = .custom(customEmoji ?? "")
        default: return nil
        }
    }

    /// Creates a reaction from an iMessage removal code (3000-3006).
    ///
    /// - Parameters:
    ///   - value: The `associated_message_type` value from the chat.db row.
    ///   - customEmoji: An optional emoji string for code 3006.
    /// - Returns: The corresponding reaction type, or `nil` if the code is out of range.
    public static func fromRemoval(_ value: Int, customEmoji: String? = nil) -> ReactionType? {
        switch value {
        case 3000: return .love
        case 3001: return .like
        case 3002: return .dislike
        case 3003: return .laugh
        case 3004: return .emphasis
        case 3005: return .question
        case 3006: return .custom(customEmoji ?? "")
        default: return nil
        }
    }

    // MARK: - Range Predicates

    /// Whether the code represents adding a reaction (2000-2006).
    public static func isReactionAdd(_ value: Int) -> Bool {
        (2000...2006).contains(value)
    }

    /// Whether the code represents removing a reaction (3000-3006).
    public static func isReactionRemove(_ value: Int) -> Bool {
        (3000...3006).contains(value)
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
        case .custom(let emoji): return emoji.isEmpty ? "custom" : emoji
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
    /// Recognized inputs: `"love"`, `"like"`, `"dislike"`, `"laugh"`,
    /// `"emphasis"`, `"question"`, or a literal emoji matching one of
    /// the built-in types. Unrecognized non-empty strings become `.custom`.
    ///
    /// - Parameter value: The string to parse.
    /// - Returns: The matching reaction type, or `nil` for empty strings.
    public static func parse(_ value: String) -> ReactionType? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        switch trimmed.lowercased() {
        case "love": return .love
        case "like": return .like
        case "dislike": return .dislike
        case "laugh": return .laugh
        case "emphasis": return .emphasis
        case "question": return .question
        default:
            break
        }

        switch trimmed {
        case "\u{2764}\u{FE0F}", "\u{2764}": return .love
        case "\u{1F44D}": return .like
        case "\u{1F44E}": return .dislike
        case "\u{1F602}": return .laugh
        case "\u{2757}\u{2757}", "\u{2757}": return .emphasis
        case "\u{2753}": return .question
        default:
            return .custom(trimmed)
        }
    }
}

// MARK: - Reaction

/// A single reaction event attached to a message.
public struct Reaction: Sendable, Equatable {
    /// The handle ID or phone/email of the sender.
    public let sender: String
    /// Whether this device's user sent the reaction.
    public let isFromMe: Bool
    /// The type of reaction applied.
    public let reactionType: ReactionType?
    /// Whether this is a removal event (3000-range).
    public let isRemoval: Bool
    /// When the reaction was created.
    public let date: Date

    public init(
        sender: String,
        isFromMe: Bool,
        reactionType: ReactionType?,
        isRemoval: Bool,
        date: Date
    ) {
        self.sender = sender
        self.isFromMe = isFromMe
        self.reactionType = reactionType
        self.isRemoval = isRemoval
        self.date = date
    }
}

// MARK: - Chat

/// A lightweight representation of an iMessage chat (conversation).
public struct Chat: Sendable, Equatable {
    /// The database row identifier.
    public let id: Int64
    /// The chat identifier (e.g., `"chat123456"`).
    public let identifier: String
    /// The display name, if set.
    public let name: String?
    /// The messaging service (`"iMessage"` or `"SMS"`).
    public let service: String
    /// The timestamp of the most recent message, if any.
    public let lastMessageDate: Date?

    public init(
        id: Int64,
        identifier: String,
        name: String?,
        service: String,
        lastMessageDate: Date?
    ) {
        self.id = id
        self.identifier = identifier
        self.name = name
        self.service = service
        self.lastMessageDate = lastMessageDate
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
    /// The display name, if set.
    public let name: String?
    /// The messaging service (`"iMessage"` or `"SMS"`).
    public let service: String

    public init(
        id: Int64,
        identifier: String,
        guid: String,
        name: String?,
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

    /// The database row identifier.
    public let rowID: Int64
    /// The `ROWID` of the chat this message belongs to.
    public let chatID: Int64
    /// The unique message GUID.
    public let guid: String
    /// The handle ID or address of the sender.
    public let sender: String
    /// Whether this device's user sent the message.
    public let isFromMe: Bool
    /// The message body text.
    public let text: String?
    /// When the message was sent or received.
    public let date: Date
    /// The messaging service (`"iMessage"` or `"SMS"`).
    public let service: String
    /// Whether this message has file attachments.
    public let hasAttachments: Bool
    /// Whether this message row represents a reaction event.
    public let isReaction: Bool
    /// The parsed reaction type, if applicable.
    public let reactionType: ReactionType?
    /// Whether this is a reaction removal (3000-range) vs addition (2000-range).
    public let isReactionRemoval: Bool
    /// The associated_message_guid for reaction events.
    public let associatedMessageGUID: String?
    /// The GUID of the message being replied to.
    public let replyToGUID: String?

    public init(
        rowID: Int64,
        chatID: Int64,
        guid: String,
        sender: String,
        isFromMe: Bool,
        text: String?,
        date: Date,
        service: String,
        hasAttachments: Bool = false,
        isReaction: Bool = false,
        reactionType: ReactionType? = nil,
        isReactionRemoval: Bool = false,
        associatedMessageGUID: String? = nil,
        replyToGUID: String? = nil
    ) {
        self.rowID = rowID
        self.chatID = chatID
        self.guid = guid
        self.sender = sender
        self.isFromMe = isFromMe
        self.text = text
        self.date = date
        self.service = service
        self.hasAttachments = hasAttachments
        self.isReaction = isReaction
        self.reactionType = reactionType
        self.isReactionRemoval = isReactionRemoval
        self.associatedMessageGUID = associatedMessageGUID
        self.replyToGUID = replyToGUID
    }
}

// MARK: - AttachmentMeta

/// Metadata about a file attachment on a message.
public struct AttachmentMeta: Sendable, Equatable {
    /// The user-facing filename (e.g., `"photo.heic"`).
    public let filename: String?
    /// The transfer-stage filename used during delivery.
    public let transferName: String?
    /// The Uniform Type Identifier (e.g., `"public.jpeg"`).
    public let uti: String?
    /// The MIME type (e.g., `"image/jpeg"`).
    public let mimeType: String?
    /// The file size in bytes.
    public let totalBytes: Int64
    /// Whether the attachment is a sticker.
    public let isSticker: Bool
    /// The original filesystem path in `~/Library/Messages/Attachments`.
    public let originalPath: String?
    /// `true` when the file is referenced but no longer on disk.
    public let missing: Bool

    public init(
        filename: String? = nil,
        transferName: String? = nil,
        uti: String? = nil,
        mimeType: String? = nil,
        totalBytes: Int64 = 0,
        isSticker: Bool = false,
        originalPath: String? = nil,
        missing: Bool = false
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

/// Predicate for filtering messages in database queries.
public struct MessageFilter: Sendable, Equatable {
    /// Only return messages after this date.
    public let afterDate: Date?
    /// Only return messages before this date.
    public let beforeDate: Date?
    /// Only return messages whose text contains this substring.
    public let textContains: String?
    /// Only return messages matching this from-me flag.
    public let isFromMe: Bool?

    public init(
        afterDate: Date? = nil,
        beforeDate: Date? = nil,
        textContains: String? = nil,
        isFromMe: Bool? = nil
    ) {
        self.afterDate = afterDate
        self.beforeDate = beforeDate
        self.textContains = textContains
        self.isFromMe = isFromMe
    }

    /// Creates a filter by parsing ISO 8601 date strings.
    public static func fromISO(
        startISO: String? = nil,
        endISO: String? = nil,
        textContains: String? = nil,
        isFromMe: Bool? = nil
    ) throws -> MessageFilter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let after: Date? = try startISO.map { iso in
            guard let date = formatter.date(from: iso) else {
                throw AppMeeeIMsgError.invalidISODate(iso)
            }
            return date
        }

        let before: Date? = try endISO.map { iso in
            guard let date = formatter.date(from: iso) else {
                throw AppMeeeIMsgError.invalidISODate(iso)
            }
            return date
        }

        return MessageFilter(
            afterDate: after,
            beforeDate: before,
            textContains: textContains,
            isFromMe: isFromMe
        )
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
