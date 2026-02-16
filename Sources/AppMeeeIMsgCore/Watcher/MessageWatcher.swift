import Darwin
import Foundation

/// Configuration for real-time message detection on the iMessage database.
public struct MessageWatcherConfiguration: Sendable, Equatable {
    /// Minimum delay between filesystem event and database poll, in seconds.
    public var debounceInterval: TimeInterval
    /// Maximum number of messages fetched per poll cycle.
    public var batchLimit: Int
    /// When true, reaction events (tapback add/remove) are included in the stream.
    public var includeReactions: Bool

    public init(
        debounceInterval: TimeInterval = 0.25,
        batchLimit: Int = 100,
        includeReactions: Bool = false
    ) {
        self.debounceInterval = debounceInterval
        self.batchLimit = batchLimit
        self.includeReactions = includeReactions
    }
}

/// Watches the iMessage chat.db for new messages using filesystem event sources.
///
/// Creates `DispatchSource` monitors on chat.db, chat.db-wal, and chat.db-shm to
/// detect writes in real time. Each filesystem event triggers a debounced poll that
/// queries `MessageStore` for rows newer than the current cursor position.
///
/// Usage:
/// ```swift
/// let store = try MessageStore()
/// let watcher = MessageWatcher(store: store)
/// for try await message in watcher.stream() {
///     print(message.text)
/// }
/// ```
public final class MessageWatcher: @unchecked Sendable {
    private let store: MessageStore

    public init(store: MessageStore) {
        self.store = store
    }

    /// Returns an async stream that yields each new `Message` as it arrives in chat.db.
    ///
    /// - Parameters:
    ///   - chatID: Optional chat filter. When nil, messages from all chats are yielded.
    ///   - sinceRowID: Starting cursor position. When nil, starts from the current max ROWID.
    ///   - configuration: Debounce, batch, and reaction settings.
    /// - Returns: An `AsyncThrowingStream` of `Message` values.
    public func stream(
        chatID: Int64? = nil,
        sinceRowID: Int64? = nil,
        configuration: MessageWatcherConfiguration = .init()
    ) -> AsyncThrowingStream<Message, Error> {
        AsyncThrowingStream { continuation in
            let state = WatchState(
                store: self.store,
                chatID: chatID,
                sinceRowID: sinceRowID,
                configuration: configuration,
                continuation: continuation
            )
            state.start()
            continuation.onTermination = { _ in
                state.stop()
            }
        }
    }
}

// MARK: - Internal Watch State

/// Encapsulates the mutable state and dispatch sources for a single watch session.
///
/// Marked `@unchecked Sendable` because all mutable state is exclusively accessed
/// on `queue`, a serial dispatch queue. The continuation itself is thread-safe.
private final class WatchState: @unchecked Sendable {
    private let store: MessageStore
    private let chatID: Int64?
    private let configuration: MessageWatcherConfiguration
    private let continuation: AsyncThrowingStream<Message, Error>.Continuation
    private let queue = DispatchQueue(label: "appmeee.imsg.watch", qos: .userInitiated)

    private var cursor: Int64
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending = false

    init(
        store: MessageStore,
        chatID: Int64?,
        sinceRowID: Int64?,
        configuration: MessageWatcherConfiguration,
        continuation: AsyncThrowingStream<Message, Error>.Continuation
    ) {
        self.store = store
        self.chatID = chatID
        self.configuration = configuration
        self.continuation = continuation
        self.cursor = sinceRowID ?? 0
    }

    func start() {
        queue.async { [self] in
            do {
                if self.cursor == 0 {
                    self.cursor = try self.store.maxRowID()
                }
                self.poll()
            } catch {
                self.continuation.finish(throwing: error)
            }
        }

        let paths = [store.path, store.path + "-wal", store.path + "-shm"]
        for path in paths {
            if let source = makeSource(path: path) {
                sources.append(source)
            }
        }
    }

    func stop() {
        queue.async { [self] in
            for source in self.sources {
                source.cancel()
            }
            self.sources.removeAll()
        }
    }

    // MARK: - Filesystem Monitoring

    private func makeSource(path: String) -> DispatchSourceFileSystemObject? {
        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            self?.schedulePoll()
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        return source
    }

    // MARK: - Debounced Polling

    private func schedulePoll() {
        guard !pending else { return }
        pending = true

        let delay = configuration.debounceInterval
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.pending = false
            self.poll()
        }
    }

    private func poll() {
        do {
            let messages = try store.messagesAfter(
                afterRowID: cursor,
                chatID: chatID,
                limit: configuration.batchLimit,
                includeReactions: configuration.includeReactions
            )

            for message in messages {
                continuation.yield(message)
                if message.rowID > cursor {
                    cursor = message.rowID
                }
            }
        } catch {
            continuation.finish(throwing: error)
        }
    }
}
