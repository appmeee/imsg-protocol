import Testing
@testable import AppMeeeIMsgCore

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
