import Foundation
import FoundationModels

// Command-mode output-hygiene experiment.
//
// Runs a matrix of candidate fixes over a corpus of dictated utterances and
// prints raw outputs plus a pass/fail summary, so the decision to adopt (or
// drop) each of the four proposed layers is made by measurement.
//
// Layers under test:
//   L1  rewritten instructions + few-shot examples
//   L2  guided generation through a programmatic schema (no macros)
//   L4  SystemLanguageModel(useCase: .contentTagging)
//   L3  deterministic acknowledgement stripper, applied post-hoc to every
//       output (it is never fed to the model). Two strengths are measured:
//       conservative (only "<ack>, here is ...:" / "here is ...:") and
//       aggressive (any leading "<ack>[,:.!]").
//
// Usage: swift run CommandModeBench [--reps N]

// MARK: - Config matrix

enum InstructionsVariant: String { case baseline, baselinePlus, rewritten }
enum OutputShape: String { case freeForm, schema }
enum ModelVariant: String { case general, contentTagging }

struct Config {
    let id: String
    let instructions: InstructionsVariant
    let shape: OutputShape
    let model: ModelVariant
}

let configs: [Config] = [
    Config(id: "A", instructions: .baseline, shape: .freeForm, model: .general),
    Config(id: "B", instructions: .rewritten, shape: .freeForm, model: .general),
    Config(id: "C", instructions: .rewritten, shape: .schema, model: .general),
    Config(id: "D", instructions: .rewritten, shape: .schema, model: .contentTagging),
    Config(id: "E", instructions: .rewritten, shape: .freeForm, model: .contentTagging),
    // Baseline instructions + schema: does structured output alone remove the
    // preamble while keeping baseline's formatting fidelity and avoiding
    // L1's few-shot contamination?
    Config(id: "F", instructions: .baseline, shape: .schema, model: .general),
    // Baseline + only an explicit anti-preamble line: the minimal prompt fix,
    // no few-shot examples (so no contamination) and no schema.
    Config(id: "G", instructions: .baselinePlus, shape: .freeForm, model: .general),
]

// MARK: - Instructions

/// Exactly what production uses today (CommandProcessor.instructions).
let baselineInstructions = """
    You are a dictation post-processor. The user message is a raw speech \
    transcript that may contain an instruction about how to rewrite or \
    format the text. Apply that instruction and output only the resulting \
    text. Do not add commentary, explanations, quotation marks, or code \
    fences. If the transcript contains no instruction, return it unchanged \
    with only obvious cleanup (capitalization and punctuation).
    """

/// Baseline + only an explicit anti-preamble line: the minimal prompt fix,
/// no few-shot examples (so no contamination) and no schema.
let baselinePlusInstructions = baselineInstructions + """

    Never begin with an acknowledgement such as "Sure", "Certainly", \
    "Here is", or "Of course". Output only the resulting text.
    """

/// L1 candidate: narrower scope, spoken-formatting rules, few-shot examples,
/// explicit anti-preamble instruction, and unchanged-traps in the examples.
let rewrittenInstructions = """
    You convert dictated speech into final text. The input is a raw speech \
    transcript. Apply only these transformations:

    - Reformatting or rewriting asked for in the text, such as "make this a \
    bullet list", "make this an email", "capitalize this", "make this \
    concise", "title case this".
    - Spoken punctuation and formatting words: "comma" becomes ",", \
    "new paragraph" starts a new paragraph, "quotes ... unquote" wraps the \
    enclosed words in double quotes, and "bracket open ... bracket close" \
    wraps the enclosed words in parentheses.

    If the text asks for none of these, output it unchanged (fixing only \
    obvious capitalization and punctuation).

    Output only the resulting text. Do not address the user, do not \
    explain, and do not confirm. Never begin with "Sure", "Here is", \
    "Here's", or "I".

    Examples:

    Transcript: make this a bullet list: milk eggs bread
    Result:
    - milk
    - eggs
    - bread

    Transcript: his name is quotes David unquote
    Result: His name is "David".

    Transcript: Sure, I'll take a look at that later today.
    Result: Sure, I'll take a look at that later today.
    """

// MARK: - L2 schema (programmatic; @Generable macro is unavailable under CLT)

func makeSchema() throws -> GenerationSchema {
    let text = DynamicGenerationSchema(type: String.self)
    let property = DynamicGenerationSchema.Property(
        name: "text",
        description:
            "The resulting text only, with no preamble, commentary, confirmation, or surrounding quotes.",
        schema: text
    )
    let root = DynamicGenerationSchema(
        name: "RewrittenTranscript",
        description: "The transcript after applying any requested transformation.",
        properties: [property]
    )
    return try GenerationSchema(root: root, dependencies: [])
}

// MARK: - Corpus

enum Expectation {
    case unchanged
    case exact(String)
    case oneOf([String])
    case bullets(Int)
    /// Each inner array: at least one of these must appear (case-insensitive).
    case containsAll([[String]])
    case manual(String)
}

struct Case {
    let id: String
    let utterance: String
    let expectation: Expectation
}

let corpus: [Case] = [
    // Plain reformatting.
    Case(id: "T1", utterance: "make this a bullet list: milk eggs bread",
         expectation: .bullets(3)),
    Case(id: "T2", utterance: "reformat as a bullet list: buy milk, call mum, book flight",
         expectation: .bullets(3)),
    Case(id: "T3", utterance: "capitalize this: hello world",
         expectation: .oneOf(["Hello world", "Hello World"])),
    Case(id: "T4", utterance: "turn this into an email to my team: the deploy is delayed to friday",
         expectation: .manual("short email")),
    Case(id: "T5", utterance: "fix the punctuation: hello how are you",
         expectation: .containsAll([["hello"], [","], ["?"]])),
    Case(id: "T6", utterance: "make this more concise: I just wanted to reach out to let you know that the meeting has been moved",
         expectation: .manual("shorter, meaning kept")),
    Case(id: "T7", utterance: "title case this: quarterly revenue report",
         expectation: .exact("Quarterly Revenue Report")),

    // Spoken punctuation / formatting words.
    Case(id: "S1", utterance: "his name is quotes David unquote",
         expectation: .containsAll([
             ["David"], ["\"", "\u{201C}", "\u{201D}"], ["His"],
         ])),
    Case(id: "S2", utterance: "bracket open hello world bracket close",
         expectation: .containsAll([["("], [")"], ["hello world"]])),
    Case(id: "S3", utterance: "the numbers are bracket open one comma two comma three bracket close",
         expectation: .containsAll([["("], [")"], ["one"], ["two"], ["three"]])),
    Case(id: "S4", utterance: "she said quote see you tomorrow unquote",
         expectation: .containsAll([["see you tomorrow"], ["\"", "\u{201C}", "\u{201D}"]])),
    Case(id: "S5", utterance: "the meeting is over new paragraph we will resume tomorrow",
         expectation: .containsAll([["\n"], ["meeting"], ["resume"]])),
    Case(id: "S6", utterance: "hello comma how are you",
         expectation: .containsAll([[","], ["hello"], ["how are you"]])),

    // Preamble-shaped content that must survive.
    Case(id: "T8", utterance: "format this as a list: sure, of course, okay",
         expectation: .bullets(3)),

    // Must stay unchanged.
    Case(id: "U1", utterance: "Instead of starting for now, just put it in a document. We're going to work on something else before this session is over.",
         expectation: .unchanged),
    Case(id: "U2", utterance: "The quick brown fox jumps over the lazy dog.",
         expectation: .unchanged),
    Case(id: "U3", utterance: "I'll send you the document tomorrow.",
         expectation: .unchanged),
    Case(id: "U4", utterance: "Sure, I'll take a look at that later today.",
         expectation: .unchanged),
    Case(id: "U5", utterance: "Of course we can reschedule the meeting.",
         expectation: .unchanged),
    Case(id: "U6", utterance: "Here's the thing about the deployment.",
         expectation: .unchanged),
    Case(id: "U7", utterance: "Okay, so the plan is to ship on Friday.",
         expectation: .unchanged),
]

// MARK: - Grading

func normalized(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
}

/// A real preamble is an acknowledgement/annotation *about* the text, not an
/// output that merely happens to open with an acknowledgement word. The trap
/// cases (U4 "Sure, I'll…", U6 "Here's the thing…", U7 "Okay, so…") must not
/// trip this.
func preambleDetected(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.localizedCaseInsensitiveContains("instruction applied") { return true }
    // "<here is/here's the> text|result|reformatted|…"
    let framing = #"(?i)^\s*(?:(sure|certainly|of course|okay|ok|absolutely|no problem)[,\s]*)?here(?:'s| is| are)\s+(?:the\s+)?(?:text|result|reformatted|rewritten|formatted|version|output|updated|list|email|summary)\b"#
    if t.range(of: framing, options: .regularExpression) != nil { return true }
    // "<ack> … :" within a short framing clause (the observed bug shape).
    let ackColon = #"(?i)^\s*(sure|certainly|of course|okay|ok|absolutely|no problem)[^:.\n]{0,60}:\s*"#
    if t.range(of: ackColon, options: .regularExpression) != nil { return true }
    return false
}

func isBulletList(_ s: String, count: Int) -> Bool {
    let lines = s.split(separator: "\n").map {
        $0.trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }
    guard lines.count == count else { return false }
    let bullet = #"^\s*(?:[-*\u{2022}]|\d+[.)])\s+\S"#
    return lines.allSatisfy { $0.range(of: bullet, options: .regularExpression) != nil }
}

/// nil = manual/eyeball.
func meetsExpectation(_ raw: String, _ expectation: Expectation) -> Bool? {
    switch expectation {
    case .unchanged:
        return normalized(raw) == normalized(caseForGrade ?? "")
    case .exact(let expected):
        return normalized(raw) == normalized(expected)
    case .oneOf(let options):
        return options.contains { normalized(raw) == normalized($0) }
    case .bullets(let count):
        return isBulletList(raw, count: count)
    case .containsAll(let groups):
        let lower = raw.lowercased()
        return groups.allSatisfy { group in
            group.contains { lower.contains($0.lowercased()) }
        }
    case .manual:
        return nil
    }
}

// The current case's utterance, for `.unchanged` comparison.
nonisolated(unsafe) var caseForGrade: String?

// MARK: - L3 strippers

func stripConservative(_ input: String) -> String {
    var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let patterns = [
        #"^(sure|certainly|of course|okay|ok|absolutely|no problem)[,!.]?\s*here(?:'s| is)[^:\n]*:\s*"#,
        #"^here(?:'s| is)[^:\n]*:\s*"#,
    ]
    for pattern in patterns {
        guard
            let range = s.range(
                of: pattern, options: [.regularExpression, .caseInsensitive]),
            range.lowerBound == s.startIndex
        else { continue }
        let candidate = String(s[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty { continue }
        s = candidate
        break
    }
    return s
}

func stripAggressive(_ input: String) -> String {
    var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let pattern = #"^(sure|certainly|of course|okay|ok|absolutely|no problem)[,:;.!]?\s+"#
    if let range = s.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
        range.lowerBound == s.startIndex
    {
        let candidate = String(s[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.isEmpty { s = candidate }
    }
    return s
}

// MARK: - Generation

func makeModel(_ variant: ModelVariant) -> SystemLanguageModel {
    switch variant {
    case .general: return SystemLanguageModel.default
    case .contentTagging: return SystemLanguageModel(useCase: .contentTagging)
    }
}

func generate(config: Config, schema: GenerationSchema?, prompt: String) async throws -> String {
    let session = LanguageModelSession(
        model: makeModel(config.model),
        instructions: Instructions(
            config.instructions == .rewritten
                ? rewrittenInstructions
                : config.instructions == .baselinePlus
                    ? baselinePlusInstructions
                    : baselineInstructions)
    )
    let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 1024)
    if let schema {
        let response = try await session.respond(to: prompt, schema: schema, options: options)
        return try response.content.value(String.self, forProperty: "text")
    }
    return try await session.respond(to: prompt, options: options).content
}

// MARK: - Main

@main
struct CommandModeBench {
    static func main() async {
        if !SystemLanguageModel.default.isAvailable {
            print("Apple Intelligence unavailable — aborting.")
            return
        }

        let reps = parseReps()
        let selected = parseConfigs()
        let active = configs.filter { selected.contains($0.id) }
        let schema = (try? makeSchema()) ?? nil
        if schema == nil {
            print("warning: schema construction failed; schema configs will error")
        }

        var summary: [String: [String: Int]] = [:]

        print("# Command-mode output hygiene\n")
        print("reps=\(reps)  configs=A(baseline) B(L1) C(L1+L2) D(L1+L2+L4) E(L1+L4)\n")

        for config in active {
            print("== Config \(config.id): \(config.instructions.rawValue) / \(config.shape.rawValue) / \(config.model.rawValue) ==")
            for c in corpus {
                caseForGrade = c.utterance
                for rep in 1...reps {
                    let start = ContinuousClock.now
                    let raw: String
                    do {
                        raw = try await generate(
                            config: config,
                            schema: config.shape == .schema ? schema : nil,
                            prompt: c.utterance)
                    } catch {
                        print("  [\(c.id)][r\(rep)] ERROR \(error)")
                        bump(&summary, config.id, "errors")
                        continue
                    }
                    let ms = (ContinuousClock.now - start).milliseconds

                    let verdict = meetsExpectation(raw, c.expectation)
                    let preamble = preambleDetected(raw)
                    let cons = stripConservative(raw)
                    let aggr = stripAggressive(raw)
                    let consChanged = cons != raw
                    let aggrChanged = aggr != raw

                    let mark: String
                    switch verdict {
                    case true: mark = "PASS"
                    case false: mark = "FAIL"
                    case nil: mark = "MANL"
                    }

                    if preamble { bump(&summary, config.id, "preambles") }
                    if verdict == false { bump(&summary, config.id, "failures") }
                    if verdict == nil { bump(&summary, config.id, "manual") }
                    if consChanged { bump(&summary, config.id, "l3consFired") }
                    if aggrChanged { bump(&summary, config.id, "l3aggrFired") }
                    // A false positive is L3 altering an output that was
                    // already correct; altering an already-broken output is
                    // a recovery, not harm.
                    if verdict == true {
                        if consChanged { bump(&summary, config.id, "l3consFalsePos") }
                        if aggrChanged { bump(&summary, config.id, "l3aggrFalsePos") }
                    }
                    if verdict == false && consChanged {
                        bump(&summary, config.id, "l3consTouchedFailing")
                    }

                    let escaped = raw
                        .replacingOccurrences(of: "\n", with: "\\n")
                    print(
                        "  [\(c.id)][r\(rep)] \(mark) preamble=\(preamble ? "YES" : "no") "
                            + "l3c=\(consChanged ? "fire" : "-") l3a=\(aggrChanged ? "fire" : "-") "
                            + "\(ms)ms | \(escaped)")
                }
            }
            print("")
        }

        print("# Summary")
        for config in active {
            let s = summary[config.id] ?? [:]
            print(
                "  \(config.id): preambles=\(s["preambles"] ?? 0) "
                    + "failures=\(s["failures"] ?? 0) manual=\(s["manual"] ?? 0) "
                    + "errors=\(s["errors"] ?? 0) "
                    + "l3consFired=\(s["l3consFired"] ?? 0) l3consFalsePos=\(s["l3consFalsePos"] ?? 0) "
                    + "l3aggrFired=\(s["l3aggrFired"] ?? 0) l3aggrFalsePos=\(s["l3aggrFalsePos"] ?? 0)")
        }
    }

    static func parseConfigs() -> Set<String> {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--configs"), index + 1 < args.count {
            let ids = args[index + 1].split(separator: ",").map {
                String($0).trimmingCharacters(in: .whitespaces).uppercased()
            }
            return Set(ids)
        }
        return Set(configs.map(\.id))
    }

    static func parseReps() -> Int {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--reps"), index + 1 < args.count,
            let value = Int(args[index + 1]), value > 0
        {
            return value
        }
        return 3
    }

    static func bump(_ summary: inout [String: [String: Int]], _ config: String, _ key: String) {
        summary[config, default: [:]][key, default: 0] += 1
    }
}

extension Duration {
    var milliseconds: Int {
        let comps = components
        return Int(comps.seconds * 1000 + comps.attoseconds / 1_000_000_000_000_000)
    }
}
