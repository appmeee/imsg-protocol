import AppMeeeIMsgCore

/// Parsed input for resolving a chat target from RPC parameters.
struct ChatTargetInput: Sendable {
    let recipient: String
    let chatID: Int64?
    let chatIdentifier: String
    let chatGUID: String

    var hasChatTarget: Bool {
        chatID != nil || !chatIdentifier.isEmpty || !chatGUID.isEmpty
    }
}

/// A resolved chat target with identifier and GUID.
struct ResolvedChatTarget: Sendable {
    let chatIdentifier: String
    let chatGUID: String

    var preferredIdentifier: String? {
        if !chatGUID.isEmpty { return chatGUID }
        if !chatIdentifier.isEmpty { return chatIdentifier }
        return nil
    }
}

/// Validates and resolves chat targets from RPC parameters.
///
/// Handles the mutual exclusion between direct recipient (`to`) and
/// chat-based targeting (`chat_id`, `chat_identifier`, `chat_guid`).
enum ChatTargetResolver {

    /// Validates that the caller provided either a direct recipient or a chat target, not both.
    static func validateRecipientRequirements(
        input: ChatTargetInput,
        mixedTargetError: Error,
        missingRecipientError: Error
    ) throws {
        if input.hasChatTarget && !input.recipient.isEmpty {
            throw mixedTargetError
        }
        if !input.hasChatTarget && input.recipient.isEmpty {
            throw missingRecipientError
        }
    }

    /// Resolves a chat target by looking up chat info from the store when a `chat_id` is provided.
    static func resolveChatTarget(
        input: ChatTargetInput,
        lookupChat: (Int64) async throws -> ChatInfo?,
        unknownChatError: (Int64) -> Error
    ) async throws -> ResolvedChatTarget {
        var resolvedIdentifier = input.chatIdentifier
        var resolvedGUID = input.chatGUID

        if let chatID = input.chatID {
            guard let info = try await lookupChat(chatID) else {
                throw unknownChatError(chatID)
            }
            resolvedIdentifier = info.identifier
            resolvedGUID = info.guid
        }

        return ResolvedChatTarget(
            chatIdentifier: resolvedIdentifier,
            chatGUID: resolvedGUID
        )
    }

    /// Builds a typing indicator identifier for a direct recipient.
    static func directTypingIdentifier(
        recipient: String,
        serviceRaw: String,
        invalidServiceError: (String) -> Error
    ) throws -> String {
        guard let service = MessageService.fromRPC(serviceRaw) else {
            throw invalidServiceError(serviceRaw)
        }
        let prefix = service == .sms ? "SMS" : "iMessage"
        return "\(prefix);-;\(recipient)"
    }
}
