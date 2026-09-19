import Foundation
@testable import pfeiferCore
import Testing

@Suite
struct CommandGrammarTests {
    @Test
    func everyTriggerMapsToItsTransformAndStripsItself() {
        let cases: [(String, Transform)] = [
            ("format this as a bullet list", .bullets),
            ("turn this into bullets", .bullets),
            ("make this a bullet list", .bullets),
            ("format this as a paragraph", .paragraph),
            ("make this a paragraph", .paragraph),
            ("turn this into a paragraph", .paragraph),
            ("make this an email", .email),
            ("turn this into an email", .email),
            ("draft this as an email", .email),
            ("make this more concise", .concise),
            ("shorten this", .concise),
            ("trim this down", .concise),
            ("make this more formal", .formal),
            ("make this professional", .formal),
            ("fix the grammar", .grammar),
            ("correct the grammar", .grammar),
            ("proofread this", .grammar),
            ("fix the punctuation", .punctuation),
            ("add punctuation", .punctuation),
            ("summarize this", .summarize),
            ("summarise this", .summarize),
            ("rewrite this", .rewrite),
            ("reword this", .rewrite),
            ("fix this", .fix),
            ("correct this", .fix),
        ]

        for (trigger, transform) in cases {
            let match = CommandGrammar.match("\(trigger) the rest of it")
            #expect(match.transform == transform, "\(trigger)")
            #expect(match.remainder == "the rest of it", "\(trigger)")
            #expect(match.requiresSelection == transform.requiresSelection)
        }
    }

    @Test
    func longestTriggerWinsSoGrammarIsNotPartiallyConsumed() {
        #expect(CommandGrammar.match("fix the grammar now").transform == .grammar)
        #expect(CommandGrammar.match("correct the grammar now").transform == .grammar)
        // The shorter "fix this" / "correct this" still work on their own.
        #expect(CommandGrammar.match("fix this now").transform == .fix)
    }

    @Test
    func matchIsCaseInsensitive() {
        #expect(CommandGrammar.match("Make This A Bullet List foo").transform == .bullets)
        #expect(CommandGrammar.match("SHORTEN THIS foo").transform == .concise)
    }

    @Test
    func trailingPunctuationOnTheTriggerIsTolerated() {
        let match = CommandGrammar.match("Fix this, please.")
        #expect(match.transform == .fix)
        #expect(match.remainder == "please.")
    }

    @Test
    func triggerMustBeAtTheStart() {
        // A command-shaped phrase inside content is not a trigger — this is
        // the structural fix for the original bug.
        let utterance = "please make this a bullet list"
        let match = CommandGrammar.match(utterance)
        #expect(match.transform == nil)
        #expect(match.remainder == utterance)
    }

    @Test
    func commandShapedContentIsNotExecuted() {
        // The originally-reported failing utterance: it *mentions* making
        // changes but does not open with a transform trigger.
        let utterance =
            "make these changes to agents.md, add an agent named Agent X and update the docs"
        let match = CommandGrammar.match(utterance)
        #expect(match.transform == nil)
        #expect(match.remainder == utterance)
        #expect(match.requiresSelection == false)
    }

    @Test
    func bareTriggerLeavesAnEmptyRemainder() {
        let match = CommandGrammar.match("make this more concise")
        #expect(match.transform == .concise)
        #expect(match.remainder == "")
        // Non-selection transforms report requiresSelection=false; the
        // coordinator refuses loudly on the empty remainder instead.
        #expect(match.requiresSelection == false)
    }

    @Test
    func contentlessTransformsReportRequiresSelection() {
        for trigger in ["summarize this", "rewrite this", "fix this", "correct this"] {
            #expect(CommandGrammar.match(trigger).requiresSelection)
        }
    }

    @Test
    func whitespaceRunsAreCollapsedInTheRemainder() {
        let match = CommandGrammar.match("make   this a bullet list    the rest")
        #expect(match.transform == .bullets)
        #expect(match.remainder == "the rest")
    }

    @Test
    func noTriggerReturnsTheTrimmedUtterance() {
        let match = CommandGrammar.match("  just some words  ")
        #expect(match.transform == nil)
        #expect(match.remainder == "just some words")
    }

    @Test
    func emptyUtteranceHasNoMatch() {
        let match = CommandGrammar.match("   ")
        #expect(match.transform == nil)
        #expect(match.remainder == "")
    }

    @Test
    func cleanupIsNotSpokenAsATrigger() {
        // `.cleanup` is the default, not a spoken transform.
        let match = CommandGrammar.match("clean this up please")
        #expect(match.transform == nil)
    }
}
