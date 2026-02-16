import Foundation

/// Resolves and validates attachment file paths from the iMessage database.
///
/// Attachment paths in `chat.db` use tilde notation (`~/Library/Messages/Attachments/...`).
/// This resolver expands those paths and checks whether the referenced file still exists on disk.
enum AttachmentResolver {

    /// Resolves a tilde-prefixed path and checks file existence.
    ///
    /// - Parameter path: The raw path from the `attachment.filename` column.
    /// - Returns: A tuple of the expanded absolute path and whether the file is missing.
    static func resolve(_ path: String) -> (resolved: String, missing: Bool) {
        guard !path.isEmpty else { return ("", true) }
        let expanded = (path as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir)
        return (expanded, !(exists && !isDir.boolValue))
    }

    /// Returns a human-readable display name for an attachment.
    ///
    /// Prefers the transfer name (which preserves the original sender's filename),
    /// then falls back to the local filename, then to a placeholder.
    ///
    /// - Parameters:
    ///   - filename: The local filename from the `attachment.filename` column.
    ///   - transferName: The transfer-stage filename from the `attachment.transfer_name` column.
    /// - Returns: The best available display name.
    static func displayName(filename: String, transferName: String) -> String {
        if !transferName.isEmpty { return transferName }
        if !filename.isEmpty { return filename }
        return "(unknown)"
    }
}
