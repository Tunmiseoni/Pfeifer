import Foundation
@testable import PfeiferCore
import Testing

@Suite
struct SubsequenceGuardTests {
    @Test
    func exactCopyIsASubsequence() {
        #expect(SubsequenceGuard.isSubsequence("hello world", of: "hello world"))
    }

    @Test
    func caseAndPunctuationDifferencesAreAllowed() {
        #expect(
            SubsequenceGuard.isSubsequence(
                "Hello, world!", of: "hello world"))
    }

    @Test
    func deletionsAreAllowed() {
        // The model may drop fillers and repeated words.
        #expect(
            SubsequenceGuard.isSubsequence(
                "I drove to the shop", of: "I I um drove to to the shop"))
    }

    @Test
    func insertionsAreRejected() {
        // A fabricated document is not a subsequence — this is the observed
        // failure the guard exists to kill.
        let fabricated = "# Mini Agent.md\n\nAdded an agent named Agent X."
        let spoken = "make these changes to agents.md"
        #expect(!SubsequenceGuard.isSubsequence(fabricated, of: spoken))
    }

    @Test
    func paraphraseIsRejected() {
        #expect(
            !SubsequenceGuard.isSubsequence(
                "I will review it tomorrow", of: "I'll send you the document tomorrow"))
    }

    @Test
    func reorderingIsRejected() {
        #expect(!SubsequenceGuard.isSubsequence("world hello", of: "hello world"))
    }

    @Test
    func emptyOutputIsNeverValid() {
        #expect(!SubsequenceGuard.isSubsequence("", of: "hello world"))
        #expect(!SubsequenceGuard.isSubsequence("   ", of: "hello world"))
    }

    @Test
    func emptyInputOnlyAcceptsEmptyOutput() {
        #expect(!SubsequenceGuard.isSubsequence("anything", of: ""))
    }

    @Test
    func internalPunctuationIsNormalizedSymmetrically() {
        #expect(
            SubsequenceGuard.isSubsequence(
                "agents.md was updated", of: "agents.md was updated"))
    }
}
