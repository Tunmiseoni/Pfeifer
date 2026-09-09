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
- Streaming partial transcripts in a floating indicator
- Transcript history
- Per-app injection improvements (AXUIElement)

## Explicitly not on the roadmap

See non-goals in `docs/product.md`.
