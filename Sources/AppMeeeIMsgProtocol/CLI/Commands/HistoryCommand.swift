import AppMeeeIMsgCore
import Foundation

enum HistoryCommand {
    static func run(options: CLIOptions) async throws {
        guard let chatID = options.optionInt64("chat-id") else {
            throw CLIError.missingOption("chat-id")
        }
        let dbPath = options.option("db") ?? MessageStore.defaultPath
        let limit = options.optionInt("limit") ?? 50
        let showAttachments = options.flag("attachments")
        let participants = parseParticipants(options.optionValues("participants"))
        let filter = try MessageFilter.fromISO(
            participants: participants,
            startISO: options.option("start"),
            endISO: options.option("end")
        )

        let store = try MessageStore(path: dbPath)
        let messages = try store.messages(chatID: chatID, limit: limit, filter: filter)

        if options.jsonOutput {
            for message in messages {
                let attachments = try store.attachments(for: message.rowID)
                let reactions = try store.reactions(for: message.rowID)
                try CLIFormatter.writeJSONLine(
                    CLIMessagePayload(message: message, attachments: attachments, reactions: reactions)
                )
            }
            return
        }

        for message in messages {
            let direction = message.isFromMe ? "sent" : "recv"
            let timestamp = CLIFormatter.formatDate(message.date)
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

    private static func parseParticipants(_ values: [String]) -> [String] {
        values
            .flatMap { $0.split(separator: ",").map { String($0) } }
            .filter { !$0.isEmpty }
    }
}
