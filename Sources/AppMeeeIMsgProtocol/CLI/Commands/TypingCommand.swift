import AppMeeeIMsgCore
import Foundation

enum TypingCommand {
    static func run(options: CLIOptions) async throws {
        let dbPath = options.option("db") ?? MessageStore.defaultPath
        let input = ChatTargetInput(
            recipient: options.option("to") ?? "",
            chatID: options.optionInt64("chat-id"),
            chatIdentifier: options.option("chat-identifier") ?? "",
            chatGUID: options.option("chat-guid") ?? ""
        )
        let stopFlag = options.flag("stop")
        let durationRaw = options.option("duration") ?? ""
        let serviceRaw = options.option("service") ?? "imessage"

        try ChatTargetResolver.validateRecipientRequirements(
            input: input,
            mixedTargetError: CLIError.invalidOption("to"),
            missingRecipientError: CLIError.missingOption("to")
        )

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
        let resolvedIdentifier: String
        if let preferred = resolvedTarget.preferredIdentifier {
            resolvedIdentifier = preferred
        } else if input.hasChatTarget {
            throw AppMeeeIMsgError.invalidChatTarget("Missing chat identifier or guid")
        } else {
            resolvedIdentifier = try ChatTargetResolver.directTypingIdentifier(
                recipient: input.recipient,
                serviceRaw: serviceRaw,
                invalidServiceError: { AppMeeeIMsgError.invalidService($0) }
            )
        }

        if stopFlag {
            try TypingIndicator.stopTyping(chatIdentifier: resolvedIdentifier)
            if options.jsonOutput {
                StdoutWriter.writeLine("{\"status\":\"stopped\"}")
            } else {
                StdoutWriter.writeLine("typing indicator stopped")
            }
            return
        }

        if !durationRaw.isEmpty {
            guard let seconds = DurationParser.parse(durationRaw), seconds > 0 else {
                throw AppMeeeIMsgError.typingIndicatorFailed(
                    "Invalid duration: \(durationRaw). Use e.g. 5s, 3000ms, 1m, or 1h"
                )
            }
            try await TypingIndicator.typeForDuration(
                chatIdentifier: resolvedIdentifier,
                duration: seconds
            )
            if options.jsonOutput {
                StdoutWriter.writeLine("{\"status\":\"completed\",\"duration_s\":\(seconds)}")
            } else {
                StdoutWriter.writeLine("typing indicator shown for \(durationRaw)")
            }
            return
        }

        try TypingIndicator.startTyping(chatIdentifier: resolvedIdentifier)
        if options.jsonOutput {
            StdoutWriter.writeLine("{\"status\":\"started\"}")
        } else {
            StdoutWriter.writeLine("typing indicator started")
        }
    }
}
