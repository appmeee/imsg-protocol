import Foundation

/// Sends tapback reactions via AppleScript + System Events UI automation.
///
/// - Important: Requires Accessibility permissions for System Events
///   and Messages.app to be running.
public enum ReactionSender {

    /// Sends a standard (non-custom) tapback reaction to the most recent message in a chat.
    ///
    /// - Parameters:
    ///   - reactionType: The reaction to apply. Must not be `.custom`.
    ///   - chatGUID: The full chat GUID (e.g., `"iMessage;+;chat123456"`).
    ///   - chatLookup: A human-readable chat name or identifier for the search field.
    /// - Throws: `AppMeeeIMsgError.appleScriptFailure` if the script fails.
    public static func send(
        reactionType: ReactionType,
        chatGUID: String,
        chatLookup: String
    ) throws {
        try send(
            reactionType: reactionType,
            chatGUID: chatGUID,
            chatLookup: chatLookup,
            runner: runAppleScript
        )
    }

    /// Testable overload accepting an injectable AppleScript runner.
    public static func send(
        reactionType: ReactionType,
        chatGUID: String,
        chatLookup: String,
        runner: (String, [String]) throws -> Void
    ) throws {
        let keyNumber: Int
        switch reactionType {
        case .love: keyNumber = 1
        case .like: keyNumber = 2
        case .dislike: keyNumber = 3
        case .laugh: keyNumber = 4
        case .emphasis: keyNumber = 5
        case .question: keyNumber = 6
        case .custom:
            let script = """
                on run argv
                  set chatGUID to item 1 of argv
                  set chatLookup to item 2 of argv
                  set customEmoji to item 3 of argv

                  tell application "Messages"
                    activate
                    set targetChat to chat id chatGUID
                  end tell

                  delay 0.3

                  tell application "System Events"
                    tell process "Messages"
                      keystroke "f" using command down
                      delay 0.15
                      keystroke "a" using command down
                      keystroke chatLookup
                      delay 0.25
                      key code 36
                      delay 0.35
                      keystroke "t" using command down
                      delay 0.2
                      keystroke customEmoji
                      delay 0.1
                      key code 36
                    end tell
                  end tell
                end run
                """
            try runner(script, [chatGUID, chatLookup, reactionType.emoji])
            return
        }

        let script = """
            on run argv
              set chatGUID to item 1 of argv
              set chatLookup to item 2 of argv
              set reactionKey to item 3 of argv

              tell application "Messages"
                activate
                set targetChat to chat id chatGUID
              end tell

              delay 0.3

              tell application "System Events"
                tell process "Messages"
                  keystroke "f" using command down
                  delay 0.15
                  keystroke "a" using command down
                  keystroke chatLookup
                  delay 0.25
                  key code 36
                  delay 0.35
                  keystroke "t" using command down
                  delay 0.2
                  keystroke reactionKey
                end tell
              end tell
            end run
            """
        try runner(script, [chatGUID, chatLookup, "\(keyNumber)"])
    }

    /// Determines the preferred chat lookup string for the Messages.app search field.
    public static func preferredChatLookup(chatInfo: ChatInfo) -> String {
        let name = chatInfo.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let identifier = chatInfo.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !identifier.isEmpty { return identifier }
        return chatInfo.guid
    }

    /// Whether a string contains exactly one emoji character.
    public static func isSingleEmoji(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1 else { return false }
        guard let scalar = trimmed.unicodeScalars.first else { return false }
        return scalar.properties.isEmoji || scalar.properties.isEmojiPresentation
    }

    // MARK: - Private

    private static func runAppleScript(_ source: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "AppleScript", "-"] + arguments

        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardError = stderrPipe

        try process.run()
        if let data = source.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        stdinPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "Unknown AppleScript error"
            throw AppMeeeIMsgError.appleScriptFailure(
                message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
