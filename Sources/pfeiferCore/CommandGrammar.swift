import Foundation

/// A bounded rewrite the user can ask for with a leading spoken trigger.
///
/// Determined in our code, never by the model: the whole point of the Phase 2
/// rework is that the instruction/content boundary is deterministic. See
/// `docs/design-command-mode.md` §2.
public enum Transform: String, CaseIterable, Sendable, Equatable {
    case bullets
    case paragraph
    case email
    case concise
    case formal
    case grammar
    case punctuation
    case summarize
    case rewrite
    case fix
    /// The productive default when command mode is active and no transform
    /// trigger is spoken.
    case cleanup

    /// Transforms with no meaningful self-contained form: their content would
    /// be the empty remainder, so they require a readable selection and refuse
    /// loudly otherwise.
    public var requiresSelection: Bool {
        switch self {
        case .summarize, .rewrite, .fix: return true
        case .bullets, .paragraph, .email, .concise, .formal, .grammar,
            .punctuation, .cleanup:
            return false
        }
    }
}

/// The result of classifying an utterance against the leading-only grammar.
public struct Match: Equatable, Sendable {
    /// The matched transform, or nil when no trigger was spoken (the caller
    /// treats that as `.cleanup`).
    public let transform: Transform?
    /// The utterance with the matched trigger stripped. When no selection is
    /// readable this is the content to transform.
    public let remainder: String
    /// True when the matched transform has no self-contained form.
    public let requiresSelection: Bool

    public init(transform: Transform?, remainder: String, requiresSelection: Bool) {
        self.transform = transform
        self.remainder = remainder
        self.requiresSelection = requiresSelection
    }
}

/// Leading-only deterministic classifier.
///
/// There is deliberately no embedded natural-language command detection: that
/// is the same semantic ambiguity as the original bug, moved into a regex.
/// Triggers only count at the start of the utterance, matched
/// case-insensitively and longest-first, and are stripped from the remainder.
public enum CommandGrammar {
    private static let triggers: [(phrase: String, transform: Transform)] = [
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

    /// Classify `utterance`. Pure. Longest trigger wins so "fix the grammar"
    /// is never partially consumed by "fix this"; the utterance must *start*
    /// with the trigger, so a command-shaped phrase inside dictated content is
    /// not a trigger.
    public static func match(_ utterance: String) -> Match {
        let words = utterance.split(whereSeparator: \.isWhitespace).map(String.init)
        let normalized = words.map(normalize)

        let ordered = triggers.sorted {
            let left = $0.phrase.split(separator: " ").count
            let right = $1.phrase.split(separator: " ").count
            if left != right { return left > right }
            return $0.phrase.count > $1.phrase.count
        }

        for (phrase, transform) in ordered {
            let trigger = phrase.split(separator: " ").map { normalize(String($0)) }
            guard trigger.count <= normalized.count else { continue }
            guard Array(normalized.prefix(trigger.count)) == trigger else { continue }
            let remainder = words.dropFirst(trigger.count).joined(separator: " ")
            return Match(
                transform: transform,
                remainder: remainder,
                requiresSelection: transform.requiresSelection)
        }

        return Match(
            transform: nil,
            remainder: utterance.trimmingCharacters(in: .whitespacesAndNewlines),
            requiresSelection: false)
    }

    /// Lowercase and strip surrounding punctuation so ASR variants like
    /// "Fix this," still match, without letting a mid-word prefix match.
    private static func normalize(_ word: String) -> String {
        let punctuation = CharacterSet.punctuationCharacters
            .union(.symbols)
        return word.lowercased().trimmingCharacters(in: punctuation)
    }
}
