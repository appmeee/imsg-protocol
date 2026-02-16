import Carbon
import Foundation

/// Sends iMessages and SMS via AppleScript using the Messages.app scripting interface.
///
/// Supports three targeting modes:
/// 1. **Chat GUID** -- directly addresses an existing chat by its internal GUID.
/// 2. **Chat identifier** -- addresses an existing chat by its identifier string.
/// 3. **Buddy lookup** -- resolves a recipient phone/email against a service.
///
/// Attachments are staged into `~/Library/Messages/Attachments/appmeee/` before
/// being sent, matching the directory structure Messages.app expects.
///
/// Falls back to `/usr/bin/osascript` when the in-process `NSAppleScript` execution
/// fails with error -1743 (Apple Events authorization denied).
public struct MessageSender: Sendable {
    private let normalizer: PhoneNumberNormalizer
    private let runner: @Sendable (String, [String]) throws -> Void
    private let attachmentsSubdirectoryProvider: @Sendable () -> URL

    public init() {
        self.normalizer = PhoneNumberNormalizer()
        self.runner = MessageSender.runAppleScript
        self.attachmentsSubdirectoryProvider = MessageSender.defaultAttachmentsSubdirectory
    }

    init(runner: @escaping @Sendable (String, [String]) throws -> Void) {
        self.normalizer = PhoneNumberNormalizer()
        self.runner = runner
        self.attachmentsSubdirectoryProvider = MessageSender.defaultAttachmentsSubdirectory
    }

    init(
        runner: @escaping @Sendable (String, [String]) throws -> Void,
        attachmentsSubdirectoryProvider: @escaping @Sendable () -> URL
    ) {
        self.normalizer = PhoneNumberNormalizer()
        self.runner = runner
        self.attachmentsSubdirectoryProvider = attachmentsSubdirectoryProvider
    }

    /// Sends a message with the given options.
    ///
    /// - Parameter options: Configuration for the message including recipient, text,
    ///   attachment, and targeting mode.
    /// - Throws: `AppMeeeIMsgError.appleScriptFailure` if the send fails.
    public func send(_ options: MessageSendOptions) throws {
        let chatTarget = resolveChatTarget(options)
        let useChat = !chatTarget.isEmpty

        var recipient = options.recipient
        var service = options.service
        let region = options.region ?? "US"

        if !useChat {
            recipient = normalizer.normalize(recipient, region: region)
            if service == .auto { service = .imessage }
        }

        var stagedAttachmentPath = ""
        if let attachmentPath = options.attachmentPath, !attachmentPath.isEmpty {
            stagedAttachmentPath = try stageAttachment(at: attachmentPath)
        }

        let text = options.text ?? ""
        try sendViaAppleScript(
            recipient: recipient,
            text: text,
            service: service,
            attachmentPath: stagedAttachmentPath,
            chatTarget: chatTarget,
            useChat: useChat
        )
    }

    // MARK: - Chat Target Resolution

    private func resolveChatTarget(_ options: MessageSendOptions) -> String {
        let guid = (options.chatGUID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = (options.chatIdentifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if !identifier.isEmpty && looksLikeHandle(identifier) {
            return ""
        }

        if !guid.isEmpty {
            return guid
        }

        if identifier.isEmpty {
            return ""
        }

        return identifier
    }

    private func looksLikeHandle(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("imessage:") || lower.hasPrefix("sms:") || lower.hasPrefix("auto:") {
            return true
        }
        if trimmed.contains("@") { return true }

        let allowed = CharacterSet(charactersIn: "+0123456789 ()-")
        return trimmed.rangeOfCharacter(from: allowed.inverted) == nil
    }

    // MARK: - Attachment Staging

    private func stageAttachment(at path: String) throws -> String {
        let expandedPath = (path as NSString).expandingTildeInPath
        let sourceURL = URL(fileURLWithPath: expandedPath)
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw AppMeeeIMsgError.appleScriptFailure("Attachment not found at \(sourceURL.path)")
        }

        let subdirectory = attachmentsSubdirectoryProvider()
        try fileManager.createDirectory(at: subdirectory, withIntermediateDirectories: true)

        let attachmentDir = subdirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(at: attachmentDir, withIntermediateDirectories: true)

        let destination = attachmentDir.appendingPathComponent(
            sourceURL.lastPathComponent,
            isDirectory: false
        )
        try fileManager.copyItem(at: sourceURL, to: destination)

        return destination.path
    }

    private static func defaultAttachmentsSubdirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let messagesRoot = home.appendingPathComponent(
            "Library/Messages/Attachments",
            isDirectory: true
        )
        return messagesRoot.appendingPathComponent("appmeee", isDirectory: true)
    }

    // MARK: - AppleScript Execution

    private func sendViaAppleScript(
        recipient: String,
        text: String,
        service: MessageService,
        attachmentPath: String,
        chatTarget: String,
        useChat: Bool
    ) throws {
        let script = buildAppleScript()
        let arguments = [
            recipient,
            text,
            service.rawValue,
            attachmentPath,
            attachmentPath.isEmpty ? "0" : "1",
            chatTarget,
            useChat ? "1" : "0",
        ]
        try runner(script, arguments)
    }

    private func buildAppleScript() -> String {
        """
        on run argv
            set theRecipient to item 1 of argv
            set theMessage to item 2 of argv
            set theService to item 3 of argv
            set theFilePath to item 4 of argv
            set useAttachment to item 5 of argv
            set chatId to item 6 of argv
            set useChat to item 7 of argv

            tell application "Messages"
                if useChat is "1" then
                    set targetChat to chat id chatId
                    if theMessage is not "" then
                        send theMessage to targetChat
                    end if
                    if useAttachment is "1" then
                        set theFile to POSIX file theFilePath as alias
                        send theFile to targetChat
                    end if
                else
                    if theService is "SMS" then
                        set targetService to first service whose service type is SMS
                    else
                        set targetService to first service whose service type is iMessage
                    end if

                    set targetBuddy to buddy theRecipient of targetService
                    if theMessage is not "" then
                        send theMessage to targetBuddy
                    end if
                    if useAttachment is "1" then
                        set theFile to POSIX file theFilePath as alias
                        send theFile to targetBuddy
                    end if
                end if
            end tell
        end run
        """
    }

    // MARK: - Script Runners

    private static func runAppleScript(source: String, arguments: [String]) throws {
        guard let script = NSAppleScript(source: source) else {
            throw AppMeeeIMsgError.appleScriptFailure("Unable to compile AppleScript")
        }

        var errorInfo: NSDictionary?
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(
            NSAppleEventDescriptor(string: "run"),
            forKeyword: AEKeyword(keyASSubroutineName)
        )

        let list = NSAppleEventDescriptor.list()
        for (index, value) in arguments.enumerated() {
            list.insert(NSAppleEventDescriptor(string: value), at: index + 1)
        }
        event.setParam(list, forKeyword: keyDirectObject)

        script.executeAppleEvent(event, error: &errorInfo)

        if let errorInfo {
            if shouldFallbackToOsascript(errorInfo: errorInfo) {
                try runOsascript(source: source, arguments: arguments)
                return
            }
            let message =
                (errorInfo[NSAppleScript.errorMessage] as? String) ?? "Unknown AppleScript error"
            throw AppMeeeIMsgError.appleScriptFailure(message)
        }
    }

    private static func shouldFallbackToOsascript(errorInfo: NSDictionary) -> Bool {
        if let errorNumber = errorInfo[NSAppleScript.errorNumber] as? Int, errorNumber == -1743 {
            return true
        }
        if errorInfo[NSAppleScript.errorMessage] == nil {
            return true
        }
        if let message = errorInfo[NSAppleScript.errorMessage] as? String {
            let lower = message.lowercased()
            return lower.contains("not authorized") || lower.contains("not authorised")
        }
        return false
    }

    private static func runOsascript(source: String, arguments: [String]) throws {
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

        guard process.terminationStatus == 0 else {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "Unknown osascript error"
            throw AppMeeeIMsgError.appleScriptFailure(
                message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}

