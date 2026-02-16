import Foundation
import Testing

@testable import AppMeeeIMsgCore

// MARK: - ReactionType Tests

@Test func reactionTypeParsing() {
    let love = ReactionType(rawValue: 2000)
    #expect(love == .love)
    #expect(love?.emoji == "\u{2764}\u{FE0F}")

    let removal = ReactionType.fromRemoval(3001)
    #expect(removal == .like)

    let factory = ReactionType.from(associatedMessageType: 2003)
    #expect(factory == .laugh)

    #expect(ReactionType.isReactionAdd(2000) == true)
    #expect(ReactionType.isReactionRemove(3000) == true)
    #expect(ReactionType.isReaction(1999) == false)
}

// MARK: - AttachmentResolver Tests

@Test func attachmentResolverResolvesPaths() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("test.txt")
    try "hi".data(using: .utf8)!.write(to: file)

    let existing = AttachmentResolver.resolve(file.path)
    #expect(existing.missing == false)
    #expect(existing.resolved.hasSuffix("test.txt"))

    let missing = AttachmentResolver.resolve(dir.appendingPathComponent("missing.txt").path)
    #expect(missing.missing == true)

    let directory = AttachmentResolver.resolve(dir.path)
    #expect(directory.missing == true)
}

@Test func attachmentResolverDisplayNamePrefersTransfer() {
    #expect(
        AttachmentResolver.displayName(filename: "file.dat", transferName: "nice.dat") == "nice.dat"
    )
    #expect(AttachmentResolver.displayName(filename: "file.dat", transferName: "") == "file.dat")
    #expect(AttachmentResolver.displayName(filename: "", transferName: "") == "(unknown)")
}

// MARK: - MessageFilter Tests

@Test func messageFilterHonorsParticipantsAndDates() throws {
    let now = Date(timeIntervalSince1970: 1000)
    let message = Message(
        rowID: 1,
        chatID: 1,
        sender: "Alice",
        text: "hi",
        date: now,
        isFromMe: false,
        service: "iMessage",
        handleID: nil,
        attachmentsCount: 0
    )
    let filter = MessageFilter(
        participants: ["alice"],
        startDate: now.addingTimeInterval(-10),
        endDate: now.addingTimeInterval(10)
    )
    #expect(filter.allows(message) == true)
    let pastFilter = MessageFilter(startDate: now.addingTimeInterval(5))
    #expect(pastFilter.allows(message) == false)
}

@Test func messageFilterRejectsInvalidISO() {
    do {
        _ = try MessageFilter.fromISO(participants: [], startISO: "bad-date", endISO: nil)
        #expect(Bool(false))
    } catch let error as AppMeeeIMsgError {
        switch error {
        case .invalidISODate(let value):
            #expect(value == "bad-date")
        default:
            #expect(Bool(false))
        }
    } catch {
        #expect(Bool(false))
    }
}

// MARK: - TypedStreamParser Tests

@Test func typedStreamParserPrefersLongestSegment() {
    let short = [UInt8(0x01), UInt8(0x2b)] + Array("short".utf8) + [0x86, 0x84]
    let long = [UInt8(0x01), UInt8(0x2b)] + Array("longer text".utf8) + [0x86, 0x84]
    let data = Data(short + long)
    #expect(TypedStreamParser.parseAttributedBody(data) == "longer text")
}

@Test func typedStreamParserTrimsControlCharacters() {
    let bytes: [UInt8] = [0x00, 0x0A] + Array("hello".utf8)
    let data = Data(bytes)
    #expect(TypedStreamParser.parseAttributedBody(data) == "hello")
}

// MARK: - PhoneNumberNormalizer Tests

@Test func phoneNumberNormalizerFormatsValidNumber() {
    let normalizer = PhoneNumberNormalizer()
    let normalized = normalizer.normalize("+1 650-253-0000", region: "US")
    #expect(normalized == "+16502530000")
}

@Test func phoneNumberNormalizerReturnsInputOnFailure() {
    let normalizer = PhoneNumberNormalizer()
    let normalized = normalizer.normalize("not-a-number", region: "US")
    #expect(normalized == "not-a-number")
}

// MARK: - MessageSender Tests

@Test func messageSenderBuildsArguments() throws {
    nonisolated(unsafe) var captured: [String] = []
    let sender = MessageSender(runner: { _, args in
        captured = args
    })
    try sender.send(
        MessageSendOptions(
            recipient: "+16502530000",
            text: "hi",
            attachmentPath: "",
            service: .auto,
            region: "US"
        )
    )
    #expect(captured.count == 7)
    #expect(captured[0] == "+16502530000")
    #expect(captured[2] == "iMessage")
    #expect(captured[5].isEmpty)
    #expect(captured[6] == "0")
}

@Test func messageSenderUsesChatIdentifier() throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }
    let attachment = tempDir.appendingPathComponent("file.dat")
    try Data("hello".utf8).write(to: attachment)
    let attachmentsSubdirectory = tempDir.appendingPathComponent("staged")
    try fileManager.createDirectory(at: attachmentsSubdirectory, withIntermediateDirectories: true)

    nonisolated(unsafe) var captured: [String] = []
    let sender = MessageSender(
        runner: { _, args in captured = args },
        attachmentsSubdirectoryProvider: { attachmentsSubdirectory }
    )
    try sender.send(
        MessageSendOptions(
            recipient: "",
            text: "hi",
            attachmentPath: attachment.path,
            service: .sms,
            region: "US",
            chatIdentifier: "iMessage;+;chat123",
            chatGUID: "ignored-guid"
        )
    )
    #expect(captured[5] == "ignored-guid")
    #expect(captured[6] == "1")
    #expect(captured[4] == "1")
}

@Test func messageSenderStagesAttachmentsBeforeSend() throws {
    let fileManager = FileManager.default
    let attachmentsSubdirectory = fileManager.temporaryDirectory.appendingPathComponent(
        UUID().uuidString
    )
    try fileManager.createDirectory(at: attachmentsSubdirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: attachmentsSubdirectory) }
    let sourceDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: sourceDir) }
    let sourceFile = sourceDir.appendingPathComponent("sample.txt")
    let payload = Data("hi".utf8)
    try payload.write(to: sourceFile)

    nonisolated(unsafe) var captured: [String] = []
    let sender = MessageSender(
        runner: { _, args in captured = args },
        attachmentsSubdirectoryProvider: { attachmentsSubdirectory }
    )

    try sender.send(
        MessageSendOptions(
            recipient: "+16502530000",
            text: "",
            attachmentPath: sourceFile.path,
            service: .imessage,
            region: "US"
        )
    )

    let stagedPath = captured[3]
    #expect(stagedPath != sourceFile.path)
    #expect(stagedPath.hasPrefix(attachmentsSubdirectory.path))
    #expect(fileManager.fileExists(atPath: stagedPath))
    let stagedData = try Data(contentsOf: URL(fileURLWithPath: stagedPath))
    #expect(stagedData == payload)
}

@Test func messageSenderThrowsWhenAttachmentMissing() {
    let fileManager = FileManager.default
    let attachmentsSubdirectory = fileManager.temporaryDirectory.appendingPathComponent(
        UUID().uuidString
    )
    try? fileManager.createDirectory(at: attachmentsSubdirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: attachmentsSubdirectory) }
    let missingFile = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    nonisolated(unsafe) var runnerCalled = false
    let sender = MessageSender(
        runner: { _, _ in runnerCalled = true },
        attachmentsSubdirectoryProvider: { attachmentsSubdirectory }
    )

    do {
        try sender.send(
            MessageSendOptions(
                recipient: "+16502530000",
                text: "",
                attachmentPath: missingFile,
                service: .imessage,
                region: "US"
            )
        )
        #expect(Bool(false))
    } catch let error as AppMeeeIMsgError {
        #expect(error.errorDescription?.contains("Attachment not found") == true)
    } catch {
        #expect(Bool(false))
    }

    #expect(runnerCalled == false)
}

// MARK: - Error Description Tests

@Test func errorDescriptionsIncludeDetails() {
    let serviceError = AppMeeeIMsgError.invalidService("weird")
    #expect(serviceError.errorDescription?.contains("weird") == true)

    let chatError = AppMeeeIMsgError.invalidChatTarget("bad")
    #expect(chatError.errorDescription?.contains("bad") == true)

    let dateError = AppMeeeIMsgError.invalidISODate("2024-99-99")
    #expect(dateError.errorDescription?.contains("2024-99-99") == true)

    let scriptError = AppMeeeIMsgError.appleScriptFailure("nope")
    #expect(scriptError.errorDescription?.contains("nope") == true)

    let permission = AppMeeeIMsgError.permissionDenied(path: "/tmp/chat.db", detail: "test")
    let permissionDescription = permission.errorDescription ?? ""
    #expect(permissionDescription.contains("/tmp/chat.db") == true)
}
