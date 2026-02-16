import AppMeeeIMsgCore
import Foundation

enum SendCommand {
    static func run(options: CLIOptions) async throws {
        let dbPath = options.option("db") ?? MessageStore.defaultPath
        let input = ChatTargetInput(
            recipient: options.option("to") ?? "",
            chatID: options.optionInt64("chat-id"),
            chatIdentifier: options.option("chat-identifier") ?? "",
            chatGUID: options.option("chat-guid") ?? ""
        )
        try ChatTargetResolver.validateRecipientRequirements(
            input: input,
            mixedTargetError: CLIError.invalidOption("to"),
            missingRecipientError: CLIError.missingOption("to")
        )

        let text = options.option("text") ?? ""
        let file = options.option("file") ?? ""
        if text.isEmpty && file.isEmpty {
            throw CLIError.missingOption("text or file")
        }
        let serviceRaw = options.option("service") ?? "auto"
        guard let service = MessageService(rawValue: serviceRaw) else {
            throw AppMeeeIMsgError.invalidService(serviceRaw)
        }
        let region = options.option("region") ?? "US"

        let resolvedTarget = try await ChatTargetResolver.resolveChatTarget(
            input: input,
            lookupChat: { chatID in
                let store = try MessageStore(path: dbPath)
                return try store.chatInfo(chatID: chatID)
            },
            unknownChatError: { chatID in
                AppMeeeIMsgError.invalidChatTarget("Unknown chat id \(chatID)")
            }
        )
        if input.hasChatTarget && resolvedTarget.preferredIdentifier == nil {
            throw AppMeeeIMsgError.invalidChatTarget("Missing chat identifier or guid")
        }

        try MessageSender().send(MessageSendOptions(
            recipient: input.recipient,
            text: text,
            attachmentPath: file,
            service: service,
            region: region,
            chatIdentifier: resolvedTarget.chatIdentifier,
            chatGUID: resolvedTarget.chatGUID
        ))

        if options.jsonOutput {
            StdoutWriter.writeLine("{\"status\":\"sent\"}")
        } else {
            StdoutWriter.writeLine("sent")
        }
    }
}
