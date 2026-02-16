import AppMeeeIMsgCore
import Foundation

enum ChatsCommand {
    static func run(options: CLIOptions) async throws {
        let dbPath = options.option("db") ?? MessageStore.defaultPath
        let limit = options.optionInt("limit") ?? 20
        let store = try MessageStore(path: dbPath)
        let chats = try store.listChats(limit: limit)

        if options.jsonOutput {
            for chat in chats {
                try CLIFormatter.writeJSONLine(CLIChatPayload(chat: chat))
            }
            return
        }

        for chat in chats {
            let last = CLIFormatter.formatDate(chat.lastMessageAt)
            StdoutWriter.writeLine("[\(chat.id)] \(chat.name) (\(chat.identifier)) last=\(last)")
        }
    }
}
