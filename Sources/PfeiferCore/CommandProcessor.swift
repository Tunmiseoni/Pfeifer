import Foundation
import FoundationModels

/// Post-processes a raw transcript before insertion when command mode is
/// active. Plain dictation never touches an implementation of this.
public protocol CommandProcessor: Sendable {
    /// True when the on-device model is present and ready to generate.
    /// Apple Intelligence can be off or its assets still downloading, so
    /// this must be cheap and callable before every command utterance.
    var isAvailable: Bool { get async }

    /// Rewrite `transcript` per any instruction it contains.
    /// - Throws: `CommandProcessorError` when the model is unavailable or
    ///   generation fails; callers fall back to the raw transcript.
    func process(_ transcript: String) async throws -> String
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
/// A fresh `LanguageModelSession` is built per utterance so instructions
/// and prior commands never accumulate across dictations. Generation is
/// greedy and token-bounded to keep command mode deterministic and inside
/// the model's small (4096-token) context window.
public actor FoundationModelCommandProcessor: CommandProcessor {
    /// The whole job in one system instruction: apply any instruction found
    /// in the transcript, return only the resulting text. Stability matters
    /// more than elegance here — this is the contract the model sees.
    static let instructions = """
        You are a dictation post-processor. The user message is a raw speech \
        transcript that may contain an instruction about how to rewrite or \
        format the text. Apply that instruction and output only the resulting \
        text. Do not add commentary, explanations, quotation marks, or code \
        fences. If the transcript contains no instruction, return it unchanged \
        with only obvious cleanup (capitalization and punctuation).
        """

    private static let maximumResponseTokens = 1024

    public init() {}

    public var isAvailable: Bool {
        get async {
            SystemLanguageModel.default.isAvailable
        }
    }

    public func process(_ transcript: String) async throws -> String {
        guard SystemLanguageModel.default.isAvailable else {
            throw CommandProcessorError.unavailable
        }

        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: Instructions(Self.instructions))
        let options = GenerationOptions(
            samplingMode: .greedy,
            maximumResponseTokens: Self.maximumResponseTokens)

        let response: String
        do {
            response = try await session.respond(to: transcript, options: options).content
        } catch {
            throw CommandProcessorError.generationFailed(String(describing: error))
        }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CommandProcessorError.emptyResponse
        }
        return trimmed
    }
}
