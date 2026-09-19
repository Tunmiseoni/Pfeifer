import Foundation
@testable import pfeiferCore
import Testing

@Suite
struct SpeechTokensTests {
    private func substitute(_ input: String) -> String {
        SpeechTokens.substitute(input)
    }

    @Test
    func pairedQuotesBecomeStraightQuotes() {
        #expect(
            substitute("he said quote hello world unquote today")
                == #"he said "hello world" today"#)
    }

    @Test
    func pairedQuotesTrimInnerWhitespace() {
        #expect(substitute("quote  spaced out  unquote") == #""spaced out""#)
    }

    @Test
    func openAndCloseQuoteBecomeStraightQuotes() {
        #expect(substitute("open quote hello close quote") == #"" hello ""#)
    }

    @Test
    func bracketsAndParens() {
        #expect(substitute("open bracket note close bracket") == "[ note ]")
        #expect(substitute("open paren aside close paren") == "( aside )")
    }

    @Test
    func paragraphAndLineBreaks() {
        #expect(substitute("first new paragraph second") == "first \n\n second")
        #expect(substitute("first new line second") == "first \n second")
    }

    @Test
    func substitutionIsCaseInsensitive() {
        #expect(substitute("Open Quote hi Close Quote") == #"" hi ""#)
        #expect(substitute("New Paragraph") == "\n\n")
        #expect(substitute("QUOTE hello UNQUOTE") == #""hello""#)
    }

    @Test
    func longestPhraseWinsWithinAMixedUtterance() {
        #expect(
            substitute("open bracket quote inner words unquote close bracket")
                == #"[ "inner words" ]"#)
    }

    @Test
    func multipleOccurrencesAllSubstitute() {
        #expect(
            substitute("new line a new line b") == "\n a \n b")
    }

    @Test
    func bareCommaPeriodColonAreNeverTokens() {
        // Explicitly excluded: these collide with legitimate speech.
        for sentence in [
            "put a comma after that",
            "the period at the end",
            "add a colon here",
        ] {
            #expect(substitute(sentence) == sentence)
        }
    }

    @Test
    func wordBoundariesAreRespected() {
        // "newline"/"quoted" must not be consumed by token prefixes.
        for sentence in ["newline", "these newlines", "quoted text", "unquoted"] {
            #expect(substitute(sentence) == sentence)
        }
    }

    @Test
    func bareQuoteWithoutUnquoteIsLeftAlone() {
        #expect(substitute("a quote is not a token") == "a quote is not a token")
    }

    @Test
    func textWithoutTokensIsUnchanged() {
        let sentence = "The quick brown fox jumps over the lazy dog."
        #expect(substitute(sentence) == sentence)
    }
}

@Suite
struct PreferencesTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "pfeifer-tests-\(UUID().uuidString)")!
    }

    @Test
    func spokenPunctuationDefaultsOnWhenKeyAbsent() {
        let defaults = makeDefaults()
        #expect(Preferences.spokenPunctuationEnabled(in: defaults) == true)
    }

    @Test
    func spokenPunctuationHonorsStoredValue() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: Preferences.spokenPunctuationKey)
        #expect(Preferences.spokenPunctuationEnabled(in: defaults) == false)
        defaults.set(true, forKey: Preferences.spokenPunctuationKey)
        #expect(Preferences.spokenPunctuationEnabled(in: defaults) == true)
    }
}
