import AppMeeeIMsgCore
import Foundation

enum WatchCommand {
    static func run(options: CLIOptions) async throws {
        let dbPath = options.option("db") ?? MessageStore.defaultPath
        let chatID = options.optionInt64("chat-id")
        let sinceRowID = options.optionInt64("since-rowid")
        let showAttachments = options.flag("attachments")
        let includeReactions = options.flag("reactions")
        let participants = options.optionValues("participants")
            .flatMap { $0.split(separator: ",").map { String($0) } }
            .filter { !$0.isEmpty }
        let filter = try MessageFilter.fromISO(
            participants: participants,
            startISO: options.option("start"),
            endISO: options.option("end")
        )

        let store = try MessageStore(path: dbPath)
        let watcher = MessageWatcher(store: store)
        let config = MessageWatcherConfiguration(includeReactions: includeReactions)

        for try await message in watcher.stream(
            chatID: chatID,
            sinceRowID: sinceRowID,
            configuration: config
        ) {
            if !filter.allows(message) { continue }

            if options.jsonOutput {
                let attachments = try store.attachments(for: message.rowID)
                let reactions = try store.reactions(for: message.rowID)
                try CLIFormatter.writeJSONLine(
                    CLIMessagePayload(message: message, attachments: attachments, reactions: reactions)
                )
                continue
            }

            let direction = message.isFromMe ? "sent" : "recv"
            let timestamp = CLIFormatter.formatDate(message.date)

            if message.isReaction, let reactionType = message.reactionType {
                let action = (message.isReactionAdd ?? true) ? "added" : "removed"
                let targetGUID = message.reactedToGUID ?? "unknown"
                StdoutWriter.writeLine(
                    "\(timestamp) [\(direction)] \(message.sender) \(action) \(reactionType.emoji) reaction to \(targetGUID)"
                )
                continue
            }

            StdoutWriter.writeLine("\(timestamp) [\(direction)] \(message.sender): \(message.text)")
            if message.attachmentsCount > 0 {
                if showAttachments {
                    let metas = try store.attachments(for: message.rowID)
                    for meta in metas {
                        let name = CLIFormatter.displayName(for: meta)
                        StdoutWriter.writeLine(
                            "  attachment: name=\(name) mime=\(meta.mimeType) missing=\(meta.missing) path=\(meta.originalPath)"
                        )
                    }
                } else {
                    StdoutWriter.writeLine(
                        "  (\(message.attachmentsCount) attachment\(CLIFormatter.pluralSuffix(for: message.attachmentsCount)))"
                    )
                }
            }
        }
    }
}
