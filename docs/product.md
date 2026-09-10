# Pfeifer — Product Brief

A native macOS voice layer: push-to-talk dictation into any app, transcribed
locally with Parakeet, with an opt-in command mode powered by Apple Foundation
Models.

## Core loop (v1)

Tap a global hotkey (Right-⌥+Space) → speak → tap again → Parakeet
transcribes on-device → the text is inserted at the cursor in the focused
app.

The tap-toggle interaction is v1's deliberate simplification of the
intended end state: *holding* the chord while streaming live transcription
(Apple-STT style). When streaming arrives, press duration will
disambiguate the two — tap toggles a batch recording, hold streams.

When command mode is active, the transcript is first post-processed by
the on-device Foundation Model (cleanup, reformatting, commands) before
insertion. When it is off, plain dictation is inserted verbatim.

## Guarantees

- **Local-first.** Audio and transcripts never leave the machine. No cloud
  ASR, no cloud LLM, ever.
- **The transcript is never silently lost.** If insertion fails or there is
  no paste target, the transcript goes to the clipboard and a notification
  shows what was captured.

## Platform floor

- Apple Silicon (M-series)
- macOS 26 or newer
- Apple Intelligence enabled (required by the Foundation Models framework)

The app fails gracefully with a clear message on machines below the floor.
Intel Macs and cloud fallbacks are explicitly out of scope.

## Non-goals (v1)

- Assistant mode / tool use / agentic behavior
- Chat UI
- Always-listening ("hey Pfeifer") wake-word activation
- Streaming partial transcripts during recording
- Cloud LLM or cloud ASR fallback
- App Store distribution (the core mechanic requires Accessibility trust and
  no sandbox — see `docs/architecture.md`)
- Cross-platform (macOS only)

## Context

Personal side project. The bar is "makes my life slightly easier" — prefer
the smallest thing that works over process, ceremony, or generality.
