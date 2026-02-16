import Foundation
import AppMeeeIMsgCore

// MARK: - RPC Method Handlers

extension RPCServer {

    // MARK: - chats.list

    /// Handles the `chats.list` JSON-RPC method.
    ///
    /// Returns an array of chat payloads ordered by most recent activity,
    /// enriched with cached metadata and participant lists.
    ///
    /// - Parameters:
    ///   - id: The JSON-RPC request ID.
    ///   - params: Optional dictionary containing `limit` (default 20, minimum 1).
    func handleChatsList(id: Any, params: [String: Any]?) async throws {
        let limit = max(intParam(params?["limit"]) ?? 20, 1)
        let chats = try store.listChats(limit: limit)

        var payloads: [[String: Any]] = []
        payloads.reserveCapacity(chats.count)

        for chat in chats {
            let info = try await cache.info(chatID: chat.id)
            let participants = try await cache.participants(chatID: chat.id)

            payloads.append(chatPayload(
                id: chat.id,
                identifier: info?.identifier ?? chat.identifier,
                guid: info?.guid ?? "",
                name: chat.name,
                service: chat.service,
                lastMessageDate: chat.lastMessageDate,
                participants: participants
            ))
        }

        respond(id: id, result: ["chats": payloads])
    }

    // MARK: - messages.history

    /// Handles the `messages.history` JSON-RPC method.
    ///
    /// Returns message history for a specific chat with optional filtering
    /// by date range, text content, direction, and enrichment with
    /// attachments and reactions.
    ///
    /// - Parameters:
    ///   - id: The JSON-RPC request ID.
    ///   - params: Dictionary requiring `chat_id` and supporting optional
    ///     `limit`, `start`, `end`, `text_contains`, `from_me`,
    ///     `attachments`, and `include_reactions`.
    func handleMessagesHistory(id: Any, params: [String: Any]?) async throws {
        guard let params, let chatID = int64Param(params["chat_id"]) else {
            throw RPCError.invalidParams("chat_id is required")
        }

        let limit = intParam(params["limit"]) ?? 50
        let startISO = stringParam(params["start"])
        let endISO = stringParam(params["end"])
        let textContains = stringParam(params["text_contains"])
        let fromMe = boolParam(params["from_me"])
        let includeAttachments = boolParam(params["attachments"]) ?? false
        let includeReactions = boolParam(params["include_reactions"]) ?? false

        let filter: MessageFilter?
        if startISO != nil || endISO != nil || textContains != nil || fromMe != nil {
            filter = try MessageFilter.fromISO(
                startISO: startISO,
                endISO: endISO,
                textContains: textContains,
                isFromMe: fromMe
            )
        } else {
            filter = nil
        }

        let messages = try store.messages(chatID: chatID, limit: limit, filter: filter)

        var payloads: [[String: Any]] = []
        payloads.reserveCapacity(messages.count)

        for message in messages {
            let payload = try await buildMessagePayload(
                message: message,
                includeAttachments: includeAttachments,
                includeReactions: includeReactions
            )
            payloads.append(payload)
        }

        respond(id: id, result: ["messages": payloads])
    }

    // MARK: - watch.subscribe

    /// Handles the `watch.subscribe` JSON-RPC method.
    ///
    /// Creates a real-time subscription that streams new messages as
    /// JSON-RPC notifications. Returns the allocated subscription ID.
    ///
    /// - Parameters:
    ///   - id: The JSON-RPC request ID.
    ///   - params: Optional dictionary with `chat_id`, `since_rowid`,
    ///     `attachments`, and `include_reactions`.
    func handleWatchSubscribe(id: Any, params: [String: Any]?) async throws {
        let chatID = int64Param(params?["chat_id"])
        let sinceRowID = int64Param(params?["since_rowid"])
        let includeAttachments = boolParam(params?["attachments"]) ?? false
        let includeReactions = boolParam(params?["include_reactions"]) ?? false

        let subID = await subscriptions.allocateID()

        let configuration = MessageWatcherConfiguration(includeReactions: includeReactions)

        let localWatcher = watcher
        let localStore = store
        let localCache = cache

        let task = Task<Void, Never> {
            do {
                let stream = localWatcher.stream(
                    chatID: chatID,
                    sinceRowID: sinceRowID,
                    configuration: configuration
                )
                for try await message in stream {
                    if Task.isCancelled { break }

                    let chatInfo = try await localCache.info(chatID: message.chatID)
                    let participants = try await localCache.participants(chatID: message.chatID)
                    let attachments = includeAttachments
                        ? try localStore.attachments(for: message.rowID) : []
                    let reactions = includeReactions
                        ? try localStore.reactions(for: message.rowID) : []
                    let payload = messagePayload(
                        message: message,
                        chatInfo: chatInfo,
                        participants: participants,
                        attachments: attachments,
                        reactions: reactions
                    )

                    let notification: [String: Any] = [
                        "jsonrpc": "2.0",
                        "method": "message",
                        "params": ["subscription": subID, "message": payload] as [String: Any],
                    ]
                    StdoutWriter.writeJSON(notification)
                }
            } catch {
                let notification: [String: Any] = [
                    "jsonrpc": "2.0",
                    "method": "error",
                    "params": [
                        "subscription": subID,
                        "error": ["message": String(describing: error)],
                    ] as [String: Any],
                ]
                StdoutWriter.writeJSON(notification)
            }
        }

        await subscriptions.insert(task, for: subID)
        respond(id: id, result: ["subscription": subID])
    }

    // MARK: - watch.unsubscribe

    /// Handles the `watch.unsubscribe` JSON-RPC method.
    ///
    /// Cancels an active watch subscription by its ID.
    ///
    /// - Parameters:
    ///   - id: The JSON-RPC request ID.
    ///   - params: Dictionary requiring `subscription` (Int).
    func handleWatchUnsubscribe(id: Any, params: [String: Any]?) async throws {
        guard let params, let subID = intParam(params["subscription"]) else {
            throw RPCError.invalidParams("subscription is required")
        }

        let task = await subscriptions.remove(subID)
        task?.cancel()

        respond(id: id, result: ["ok": true])
    }

    // MARK: - send

    /// Handles the `send` JSON-RPC method.
    ///
    /// Sends a message to a recipient or existing chat. Supports text,
    /// file attachments, service selection, and multiple targeting modes.
    ///
    /// - Parameters:
    ///   - id: The JSON-RPC request ID.
    ///   - params: Dictionary with message content and targeting options.
    func handleSend(id: Any, params: [String: Any]?) async throws {
        guard let params else {
            throw RPCError.invalidParams("params are required")
        }

        let text = stringParam(params["text"])
        let file = stringParam(params["file"])
        let serviceStr = stringParam(params["service"]) ?? "auto"
        let region = stringParam(params["region"]) ?? "US"

        let to = stringParam(params["to"])
        let chatID = int64Param(params["chat_id"])
        let chatIdentifier = stringParam(params["chat_identifier"])
        let chatGUID = stringParam(params["chat_guid"])

        guard text != nil || file != nil else {
            throw RPCError.invalidParams("at least text or file must be provided")
        }

        let hasDirectTarget = to != nil
        let hasChatTarget = chatID != nil || chatIdentifier != nil || chatGUID != nil

        guard hasDirectTarget || hasChatTarget else {
            throw RPCError.invalidParams(
                "must provide either 'to' or one of 'chat_id', 'chat_identifier', 'chat_guid'"
            )
        }

        guard !(hasDirectTarget && hasChatTarget) else {
            throw RPCError.invalidParams(
                "cannot provide both 'to' and chat targeting parameters"
            )
        }

        var resolvedIdentifier = chatIdentifier
        var resolvedGUID = chatGUID
        let recipient = to ?? ""

        if let chatID {
            guard let info = try await cache.info(chatID: chatID) else {
                throw RPCError.invalidParams("no chat found with id \(chatID)")
            }
            resolvedIdentifier = info.identifier
            resolvedGUID = info.guid
        }

        guard let service = MessageService(rawValue: serviceStr) else {
            throw RPCError.invalidParams(
                "invalid service '\(serviceStr)'. Use 'iMessage', 'SMS', or 'auto'"
            )
        }

        if recipient.isEmpty, resolvedIdentifier == nil, resolvedGUID == nil {
            throw RPCError.invalidParams("could not resolve message target")
        }

        let options = MessageSendOptions(
            recipient: recipient,
            text: text,
            attachmentPath: file,
            service: service,
            region: region,
            chatIdentifier: resolvedIdentifier,
            chatGUID: resolvedGUID
        )

        try sendMessage(options)
        respond(id: id, result: ["ok": true])
    }

    // MARK: - typing

    /// Handles the `typing.start` and `typing.stop` JSON-RPC methods.
    ///
    /// Sends a typing indicator to the resolved chat target.
    ///
    /// - Parameters:
    ///   - id: The JSON-RPC request ID.
    ///   - params: Dictionary with targeting options.
    ///   - start: Whether to start (`true`) or stop (`false`) the typing indicator.
    func handleTyping(id: Any, params: [String: Any]?, start: Bool) async throws {
        let to = stringParam(params?["to"])
        let chatIdentifierParam = stringParam(params?["chat_identifier"])
        let chatGUIDParam = stringParam(params?["chat_guid"])
        let chatID = int64Param(params?["chat_id"])

        guard to != nil || chatIdentifierParam != nil || chatGUIDParam != nil || chatID != nil else {
            throw RPCError.invalidParams(
                "must provide at least one of 'to', 'chat_identifier', 'chat_guid', or 'chat_id'"
            )
        }

        let identifier: String
        if let chatGUIDParam {
            identifier = chatGUIDParam
        } else if let chatIdentifierParam {
            identifier = chatIdentifierParam
        } else if let chatID {
            guard let info = try await cache.info(chatID: chatID) else {
                throw RPCError.invalidParams("no chat found with id \(chatID)")
            }
            identifier = info.guid.isEmpty ? info.identifier : info.guid
        } else if let to {
            let servicePrefix = stringParam(params?["service"]) ?? "iMessage"
            identifier = "\(servicePrefix);-;\(to)"
        } else {
            throw RPCError.invalidParams("could not resolve typing target")
        }

        if start {
            try startTyping(identifier)
        } else {
            try stopTyping(identifier)
        }

        respond(id: id, result: ["ok": true])
    }
}

// MARK: - Private Helpers

extension RPCServer {

    /// Builds a complete message payload with optional attachments and reactions.
    ///
    /// Resolves chat metadata from the cache actor and fetches attachment/reaction
    /// data from the store when requested.
    ///
    /// - Parameters:
    ///   - message: The message to serialize.
    ///   - includeAttachments: Whether to fetch and include attachment metadata.
    ///   - includeReactions: Whether to fetch and include reaction data.
    /// - Returns: A JSON-compatible dictionary representing the message.
    private func buildMessagePayload(
        message: Message,
        includeAttachments: Bool,
        includeReactions: Bool
    ) async throws -> [String: Any] {
        let chatInfo = try await cache.info(chatID: message.chatID)
        let participants = try await cache.participants(chatID: message.chatID)

        let attachments: [AttachmentMeta]
        if includeAttachments {
            attachments = try store.attachments(for: message.rowID)
        } else {
            attachments = []
        }

        let reactions: [Reaction]
        if includeReactions {
            reactions = try store.reactions(for: message.rowID)
        } else {
            reactions = []
        }

        return messagePayload(
            message: message,
            chatInfo: chatInfo,
            participants: participants,
            attachments: attachments,
            reactions: reactions
        )
    }
}
