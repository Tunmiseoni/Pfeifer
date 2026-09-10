# Pfeifer — Roadmap

Each phase ends with a working app you can actually use. Phases follow the
architecture in `docs/architecture.md`.

## Phase 0 — ASR benchmark spike (no app)

Goal: pick the `Transcriber` backend using the decision rule in
`docs/architecture.md`, before the architecture locks in. This is running
sample projects on test audio with a stopwatch — no ML expertise needed.

1. Record three test clips (≈5s, ≈15s, ≈60s) of real dictation.
2. Run each candidate on the clips; measure transcription latency, peak
   memory, and model download size.
3. Sanity-check accuracy on your own speech (accent, technical terms).
4. Record the numbers in this file and pick the winner per the rule.

Exit: a chosen backend, with numbers to justify it.

### Phase 0 results (2026-09-09, M1 / 8 GB, macOS 26.6)

Clips: real dictation, 16 kHz mono, recorded via `benchmark/` ClipRecorder.
Numbers are key-release → text for the full clip, best of 3 warm runs.

| Candidate | 5s | 15s | 60s | Peak RSS | Load time |
| --- | --- | --- | --- | --- | --- |
| FluidAudio (Parakeet v2, CoreML/ANE, in-process Swift) | 0.14 s | 0.21 s | 1.13 s | 104 MB | ~30 s (ANE compile, every launch) |
| ONNX Runtime int8 (CPU) | 0.17 s | 0.48 s | 2.4 s | 1.58 GB | <0.01 s |
| ONNX Runtime int8 (CoreML EP) | — | 2.6–3.2 s | n/a | — | minutes per audio length |

- **ONNX + CoreML EP is impractical.** The int8 encoder splits into 368
  CoreML partitions and CoreML specializes per input shape, so every new
  audio length triggers a multi-minute recompile (the 60s shape never
  finished compiling within a 5-minute budget). Warm runs are still ~5x
  slower than CPU because only ~44% of encoder nodes run on CoreML and the
  partition boundaries cost host copies.
- **Accuracy:** near-identical between the two passing candidates on the
  15s clip (common words and "Parakeet" correct). The invented name
  "Pfeifer" garbles identically in every backend — a model+accent artifact,
  not a runtime one. FluidAudio's chunked 60s path degrades slightly vs
  ONNX's single pass; both are fine at dictation lengths (≤30s).
- **FluidAudio model load is ~30s per process launch** — the E5RT/ANE
  compile is not cached across processes. Tolerable for a resident
  menu-bar app that preloads at startup (104 MB resident), but it must not
  block first use. The 60s FluidAudio number also includes chunk
  orchestration; at v1 dictation lengths it is irrelevant.

**Decision: FluidAudio** — Parakeet TDT v2 via CoreML on the Neural Engine,
in-process Swift. Fastest passing candidate by ~2x at the 10s-utterance
budget (~0.17 s extrapolated vs ~0.32 s), ~15x lower memory, no Python.
The `Transcriber` protocol stays; the ONNX CPU path measured here remains
the documented escape hatch.

### Phase 0 addendum — Parakeet Unified EN head-to-head (2026-09-09)

Before Phase 1, reconsidered the model within FluidAudio. Parakeet TDT v3
was rejected on paper: it is the multilingual (25 European languages)
variant with an English recall tax — FluidAudio's own docs position v2 as
the English-only, highest-recall model — and its v3 CoreML export carried a
window-composition word-corruption bug (FluidAudio#760) whose fix (Encoder_v2
re-quantization, PR #872) was in no release at the time. Benchmarked
**Parakeet Unified EN 0.6B** (FastConformer-RNNT, English-only, same 0.6B
class) instead — the only English model with a streaming export, which the
Phase 3 hold-to-talk end-state needs.

Same clips, same machine, best of 3 warm runs:

| Model | 5s | 15s | 60s | Load cold / warm | Peak RSS / footprint |
| --- | --- | --- | --- | --- | --- |
| Parakeet TDT v2 | 0.113 s | 0.181 s | 0.818 s | 33.4 s / 0.27 s | 88 MB / 57 MB |
| Parakeet Unified EN int8 | 0.102 s | 0.272 s | 0.811 s | 26.9 s / 0.39 s | 626 MB / 73 MB |

- Accuracy on our clips is a wash; both garble "Pfeifer"/"Tunmise" (a
  model+accent artifact, not a runtime one). Both emit punctuation and caps.
- Correction to the Phase 0 load-time finding: on this OS build the E5RT/ANE
  compile **caches across process launches**. First-ever load per model is
  ~30 s; subsequent launches load in < 0.5 s. The app still preloads in the
  background defensively.
- Streaming preview (320 ms fast-feel tier, `70_2_2` int8 encoder): ~30 ms
  compute per 160 ms chunk (5.3x real-time headroom), first partial text
  ~4 s in, continuous updates. Phase 3 hold-to-talk is viable; streaming
  transcripts are visibly rougher than batch — the expected tier tradeoff.
- Model files live in `models/parakeet-unified-en-0.6b/` (offline int8 set
  plus the 320 ms streaming encoder, staged for Phase 3).

**Decision: Parakeet Unified EN 0.6B (int8)** as the app's model. The 15s
latency gap (0.27 s vs 0.18 s) is imperceptible against the 1 s budget,
accuracy is at least as good, and it is the only English model whose
streaming export serves Phase 3 without a second model swap. Accepted
costs: ~600 MB resident (73 MB true footprint, fine on 8 GB) and a ~140 MB
larger download than v2. Parakeet TDT v2 stays on disk as the documented
lighter fallback; the ONNX CPU path remains the escape hatch.

## Phase 1 — Core loop, no LLM

Global hotkey → record → transcribe → insert at the cursor, plus the
clipboard fallback and notification.

Exit: you can dictate into Mail/Notes/Slack all day and never lose a
transcript.

## Phase 2 — Command mode

Apple Foundation Models integration: an opt-in mode (modifier-hold or spoken
prefix — decide here) that post-processes the transcript before insertion.

Exit: "reformat this as a bullet list" works end-to-end, on-device.

## Phase 3 — Polish

- Settings UI (hotkey, model, command-mode trigger)
- Streaming partial transcripts in a floating indicator: holding the
  chord streams live (via Parakeet Unified's streaming export, already
  staged in `models/`), tapping keeps the batch toggle — disambiguated
  by press duration
- Transcript history
- Per-app injection improvements (AXUIElement)

## Explicitly not on the roadmap

See non-goals in `docs/product.md`.
