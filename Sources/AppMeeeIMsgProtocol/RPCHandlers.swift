import Foundation
import AppMeeeIMsgCore

// MARK: - RPC Method Handlers

extension RPCServer {

    // MARK: - chats.list

    func handleChatsList(id: Any?, params: [String: Any]) async throws {
        let limit = intParam(params["limit"]) ?? 20
        let chats = try store.listChats(limit: max(limit, 1))

        var payloads: [[String: Any]] = []
        payloads.reserveCapacity(chats.count)

        for chat in chats {
            let info = try await cache.info(chatID: chat.id)
            let participants = try await cache.participants(chatID: chat.id)
            let identifier = info?.identifier ?? chat.identifier
            let guid = info?.guid ?? ""
            let name = (info?.name.isEmpty == false ? info?.name : nil) ?? chat.name
            let service = info?.service ?? chat.service
            payloads.append(chatPayload(
                id: chat.id,
                identifier: identifier,
                guid: guid,
                name: name,
                service: service,
                lastMessageAt: chat.lastMessageAt,
                participants: participants
            ))
        }

        respond(id: id, result: ["chats": payloads])
    }

    // MARK: - messages.history

    func handleMessagesHistory(id: Any?, params: [String: Any]) async throws {
        guard let chatID = int64Param(params["chat_id"]) else {
            throw RPCError.invalidParams("chat_id is required")
        }

        let limit = intParam(params["limit"]) ?? 50
        let participants = stringArrayParam(params["participants"])
        let startISO = stringParam(params["start"])
        let endISO = stringParam(params["end"])
        let includeAttachments = boolParam(params["attachments"]) ?? false

        let filter = try MessageFilter.fromISO(
            participants: participants,
            startISO: startISO,
            endISO: endISO
        )

        let messages = try store.messages(chatID: chatID, limit: max(limit, 1), filter: filter)

        var payloads: [[String: Any]] = []
        payloads.reserveCapacity(messages.count)

        for message in messages {
            let payload = try await buildMessagePayload(
                message: message,
                includeAttachments: includeAttachments
            )
            payloads.append(payload)
        }

        respond(id: id, result: ["messages": payloads])
    }

    // MARK: - watch.subscribe

    func handleWatchSubscribe(id: Any?, params: [String: Any]) async throws {
        let chatID = int64Param(params["chat_id"])
        let sinceRowID = int64Param(params["since_rowid"])
        let participants = stringArrayParam(params["participants"])
        let startISO = stringParam(params["start"])
        let endISO = stringParam(params["end"])
        let includeAttachments = boolParam(params["attachments"]) ?? false
        let includeReactions = boolParam(params["include_reactions"]) ?? false

        let filter = try MessageFilter.fromISO(
            participants: participants,
            startISO: startISO,
            endISO: endISO
        )

        let config = MessageWatcherConfiguration(includeReactions: includeReactions)
        let subID = await subscriptions.allocateID()

        let localStore = store
        let localWatcher = watcher
        let localCache = cache
        let localOutput = output

        let task = Task {
            do {
                for try await message in localWatcher.stream(
                    chatID: chatID,
                    sinceRowID: sinceRowID,
                    configuration: config
                ) {
                    if Task.isCancelled { return }
                    if !filter.allows(message) { continue }

                    let chatInfo = try await localCache.info(chatID: message.chatID)
                    let chatParticipants = try await localCache.participants(chatID: message.chatID)
                    let attachments = includeAttachments ? try localStore.attachments(for: message.rowID) : []
                    let reactions = includeAttachments ? try localStore.reactions(for: message.rowID) : []
                    let payload = messagePayload(
                        message: message,
                        chatInfo: chatInfo,
                        participants: chatParticipants,
                        attachments: attachments,
                        reactions: reactions
                    )

                    localOutput.sendNotification(
                        method: "message",
                        params: ["subscription": subID, "message": payload]
                    )
                }
            } catch {
                localOutput.sendNotification(
                    method: "error",
                    params: [
                        "subscription": subID,
                        "error": ["message": String(describing: error)],
                    ]
                )
            }
        }

        await subscriptions.insert(task, for: subID)
        respond(id: id, result: ["subscription": subID])
    }

    // MARK: - watch.unsubscribe

    func handleWatchUnsubscribe(id: Any?, params: [String: Any]) async throws {
        guard let subID = intParam(params["subscription"]) else {
            throw RPCError.invalidParams("subscription is required")
        }
        if let task = await subscriptions.remove(subID) {
            task.cancel()
        }
        respond(id: id, result: ["ok": true])
    }

    // MARK: - send

    func handleSend(params: [String: Any], id: Any?) async throws {
        let text = stringParam(params["text"]) ?? ""
        let file = stringParam(params["file"]) ?? ""
        let serviceRaw = stringParam(params["service"]) ?? "auto"
        guard let service = MessageService.fromRPC(serviceRaw) else {
            throw RPCError.invalidParams("invalid service")
        }
        let region = stringParam(params["region"]) ?? "US"

        let input = ChatTargetInput(
            recipient: stringParam(params["to"]) ?? "",
            chatID: int64Param(params["chat_id"]),
            chatIdentifier: stringParam(params["chat_identifier"]) ?? "",
            chatGUID: stringParam(params["chat_guid"]) ?? ""
        )

        try ChatTargetResolver.validateRecipientRequirements(
            input: input,
            mixedTargetError: RPCError.invalidParams("use to or chat_*; not both"),
            missingRecipientError: RPCError.invalidParams("to is required for direct sends")
        )

        if text.isEmpty && file.isEmpty {
            throw RPCError.invalidParams("text or file is required")
        }

        let resolvedTarget = try await ChatTargetResolver.resolveChatTarget(
            input: input,
            lookupChat: { chatID in try await self.cache.info(chatID: chatID) },
            unknownChatError: { chatID in RPCError.invalidParams("unknown chat_id \(chatID)") }
        )

        if input.hasChatTarget && resolvedTarget.preferredIdentifier == nil {
            throw RPCError.invalidParams("missing chat identifier or guid")
        }

        try sendMessage(MessageSendOptions(
            recipient: input.recipient,
            text: text,
            attachmentPath: file,
            service: service,
            region: region,
            chatIdentifier: resolvedTarget.chatIdentifier,
            chatGUID: resolvedTarget.chatGUID
        ))

        respond(id: id, result: ["ok": true])
    }

    // MARK: - typing

    func handleTyping(params: [String: Any], id: Any?, start: Bool) async throws {
        let input = ChatTargetInput(
            recipient: stringParam(params["to"]) ?? "",
            chatID: int64Param(params["chat_id"]),
            chatIdentifier: stringParam(params["chat_identifier"]) ?? "",
            chatGUID: stringParam(params["chat_guid"]) ?? ""
        )

        try ChatTargetResolver.validateRecipientRequirements(
            input: input,
            mixedTargetError: RPCError.invalidParams("use to or chat_*; not both"),
            missingRecipientError: RPCError.invalidParams("to is required for direct typing")
        )

        let resolvedTarget = try await ChatTargetResolver.resolveChatTarget(
            input: input,
            lookupChat: { chatID in try await self.cache.info(chatID: chatID) },
            unknownChatError: { chatID in RPCError.invalidParams("unknown chat_id \(chatID)") }
        )

        let resolvedIdentifier: String
        if let preferred = resolvedTarget.preferredIdentifier {
            resolvedIdentifier = preferred
        } else if input.hasChatTarget {
            throw RPCError.invalidParams("missing chat identifier or guid")
        } else {
            let serviceRaw = stringParam(params["service"]) ?? "imessage"
            resolvedIdentifier = try ChatTargetResolver.directTypingIdentifier(
                recipient: input.recipient,
                serviceRaw: serviceRaw,
                invalidServiceError: { _ in RPCError.invalidParams("invalid service") }
            )
        }

        if start {
            try startTyping(resolvedIdentifier)
        } else {
            try stopTyping(resolvedIdentifier)
        }

        respond(id: id, result: ["ok": true])
    }

    // MARK: - react

    func handleReact(params: [String: Any], id: Any?) async throws {
        guard let chatID = int64Param(params["chat_id"]) else {
            throw RPCError.invalidParams("chat_id is required")
        }
        guard let reactionString = stringParam(params["reaction"]) else {
            throw RPCError.invalidParams("reaction is required")
        }
        guard let reactionType = ReactionType.parse(reactionString) else {
            throw RPCError.invalidParams("invalid reaction: \(reactionString)")
        }
        if case .custom(let emoji) = reactionType, !ReactionSender.isSingleEmoji(emoji) {
            throw RPCError.invalidParams("invalid reaction: \(reactionString)")
        }

        guard let chatInfo = try await cache.info(chatID: chatID) else {
            throw RPCError.invalidParams("unknown chat_id \(chatID)")
        }

        let chatLookup = ReactionSender.preferredChatLookup(chatInfo: chatInfo)
        try sendReaction(reactionType, chatInfo.guid, chatLookup)

        respond(id: id, result: [
            "ok": true,
            "reaction_type": reactionType.name,
            "reaction_emoji": reactionType.emoji,
        ])
    }
}

// MARK: - Private Helpers

extension RPCServer {

    private func buildMessagePayload(
        message: Message,
        includeAttachments: Bool
    ) async throws -> [String: Any] {
        let chatInfo = try await cache.info(chatID: message.chatID)
        let participants = try await cache.participants(chatID: message.chatID)
        let attachments = includeAttachments ? try store.attachments(for: message.rowID) : []
        let reactions = includeAttachments ? try store.reactions(for: message.rowID) : []
        return messagePayload(
            message: message,
            chatInfo: chatInfo,
            participants: participants,
            attachments: attachments,
            reactions: reactions
        )
    }
}
