import Foundation
@testable import PfeiferCore
import Testing

@Suite
struct DeterministicCleanupTests {
    private func cleanup(_ input: String) -> String {
        DeterministicCleanup.cleanup(input)
    }

    @Test
    func removesFillerWords() {
        #expect(cleanup("I um went to the uh shop") == "I went to the shop")
        #expect(cleanup("er hello erm there") == "hello there")
        #expect(cleanup("hmm let me think") == "let me think")
    }

    @Test
    func removesImmediateWordRepetitions() {
        #expect(cleanup("I I went to the the shop") == "I went to the shop")
    }

    @Test
    func removesImmediatePhraseRepetitions() {
        #expect(cleanup("I want to I want to go home") == "I want to go home")
    }

    @Test
    func repetitionsWithFillersBetweenStillCollapse() {
        #expect(cleanup("I um I went") == "I went")
    }

    @Test
    func preservesOrderFactsAndPunctuation() {
        #expect(
            cleanup("Send it to Sam, not Alex, on Friday.")
                == "Send it to Sam, not Alex, on Friday.")
    }

    @Test
    func leavesNormalTextAlone() {
        let sentence = "The quick brown fox jumps over the lazy dog."
        #expect(cleanup(sentence) == sentence)
    }

    @Test
    func textThatIsOnlyFillersBecomesEmpty() {
        #expect(cleanup("um uh er") == "")
    }

    @Test
    func caseInsensitiveFillerMatching() {
        #expect(cleanup("I UM said so") == "I said so")
    }
}
