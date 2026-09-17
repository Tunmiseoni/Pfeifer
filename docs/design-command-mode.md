# Design: Command mode (Phase 2 rework)

Implementation spec for the Phase 2 rework. `docs/product.md`,
`docs/architecture.md`, and `docs/roadmap.md` describe the product intent;
this document is the source of truth for *how* command mode is rebuilt and
*why* each decision was made.

## Why

Command mode functioned mechanically (trigger, transcribe, inject, fallback)
but produced untrustworthy output. The observed failure: a dictated
transcript containing an instruction — "make these changes to agents.md, add
an agent named Agent X…" — was *executed* by the model, which returned a
fabricated `# Mini Agent.md` changelog. The user's actual words were lost.

Root cause is structural, not prompt-wording. `CommandProcessor` puts the
instruction inside the same user message as the text to be transformed
(`CommandProcessor.swift:41`) and asks the model to find it. The system
prompt and user message *are* separate channels in `LanguageModelSession`;
we chose to merge them. A model cannot separate two roles that arrive on one
wire, so the separation must happen in our code before the model is called.

Secondary findings from `docs/command-mode-experiment.md`:

- Instructions cannot reliably suppress unwanted behavior; config G's
  anti-preamble line was insufficient.
- Cleanup itself corrupts text ("Of course we can reschedule the meeting."
  corrupted in every config).
- The model categorically cannot do spoken punctuation ("bracket
  open/close" / "new paragraph" never worked in any config).
- Schema-constrained output (L2) destroyed formatting fidelity; per-template
  free-form prompts are the right shape.

## Goals

- Never execute an instruction that appears inside dictated content.
- Make the instruction/content boundary deterministic.
- Make cleanup (stammers, repeats, thinking-aloud) the productive default.
- Guarantee that no model output can replace the user's words wholesale.
- Keep plain dictation fast and verbatim-modulo-explicit-tokens.

## Non-goals (this rework)

- Streaming partial transcripts.
- Transcript history / persistence.
- Multi-turn or session context (each utterance remains independent).
- Assistant/agentic behavior, tool use.
- Background / cross-app insertion — **deferred**, see the last section.

---

## Pipeline

```text
                    ┌── AX selection read (at chord press) ──┐
                    │                                        │
chord start ────▶ capture InjectionTarget (pid + AX element) │
                    │                                        │
utterance ────▶ ASR transcript                               │
                    │                                        │
                    ▼                                        ▼
        SpeechTokens.substitute(transcript)        (selection used as content)
                    │
                    ▼
        CommandGrammar.match(utterance)  ──▶ { transform?, remainder, requiresSelection }
                    │
        ┌───────────┼────────────────┬───────────────────────────┐
        │           │                │                           │
   no selection,  selection      selection,               no selection,
   no match       + match        no match                 match, requiresSelection
        │           │                │                           │
   CLEANUP       TRANSFORM      REFUSE loudly             REFUSE loudly
        │           │
        ▼           ▼
  deterministic  template prompt
  cleanup first  (full output)
        │           │
        ▼           ▼
  SubsequenceGuard  (no guard; paraphrase allowed)
        │           │
        ▼           ▼
   insert / write selection / clipboard fallback
        │
        ▼
   retain raw + inserted for recovery
```

---

## Components

### 1. `SpeechTokens` (new, `Sources/PfeiferCore/SpeechTokens.swift`)

Deterministic spoken-punctuation substitution. Runs on every transcript
*before* any model call, so the model never sees the literal token words and
the guard compares post-substitution text on both sides.

- Pure: `static func substitute(_ text: String) -> String`.
- Applied to plain dictation and command mode (per `product.md`, this
  rewrites the "verbatim" guarantee — see Guarantees).
- On by default; behind a setting so it can be disabled.
- Token list is collision-safe only. Explicitly **excluded**: bare
  "comma", "period", "colon" — they collide with legitimate speech ("put a
  comma after that") and reintroduce content/instruction ambiguity.

| Spoken | Emitted |
| --- | --- |
| `quote … unquote` | `"…"` |
| `open quote` / `close quote` | `"` |
| `open bracket` / `close bracket` | `[` / `]` |
| `open paren` / `close paren` | `(` / `)` |
| `new paragraph` | blank line |
| `new line` | line break |

Multi-word phrases matched longest-first, case-insensitive, word-boundary
anchored. Unit-tested for collisions.

### 2. `CommandGrammar` (new, `Sources/PfeiferCore/CommandGrammar.swift`)

Leading-only deterministic classifier. No embedded natural-language command
detection — that is the same semantic ambiguity as the original bug, moved
into a regex.

- Pure: `static func match(_ utterance: String) -> Match`.
- `Match { transform: Transform?, remainder: String, requiresSelection: Bool }`.
- Case-insensitive, whitespace-trimmed, anchored at `startIndex`,
  longest-trigger-first.
- The matched trigger phrase is stripped; `remainder` is the content when no
  selection is present.

`Transform` is an enum with a `requiresSelection` flag:

| Transform | Leading triggers | requiresSelection |
| --- | --- | --- |
| `.bullets` | "format this as a bullet list", "turn this into bullets", "make this a bullet list" | no |
| `.paragraph` | "format this as a paragraph", "make this a paragraph", "turn this into a paragraph" | no |
| `.email` | "make this an email", "turn this into an email", "draft this as an email" | no |
| `.concise` | "make this more concise", "shorten this", "trim this down" | no |
| `.formal` | "make this more formal", "make this professional" | no |
| `.grammar` | "fix the grammar", "correct the grammar", "proofread this" | no |
| `.punctuation` | "fix the punctuation", "add punctuation" | no |
| `.summarize` | "summarize this", "summarise this" | **yes** |
| `.rewrite` | "rewrite this", "reword this" | **yes** |
| `.fix` | "fix this", "correct this" | **yes** |

`.summarize` / `.rewrite` / `.fix` have no meaningful self-contained form
(their content would be the empty remainder), so they require a readable
selection and refuse loudly otherwise.

### 3. `CommandTemplates` (new, `Sources/PfeiferCore/CommandTemplates.swift`)

One narrow system instruction per transform, free-form output (schema output
was measured and rejected). Chosen deterministically by `CommandGrammar`,
never by the model.

| Transform | System instruction |
| --- | --- |
| `.bullets` | *You are a formatter. Rewrite the text as a bullet list. Preserve every fact, name, number, and link exactly. Do not add, drop, or infer anything. Output only the list.* |
| `.paragraph` | *You are a formatter. Rewrite the text as one flowing paragraph. Preserve every fact, name, and number exactly. Do not add or drop information. Output only the paragraph.* |
| `.email` | *Rewrite the text as a short professional email. Preserve every fact, name, and commitment exactly. Invent no recipients, dates, or promises. Output only the email body.* |
| `.concise` | *Rewrite the text more concisely. Keep every distinct fact and name. Remove only filler and redundancy. Output only the text.* |
| `.formal` | *Rewrite the text in a formal, professional register. Change wording only; preserve meaning, facts, and names exactly. Output only the text.* |
| `.grammar` | *Correct grammar, spelling, and punctuation only. Do not reword, reorder, add, or remove content. Output only the corrected text.* |
| `.punctuation` | *Add or correct punctuation and capitalization only. Change no words. Output only the text.* |
| `.summarize` | *Summarize the text in at most three sentences. Preserve every distinct fact and name. Add nothing that is not in the text. Output only the summary.* |
| `.rewrite` | *Rewrite the text for clarity. Preserve every fact, name, and commitment exactly. Change wording only. Output only the rewritten text.* |
| `.fix` | *Correct errors in the text. Preserve every fact, name, and number exactly. Change only what is wrong. Output only the corrected text.* |
| `.cleanup` (default) | *You are a dictation cleaner. Remove filler words, humming, immediate word repetitions, and abandoned false starts where the speaker corrects themselves. Preserve every distinct fact, name, and number; preserve all other wording and order. Output only the cleaned text.* |

### 4. `SubsequenceGuard` (new, `Sources/PfeiferCore/SubsequenceGuard.swift`)

Structural safety net for the cleanup path. A fabricated document is not a
subsequence of what the user said, so this directly kills the observed
failure.

- Pure: `static func isSubsequence(_ output: String, of input: String) -> Bool`.
- Tokenize: lowercase, strip punctuation, split on whitespace.
- Cleanup output must be a token-subsequence of the (post-`SpeechTokens`)
  input. Deletions and case/punctuation normalization only — no insertions,
  no paraphrase.
- On failure: discard the model output, insert the deterministic cleanup
  result, notify the user.
- Deterministic normalization (numbers, times, dates) happens in our layer,
  never in the model, so it never trips the guard.
- Transform path: no subsequence guard (paraphrase is the point); instead the
  raw transcript is retained for recovery.

### 5. Deterministic-first cleanup

Two systems may alter cleanup text; the order is fixed and tested.

1. `SpeechTokens.substitute` on the raw transcript.
2. Code removes fillers (`um`, `uh`, `er`, `erm`, `hmm`) and immediate
   word/phrase repetitions.
3. The model handles self-corrections and abandoned false starts
   ("I went to the— actually I drove") — the part that genuinely needs it.
4. `SubsequenceGuard` against the post-substitution input.

Minimizing how much text the model is invited to rewrite is the only lever
that actually reduces conflation, since prompts cannot.

### 6. `InjectionTarget` + `SelectionReader` (new)

Target capture at chord-press, not at injection time. This also fixes a
latent bug: today, if focus changes during transcription and the LLM pass,
the synthetic ⌘V lands in whatever app is frontmost.

- `InjectionTarget`: captured `pid` + `AXUIElement` of the focused element.
- `SelectionReader`: reads `kAXSelectedTextAttribute` and whether the element
  supports it (distinguishing "empty selection" from "attribute
  unsupported").
- Captured when recording starts (`DictationCoordinator.toggle` `.idle`).
- Injection time: if the captured target is still frontmost, current
  pasteboard+⌘V path. If it is not, do **not** paste blindly — attempt an
  AX-direct write, else leave the text on the clipboard and notify. Full
  background insertion is deferred (below).

### 7. `CommandProcessor` rework (`Sources/PfeiferCore/CommandProcessor.swift`)

Protocol change:

```swift
func process(_ content: String, transform: Transform) async throws -> String
```

- One fresh `LanguageModelSession` per utterance, `CommandTemplates`
  instruction for the chosen transform, greedy, token-bounded.
- `CommandProcessorError` vocabulary unchanged.
- No classification inside the processor — it is told the transform.

### 8. `DictationCoordinator` wiring (`Sources/PfeiferCore/DictationCoordinator.swift`)

Per utterance:

1. At `.idle` → `.recording`: capture `InjectionTarget` and selection;
   latch `commandModeActive` (existing behavior).
2. At stop: transcribe, apply `SpeechTokens.substitute`.
3. If command mode:
   - `CommandGrammar.match(utterance)`.
   - Resolve content source:
     - selection readable + match → transform, content = selection.
     - selection readable + no match → refuse loudly, leave selection.
     - no selection + shared match → transform, content = remainder.
     - no selection + `requiresSelection` match → refuse loudly.
     - no selection + no match → `.cleanup` on the utterance.
   - Cleanup path: deterministic cleanup → model → guard → insert.
   - Transform path: model → insert / replace selection; retain raw.
4. Retain last raw transcript + last inserted text in memory.
5. Failure/refusal paths never lose text: clipboard fallback + notification,
   per the existing guarantee.

### 9. App shell (`Sources/Pfeifer/PfeiferApp.swift`)

- Menu items: "Copy last raw transcript", "Copy last inserted text".
- Setting for spoken punctuation (default on).
- Existing Apple Intelligence gating unchanged.

---

## Guarantees

Two guarantees now, by path:

- **Cleanup path**: output is a token-subsequence of the (token-substituted)
  raw transcript. Deletions and case/punctuation only.
- **Transform path**: output may paraphrase, so the raw transcript is
  retained and retrievable.

`product.md:29` "The transcript is never silently lost" must be reworded:
plain dictation is verbatim except explicit spoken-punctuation tokens, and
command mode may clean or transform text but always retains the raw
transcript.

## Latency

Instrument `process()` per utterance (cleanup vs each transform). Budget:
key-release → insert ≤ 2s for cleanup, ≤ 3s for a transform at a 15s
utterance. If exceeded, in order: tighten per-template token caps, show an
explicit processing indicator, then consider streaming. Measure after the
rework, against the new job — not the old one.

---

## Implementation phases

Commit per phase, keep `swift build` green.

- **Phase A** — `SpeechTokens` + setting + tests.
- **Phase B** — `CommandGrammar`, `CommandTemplates`, `CommandProcessor`
  API rework + tests.
- **Phase C** — `SubsequenceGuard`, deterministic-first cleanup, raw/inserted
  retention, menu items + tests (including the mock-agents.md case).
- **Phase D** — `InjectionTarget`, `SelectionReader`, target capture at
  start, AX-direct write / clipboard fallback + tests.
- **Phase E** — latency instrumentation; update `product.md`,
  `architecture.md`, `roadmap.md`; fold or delete `experiments/command-mode`;
  re-run bench against the new design.

No new dependencies, no downloads. Confirm the test count rises from 51 —
a green run reporting zero tests is a failure.

## Risks

- V1 selection-aware mode works only in apps exposing `AXSelectedText`;
  everything else refuses loudly.
- Deterministic-first cleanup is two systems mutating text; ordering is
  pinned by tests.
- The strict cleanup guard may reject legitimate cleanups at first; tune the
  deterministic layer, not the guard.

## Deferred

- **Background / cross-app insertion.** Let the user fire a command, switch
  to another app, keep working, and have the result land in the original
  target. Synthetic ⌘V cannot address a non-focused app; the only universal
  mechanism is focus-stealing (activate target, paste, reactivate current),
  which interrupts the user and can eat in-progress input. True background
  insertion requires an AX-direct write into a writable text element, which
  not all apps expose. Tracked in `docs/architecture.md` and
  `docs/roadmap.md`.
- Streaming insertion, transcript history, per-app AX refinement, multi-turn
  context.
