import Foundation

/// The system instruction for each transform.
///
/// One narrow, free-form instruction per transform, chosen deterministically by
/// `CommandGrammar` and never by the model. Schema-constrained output was
/// measured and rejected (it destroys formatting fidelity); see
/// `docs/design-command-mode.md` §3 and `docs/command-mode-experiment.md`.
public enum CommandTemplates {
    public static func instruction(for transform: Transform) -> String {
        switch transform {
        case .bullets:
            return """
                You are a formatter. Rewrite the text as a bullet list. Preserve every fact, name, \
                number, and link exactly. Do not add, drop, or infer anything. Output only the list.
                """
        case .paragraph:
            return """
                You are a formatter. Rewrite the text as one flowing paragraph. Preserve every fact, \
                name, and number exactly. Do not add or drop information. Output only the paragraph.
                """
        case .email:
            return """
                Rewrite the text as a short professional email. Preserve every fact, name, and \
                commitment exactly. Invent no recipients, dates, or promises. Output only the email \
                body.
                """
        case .concise:
            return """
                Rewrite the text more concisely. Keep every distinct fact and name. Remove only \
                filler and redundancy. Output only the text.
                """
        case .formal:
            return """
                Rewrite the text in a formal, professional register. Change wording only; preserve \
                meaning, facts, and names exactly. Output only the text.
                """
        case .grammar:
            return """
                Correct grammar, spelling, and punctuation only. Do not reword, reorder, add, or \
                remove content. Output only the corrected text.
                """
        case .punctuation:
            return """
                Add or correct punctuation and capitalization only. Change no words. Output only the \
                text.
                """
        case .summarize:
            return """
                Summarize the text in at most three sentences. Preserve every distinct fact and name. \
                Add nothing that is not in the text. Output only the summary.
                """
        case .rewrite:
            return """
                Rewrite the text for clarity. Preserve every fact, name, and commitment exactly. \
                Change wording only. Output only the rewritten text.
                """
        case .fix:
            return """
                Correct errors in the text. Preserve every fact, name, and number exactly. Change \
                only what is wrong. Output only the corrected text.
                """
        case .cleanup:
            return """
                You are a dictation cleaner. Remove filler words, humming, immediate word \
                repetitions, and abandoned false starts where the speaker corrects themselves. \
                Preserve every distinct fact, name, and number; preserve all other wording and \
                order. Output only the cleaned text.
                """
        }
    }
}
