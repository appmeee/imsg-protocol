import Foundation

/// Errors produced by the AppMeee iMessage protocol layer.
///
/// Each case preserves enough context to produce a meaningful
/// diagnostic without leaking implementation details.
public enum AppMeeeIMsgError: LocalizedError, Sendable, Equatable {
    /// Full Disk Access or file-level permission was denied.
    case permissionDenied(path: String, detail: String)
    /// The chat.db file does not exist at the expected path.
    case databaseNotFound(path: String)
    /// A generic database operation failed.
    case databaseError(detail: String)
    /// An ISO 8601 date string could not be parsed.
    case invalidISODate(String)
    /// An unrecognized service name was provided.
    case invalidService(String)
    /// The recipient or chat target could not be resolved.
    case invalidChatTarget(String)
    /// An AppleScript execution failed.
    case appleScriptFailure(String)
    /// Sending a typing indicator failed.
    case typingIndicatorFailed(String)
    /// A reaction string or code could not be interpreted.
    case invalidReaction(String)
    /// No chat exists with the given database row ID.
    case chatNotFound(chatID: Int64)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let path, let detail):
            return "Permission denied for '\(path)': \(detail)"
        case .databaseNotFound(let path):
            return "iMessage database not found at '\(path)'. "
                + "Ensure Messages.app has been opened at least once."
        case .databaseError(let detail):
            return "Database error: \(detail)"
        case .invalidISODate(let value):
            return "Cannot parse '\(value)' as an ISO 8601 date. "
                + "Expected format: yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        case .invalidService(let name):
            return "Unknown messaging service '\(name)'. Use 'iMessage', 'SMS', or 'auto'."
        case .invalidChatTarget(let target):
            return "Cannot resolve chat target '\(target)'. "
                + "Provide a valid phone number, email, or chat GUID."
        case .appleScriptFailure(let detail):
            return "AppleScript execution failed: \(detail)"
        case .typingIndicatorFailed(let detail):
            return "Typing indicator failed: \(detail)"
        case .invalidReaction(let detail):
            return "Invalid reaction: \(detail). "
                + "Use a named type (love, like, dislike, laugh, emphasis, question) or an emoji."
        case .chatNotFound(let chatID):
            return "No chat found with ROWID \(chatID) in chat.db."
        }
    }
}

