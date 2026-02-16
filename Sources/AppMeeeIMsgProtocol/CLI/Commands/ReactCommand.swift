import AppMeeeIMsgCore
import Foundation

enum ReactCommand {
    static func run(options: CLIOptions) async throws {
        guard let chatID = options.optionInt64("chat-id") else {
            throw CLIError.missingOption("chat-id")
        }
        guard let reactionString = options.option("reaction") else {
            throw CLIError.missingOption("reaction")
        }
        guard let reactionType = ReactionType.parse(reactionString) else {
            throw AppMeeeIMsgError.invalidReaction(reactionString)
        }
        if case .custom(let emoji) = reactionType, !ReactionSender.isSingleEmoji(emoji) {
            throw AppMeeeIMsgError.invalidReaction(reactionString)
        }

        let dbPath = options.option("db") ?? MessageStore.defaultPath
        let store = try MessageStore(path: dbPath)
        guard let chatInfo = try store.chatInfo(chatID: chatID) else {
            throw AppMeeeIMsgError.chatNotFound(chatID: chatID)
        }

        let chatLookup = ReactionSender.preferredChatLookup(chatInfo: chatInfo)
        try ReactionSender.send(
            reactionType: reactionType,
            chatGUID: chatInfo.guid,
            chatLookup: chatLookup
        )

        if options.jsonOutput {
            try CLIFormatter.writeJSONLine(CLIReactResult(
                success: true,
                chatID: chatID,
                reactionType: reactionType.name,
                reactionEmoji: reactionType.emoji
            ))
        } else {
            StdoutWriter.writeLine("Sent \(reactionType.emoji) reaction to chat \(chatID)")
        }
    }
}
