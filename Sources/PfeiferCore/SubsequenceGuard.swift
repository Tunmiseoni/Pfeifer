import Foundation

/// Structural safety net for the cleanup path.
///
/// A fabricated document is not a token-subsequence of what the user said, so
/// this directly kills the observed failure where a dictated instruction was
/// executed and the words lost. Cleanup output may only delete tokens or
/// normalize case/punctuation — no insertions, no paraphrase.
///
/// See `docs/design-command-mode.md` §4.
public enum SubsequenceGuard {
    /// True when every token of `output` appears, in order, in `input`.
    ///
    /// Both sides are tokenized the same way (lowercased, punctuation and
    /// symbols removed, split on whitespace, empties dropped). An empty output
    /// is never a valid cleanup, so it returns false.
    public static func isSubsequence(_ output: String, of input: String) -> Bool {
        let candidate = tokens(output)
        guard !candidate.isEmpty else { return false }
        let source = tokens(input)

        var matched = 0
        for token in source where matched < candidate.count && candidate[matched] == token {
            matched += 1
        }
        return matched == candidate.count
    }

    /// Lowercase, strip punctuation/symbols, split on whitespace.
    static func tokens(_ text: String) -> [String] {
        let disallowed = CharacterSet.punctuationCharacters.union(.symbols)
        let kept = text.lowercased().unicodeScalars.filter { !disallowed.contains($0) }
        return String(String.UnicodeScalarView(kept))
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }
}
