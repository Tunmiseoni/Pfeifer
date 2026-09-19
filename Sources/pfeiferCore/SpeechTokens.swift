import Foundation

/// Deterministic spoken-punctuation substitution.
///
/// Runs on every transcript *before* any model call, so the model never sees
/// the literal token words and the cleanup guard compares post-substitution
/// text on both sides. The Phase 0 command-mode experiment showed the model
/// cannot do spoken punctuation in any config; this belongs in our code.
///
/// Collision-safe only: bare "comma", "period", and "colon" are deliberately
/// excluded because they collide with legitimate speech ("put a comma after
/// that") and would reintroduce content/instruction ambiguity.
///
/// See `docs/design-command-mode.md` §1.
public enum SpeechTokens {
    /// Literal phrase substitutions, longest-first so a phrase is never
    /// partially consumed by a shorter one. Word-boundary anchored and
    /// case-insensitive; replacements are literal (never regex templates),
    /// so punctuation needs no escaping.
    private static let literalSubstitutions: [(phrase: String, replacement: String)] = [
        ("new paragraph", "\n\n"),
        ("close bracket", "]"),
        ("close quote", "\""),
        ("close paren", ")"),
        ("open bracket", "["),
        ("open quote", "\""),
        ("open paren", "("),
        ("new line", "\n"),
    ].sorted { $0.phrase.count > $1.phrase.count }

    /// Substitution is idempotent for our token set (no emitted replacement
    /// re-introduces a spoken token), so callers may apply it unconditionally.
    public static func substitute(_ text: String) -> String {
        var result = text
        for (phrase, replacement) in literalSubstitutions {
            result = replaceLiteral(phrase, with: replacement, in: result)
        }
        return replaceQuotedSpans(in: result)
    }

    /// Replace one whole-word (or whole-phrase) token, case-insensitively.
    /// `replacingOccurrences` with `.regularExpression` matches the pattern
    /// but treats `replacement` literally, which is what we want.
    private static func replaceLiteral(
        _ phrase: String,
        with replacement: String,
        in text: String
    ) -> String {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b"
        return text.replacingOccurrences(
            of: pattern,
            with: replacement,
            options: [.regularExpression, .caseInsensitive]
        )
    }

    /// `quote … unquote` → `"…"`. Run after the literal phrases so the
    /// `open quote` / `close quote` forms are already consumed. Matching is
    /// thread-safe (Foundation documents concurrent `NSRegularExpression`
    /// matching).
    private static let quotedSpanPattern = try! NSRegularExpression(
        pattern: #"\bquote\b\s*([\s\S]*?)\s*\bunquote\b"#,
        options: [.caseInsensitive]
    )

    private static func replaceQuotedSpans(in text: String) -> String {
        let fullRange = NSRange(text.startIndex..., in: text)
        var result = text
        // Apply right-to-left so each replacement cannot shift the ranges of
        // the matches still to come.
        for match in quotedSpanPattern.matches(in: text, range: fullRange).reversed() {
            guard
                let full = Range(match.range, in: result),
                let innerRange = Range(match.range(at: 1), in: result)
            else { continue }
            let inner = result[innerRange].trimmingCharacters(in: .whitespacesAndNewlines)
            result.replaceSubrange(full, with: "\"\(inner)\"")
        }
        return result
    }
}
