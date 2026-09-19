import Foundation
import FoundationModels

/// Post-processes a raw transcript before insertion when command mode is
/// active. Plain dictation never touches an implementation of this.
public protocol CommandProcessor: Sendable {
    /// True when the on-device model is present and ready to generate.
    /// Apple Intelligence can be off or its assets still downloading, so
    /// this must be cheap and callable before every command utterance.
    var isAvailable: Bool { get async }

    /// Rewrite `content` with the instruction for `transform`.
    ///
    /// The transform is decided by `CommandGrammar`, not by the model: the
    /// content stream carries no instruction, so nothing in it can be executed.
    /// - Throws: `CommandProcessorError` when the model is unavailable or
    ///   generation fails; callers fall back to the raw transcript.
    func process(_ content: String, transform: Transform) async throws -> String
}

public enum CommandProcessorError: Error, Equatable, Sendable {
    /// Apple Intelligence is disabled or its model assets are not ready.
    case unavailable
    /// The model returned nothing usable (empty or whitespace-only).
    case emptyResponse
    /// The model threw while generating.
    case generationFailed(String)
}

/// Command mode via Apple's on-device Foundation Model
/// (`SystemLanguageModel`, macOS 26+). No network, no API key: when Apple
/// Intelligence is unavailable, `process` throws `.unavailable` and the
/// caller inserts the verbatim transcript.
///
/// A fresh `LanguageModelSession` is built per utterance so instructions and
/// prior commands never accumulate across dictations. The system instruction
/// is the narrow template for the transform the caller resolved; the user
/// message is only the content to rewrite. Generation is greedy and
/// token-bounded to keep command mode deterministic and inside the model's
/// small (4096-token) context window.
public actor FoundationModelCommandProcessor: CommandProcessor {
    private static let maximumResponseTokens = 1024

    public init() {}

    public var isAvailable: Bool {
        get async {
            SystemLanguageModel.default.isAvailable
        }
    }

    public func process(_ content: String, transform: Transform) async throws -> String {
        guard SystemLanguageModel.default.isAvailable else {
            throw CommandProcessorError.unavailable
        }

        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: Instructions(CommandTemplates.instruction(for: transform)))
        let options = GenerationOptions(
            samplingMode: .greedy,
            maximumResponseTokens: Self.maximumResponseTokens)

        let response: String
        do {
            response = try await session.respond(to: content, options: options).content
        } catch {
            throw CommandProcessorError.generationFailed(String(describing: error))
        }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = Self.stripAcknowledgementPrefix(trimmed)
        guard !cleaned.isEmpty else {
            throw CommandProcessorError.emptyResponse
        }
        return cleaned
    }

    /// Remove a leading acknowledgement/framing clause the on-device model
    /// sometimes prepends despite the instructions, e.g.
    /// "Sure, here is the text with the instruction applied: …".
    ///
    /// Deliberately conservative: it only strips shapes that are unambiguously
    /// model framing ("<ack> … here is …:" or "here is …:"), never a
    /// legitimate sentence that merely opens with "Sure," or "Of course".
    /// Measured in docs/command-mode-experiment.md — the aggressive variant
    /// that also stripped bare "<ack>," prefixes corrupted valid output.
    ///
    /// - Returns: the input with the framing removed, or the input unchanged
    ///   when no framing matches (or stripping would leave nothing).
    static func stripAcknowledgementPrefix(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"^(sure|certainly|of course|okay|ok|absolutely|no problem)[,!.]?\s*here(?:'s| is)[^:\n]*:\s*"#,
            #"^here(?:'s| is)[^:\n]*:\s*"#,
        ]
        for pattern in patterns {
            guard
                let range = text.range(
                    of: pattern, options: [.regularExpression, .caseInsensitive]),
                range.lowerBound == text.startIndex
            else { continue }
            let remainder = String(text[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remainder.isEmpty else { continue }
            text = remainder
            break
        }
        return text
    }
}
