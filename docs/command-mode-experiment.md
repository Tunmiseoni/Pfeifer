# Command-mode output hygiene — experiment results

Question: how do we stop command mode inserting model framing (e.g.
"Sure, here is the text with the instruction applied:") instead of only the
transformed transcript? Four candidate layers were proposed (L1 rewritten
instructions + few-shot, L2 programmatic schema, L3 deterministic stripper,
L4 `contentTagging`). This records the measurement used to decide which to
adopt.

Harness: `Sources/CommandModeBench` (`swift run CommandModeBench`), a
throwaway target. Corpus: 21 utterances — 8 plain reformats, 6 spoken
punctuation/formatting (`quotes … unquote`, `bracket open/close`, `comma`,
`new paragraph`), and 7 that must stay unchanged (including four traps that
legitimately open with "Sure", "Of course", "Here's", "Okay"), plus the
originally-reported failing utterance (U1).

Protocol: greedy sampling, 1 rep — outputs were verified identical across 3
reps (greedy is deterministic here), so reps were dropped for runtime.
L3 is applied post-hoc to every output and never fed to the model. A L3
"false positive" means it altered an output that was *already correct*.

## Configs

| ID | Instructions | Shape | Model |
| --- | --- | --- | --- |
| A | baseline (current production) | free-form | `.default` |
| B | rewritten + few-shot (L1) | free-form | `.default` |
| C | rewritten + few-shot (L1) | schema (L2) | `.default` |
| D | rewritten (L1) | schema (L2) | `.contentTagging` (L4) |
| E | rewritten (L1) | free-form | `.contentTagging` (L4) |
| F | baseline | schema (L2) | `.default` |
| G | baseline + anti-preamble line | free-form | `.default` |

## Results

| ID | preambles | failures | L3conservative fired / false-pos | L3aggressive fired / false-pos |
| --- | --- | --- | --- | --- |
| A | **1** | 7 | 1 / **0** | 5 / 2 |
| G | **1** | 7 | 1 / **0** | 5 / 2 |
| B | 0 | 6 | 1 / **0** | 4 / 2 |
| C | 0 | 6 | 0 / 0 | 4 / 2 |
| F | 0 | 11 | 0 / 0 | 4 / 3 |
| D | 0 | 18 (+1 error) | 0 / 0 | 0 / 0 |
| E | 0 | 19 | 0 / 0 | 0 / 0 |

## Layer verdicts

- **L4 `contentTagging` — reject.** Categorically wrong task: it emits tags
  ("text formatting", "list formatting", "bullet list format"), not rewritten
  text. 18–19/21 failures, and it degenerated into repetitive output in one
  run. Not a prompt issue; the wrong model mode.
- **L3 aggressive — reject.** It strips legitimate openers, altering outputs
  that were already correct (2 false positives: U4 "Sure, I'll take a look…",
  U7 "Okay, so the plan is…"). This is exactly the "bites us later" risk.
- **L3 conservative — safe here.** On this corpus it fired only on genuine
  framing (A/G's U1) and altered **zero** correct outputs. Coverage is proven
  only for the observed shapes ("<ack> … here is …:" / "here is …:").
- **L2 schema — reject.** It removes free-form framing structurally but
  degrades formatting fidelity badly: bullets collapse to a comma list (T2),
  "new paragraph" and spoken punctuation are lost, and punctuation is dropped
  (F's U2 lost its period). F failed 11/21.
- **L1 instructions + few-shot — reject as written.** It made preambles
  disappear, but at a worse cost: hallucination and unwanted instruction-
  following on text that must pass through. U1 returned a *few-shot example's*
  text; U3 "I'll send you the document tomorrow." became "I'll review it
  tomorrow."; U6 "Here's the thing about the deployment." exploded into a
  7-item bullet list. Losing the user's words is worse than a preamble.
- **G (baseline + explicit anti-preamble line) — insufficient.** Still leaked
  on U1, only shorter ("Sure, here is the text:"). Instruction-only fixes do
  not reliably suppress this on the on-device model.

## Recommendation

**Baseline instructions unchanged + the conservative deterministic stripper.**

Rationale: baseline (A) has the best content fidelity of any config (only
U1 leaked; formatting like bullets/paragraphs was preserved best), and the
conservative stripper removed that one leak with zero collateral damage on 21
utterances. Every alternative that removed the preamble (L1, L2, L4) paid for
it with mangled or hallucinated text, which violates the never-lost-trust
guarantee more severely than a stray "Sure,".

## Caveats and known gaps

- The stripper's coverage is only demonstrated for the observed framing
  shapes; other phrasings could still leak. Conservative by design.
- The model corrupts "Of course we can reschedule the meeting." in every
  config (inserts a comma or drops "Of course"). Not fixable by these layers.
- Spoken punctuation is only partly handled: "quotes … unquote" worked under
  L1 (not baseline), and **"bracket open/close" never worked in any config**
  — the model does not know that convention. `new paragraph` likewise.
- Command mode remains an opt-in mode precisely because verbatim fidelity is
  not guaranteed; this experiment reinforces that.

## Possible follow-ups (not decided)

- If spoken punctuation ("brackets", literal "comma", "new paragraph") is
  wanted, it should be handled by deterministic text substitution in our code,
  not by the model.
- Retest the stripper against a larger corpus of real failures before
  trusting its coverage.
- The harness (`CommandModeBench`) is throwaway; delete it or fold the corpus
  into a permanent test once a decision is made.
