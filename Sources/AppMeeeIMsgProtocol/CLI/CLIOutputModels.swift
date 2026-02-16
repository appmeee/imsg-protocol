import AppMeeeIMsgCore
import Foundation

struct CLIChatPayload: Codable {
    let id: Int64
    let name: String
    let identifier: String
    let service: String
    let lastMessageAt: String

    init(chat: Chat) {
        self.id = chat.id
        self.name = chat.name
        self.identifier = chat.identifier
        self.service = chat.service
        self.lastMessageAt = CLIFormatter.formatDate(chat.lastMessageAt)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, identifier, service
        case lastMessageAt = "last_message_at"
    }
}

struct CLIMessagePayload: Codable {
    let id: Int64
    let chatID: Int64
    let guid: String
    let replyToGUID: String?
    let threadOriginatorGUID: String?
    let sender: String
    let isFromMe: Bool
    let text: String
    let createdAt: String
    let attachments: [CLIAttachmentPayload]
    let reactions: [CLIReactionPayload]
    let destinationCallerID: String?
    let isReaction: Bool?
    let reactionType: String?
    let reactionEmoji: String?
    let isReactionAdd: Bool?
    let reactedToGUID: String?

    init(message: Message, attachments: [AttachmentMeta], reactions: [Reaction] = []) {
        self.id = message.rowID
        self.chatID = message.chatID
        self.guid = message.guid
        self.replyToGUID = message.replyToGUID
        self.threadOriginatorGUID = message.threadOriginatorGUID
        self.sender = message.sender
        self.isFromMe = message.isFromMe
        self.text = message.text
        self.createdAt = CLIFormatter.formatDate(message.date)
        self.attachments = attachments.map { CLIAttachmentPayload(meta: $0) }
        self.reactions = reactions.map { CLIReactionPayload(reaction: $0) }
        self.destinationCallerID = message.destinationCallerID

        if message.isReaction {
            self.isReaction = true
            self.reactionType = message.reactionType?.name
            self.reactionEmoji = message.reactionType?.emoji
            self.isReactionAdd = message.isReactionAdd
            self.reactedToGUID = message.reactedToGUID
        } else {
            self.isReaction = nil
            self.reactionType = nil
            self.reactionEmoji = nil
            self.isReactionAdd = nil
            self.reactedToGUID = nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, guid, sender, text, attachments, reactions
        case chatID = "chat_id"
        case replyToGUID = "reply_to_guid"
        case threadOriginatorGUID = "thread_originator_guid"
        case isFromMe = "is_from_me"
        case createdAt = "created_at"
        case destinationCallerID = "destination_caller_id"
        case isReaction = "is_reaction"
        case reactionType = "reaction_type"
        case reactionEmoji = "reaction_emoji"
        case isReactionAdd = "is_reaction_add"
        case reactedToGUID = "reacted_to_guid"
    }
}

struct CLIReactionPayload: Codable {
    let id: Int64
    let type: String
    let emoji: String
    let sender: String
    let isFromMe: Bool
    let createdAt: String

    init(reaction: Reaction) {
        self.id = reaction.rowID
        self.type = reaction.reactionType.name
        self.emoji = reaction.reactionType.emoji
        self.sender = reaction.sender
        self.isFromMe = reaction.isFromMe
        self.createdAt = CLIFormatter.formatDate(reaction.date)
    }

    enum CodingKeys: String, CodingKey {
        case id, type, emoji, sender
        case isFromMe = "is_from_me"
        case createdAt = "created_at"
    }
}

struct CLIAttachmentPayload: Codable {
    let filename: String
    let transferName: String
    let uti: String
    let mimeType: String
    let totalBytes: Int64
    let isSticker: Bool
    let originalPath: String
    let missing: Bool

    init(meta: AttachmentMeta) {
        self.filename = meta.filename
        self.transferName = meta.transferName
        self.uti = meta.uti
        self.mimeType = meta.mimeType
        self.totalBytes = meta.totalBytes
        self.isSticker = meta.isSticker
        self.originalPath = meta.originalPath
        self.missing = meta.missing
    }

    enum CodingKeys: String, CodingKey {
        case filename, uti, missing
        case transferName = "transfer_name"
        case mimeType = "mime_type"
        case totalBytes = "total_bytes"
        case isSticker = "is_sticker"
        case originalPath = "original_path"
    }
}

struct CLIReactResult: Codable {
    let success: Bool
    let chatID: Int64
    let reactionType: String
    let reactionEmoji: String

    enum CodingKeys: String, CodingKey {
        case success
        case chatID = "chat_id"
        case reactionType = "reaction_type"
        case reactionEmoji = "reaction_emoji"
    }
}
