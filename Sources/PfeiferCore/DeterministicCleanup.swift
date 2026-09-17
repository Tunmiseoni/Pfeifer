import Foundation

/// Deterministic-first cleanup: the part of cleanup that needs no model.
///
/// `docs/design-command-mode.md` §5 fixes the order — `SpeechTokens` runs
/// first (in the coordinator), then this removes fillers and immediate
/// word/phrase repetitions, and only then does the model see the text for the
/// genuinely hard part (self-corrections and abandoned false starts).
/// Minimizing what the model is invited to rewrite is the only lever that
/// actually reduces conflation.
public enum DeterministicCleanup {
    private static let fillers: Set<String> = ["um", "uh", "er", "erm", "hmm"]

    /// Remove filler words and immediately repeated words/phrases, preserving
    /// all other wording, punctuation, and order. Pure.
    ///
    /// Rebuilding joins tokens with single spaces; ASR transcripts are already
    /// single-spaced, so punctuation attached to a token survives.
    public static func cleanup(_ text: String) -> String {
        var words: [String] = []
        for token in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            if fillers.contains(normalize(token)) { continue }
            words.append(token)
            collapseTrailingRepetition(&words)
        }
        return words.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// If the tail of `words` is an immediately repeated phrase (1...n tokens
    /// long), drop the duplicate tail. Builds repetition collapse into the
    /// append loop so "I want to I want to go" becomes "I want to go".
    private static func collapseTrailingRepetition(_ words: inout [String]) {
        guard words.count >= 2 else { return }
        for length in stride(from: words.count / 2, through: 1, by: -1) {
            let start = words.count - (2 * length)
            let first = words[start..<(start + length)].map(normalize)
            let second = words[(start + length)...].map(normalize)
            if first == second {
                words.removeLast(length)
                return
            }
        }
    }

    private static func normalize(_ word: String) -> String {
        word.lowercased().trimmingCharacters(
            in: CharacterSet.punctuationCharacters.union(.symbols))
    }
}
