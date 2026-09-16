# Pfeifer — System Architecture

## Overview

Pfeifer is a single native macOS app (Swift/SwiftUI), non-sandboxed, running
as a menu-bar utility. One process owns the whole pipeline.

```text
HotkeyManager ──▶ Recorder ──▶ Transcriber ──▶ CommandMode ──▶ Injector
(global hotkey)   (mic audio)   (protocol,     (opt-in LLM     (pasteboard +
                                local          post-process)   simulated ⌘V,
                                Parakeet)                      restore after)
```

Flow:

1. **HotkeyManager** — registers a system-wide hotkey; tapping the
   Right-⌥+Space chord toggles recording (hold-to-stream is the Phase 3
   extension, disambiguated by press duration).
2. **Recorder** — captures microphone audio via AVAudioEngine into a buffer
   (PCM, 16 kHz mono — Parakeet's expected input).
3. **Transcriber** — `protocol Transcriber` with one async entry point,
   `transcribe(audio) -> String`. The concrete backend is chosen by the
   Phase 0 benchmark (below). v1 is batch: the full clip is transcribed once
   after key release.
4. **CommandMode** — off by default. When active, the transcript is passed
   to the on-device Foundation Model (`FoundationModels` framework) for
   post-processing before insertion. A one-shot chord (Right-⌥+⇧+Space)
   activates it for a single utterance; plain dictation never passes
   through the LLM. Behind `protocol CommandProcessor`, so the coordinator
   is testable without Apple Intelligence and a cloud provider could later
   sit behind the same seam.
5. **Injector** — writes text at the cursor of the focused app: save the
   current pasteboard → set it to the transcript → synthesize ⌘V via
   CGEvent → restore the previous pasteboard contents. On any failure (no
   focused text target, AX error, permission missing), leave the transcript
   on the clipboard and post a notification.

## Key decisions

| Decision | Choice | Why |
| --- | --- | --- |
| App model | Native macOS, single process, menu-bar utility | Latency and direct access to Foundation Models and audio; containers can reach neither |
| Distribution | Direct (Developer ID), non-sandboxed, never App Store | Global hotkeys and CGEvent injection require Accessibility trust and no sandbox |
| ASR | Local Parakeet behind `protocol Transcriber` | Swappable runtime; chosen by benchmark, not vibes |
| LLM usage | Opt-in command mode only | Always-on rewriting adds latency to every utterance and mangles verbatim text |
| Command-mode trigger | One-shot Right-⌥+⇧+Space; transcript is the only input in v1 | A modifier chord is deterministic and needs no ASR reinterpretation (a spoken prefix relies on a wake word that already garbles); one-shot avoids a persistent mode that silently rewrites verbatim dictation. Reading the focused selection is deferred to Phase 3 |
| Injection | Pasteboard + simulated ⌘V, restore after | Most cross-app compatible; keystroke-by-keystroke is slow and breaks some apps |
| Transcripts | Never silently lost — clipboard fallback + notification | A dropped dictation destroys trust in the tool |
| v1 interaction | Tap-toggle on the Right-⌥+Space chord | Batch-first: the core loop is proven end-to-end before streaming exists. Hold-to-stream arrives in Phase 3, disambiguated from tapping by press duration; the chosen model (Parakeet Unified EN) already has the streaming export for it |

## ASR runtime: decision rule (Phase 0)

The runtime is decided by measurement, under a rule fixed in advance.

**Candidates**

1. `parakeet-mlx` — in-process Swift (MLX)
2. ONNX Runtime with the Parakeet ONNX export (CoreML execution provider)
3. Python sidecar process (`parakeet-onnx` or CTranslate2) — the complexity
   baseline

**Acceptance criteria (on the dev machine)**

- A 10-second utterance goes from key-release to inserted text in ~1s
- Peak memory stays under ~2 GB
- Fits inside a single `.app` (no bundled Python runtime)

**Rule:** pick the fastest candidate that passes. If no in-process candidate
passes, accept the sidecar's complexity. Start with
`parakeet-tdt-0.6b-v2`; drop to a smaller CTC model if it misses the latency
budget.

**Outcome:** FluidAudio (in-process Swift, CoreML/ANE) with **Parakeet
Unified EN 0.6B (int8)** as the model — benchmarked head-to-head against
TDT v2 (numbers in `docs/roadmap.md` Phase 0 addendum); Unified won on the
Phase 3 streaming future at an imperceptible latency cost. TDT v2 is the
documented lighter fallback.

## Permissions

| Permission | Needed by | When |
| --- | --- | --- |
| Microphone | Recorder | First use |
| Accessibility (trusted) | HotkeyManager, Injector | First launch, manual grant |
| Notifications | Clipboard-fallback notice | On fallback |

Dev builds must be signed with the stable self-signed "Pfeifer
Development" identity (created once via `make cert`, auto-detected by
`scripts/make-app.sh`, ad-hoc fallback with a warning): ad-hoc
signatures change every rebuild, which silently invalidates the
Accessibility grant — the System Settings toggle stays on while the new
binary stays untrusted. Distribution builds use Developer ID, which has
the same stability.

## Failure modes

| Failure | Behavior |
| --- | --- |
| Machine below platform floor | Clear message at launch, no crash |
| Apple Intelligence disabled | Command mode unavailable; plain dictation still works |
| Accessibility not granted | Prompt once at launch; rechecked silently (menu open + poll) until granted, watcher auto-installs |
| No focused paste target / injection fails | Clipboard + notification, never silent |
| ASR model not downloaded | Offer to download (showing the size) before first use |

## Risks & accepted tradeoffs

- `parakeet-mlx` is a community port and may lag NVIDIA's latest models.
  Mitigated by the `Transcriber` protocol; the sidecar is the escape hatch.
- Accessibility trust is a hard, manual gate for the core mechanic.
- The Apple Intelligence dependency excludes machines with it disabled —
  accepted.
- Per-app injection quirks (some apps ignore synthetic ⌘V or guard their
  pasteboards). Per-app AXUIElement handling is a later enhancement, not v1.

## Open branches

Unresolved by design, to be settled when their phase arrives:

- Command-mode trigger (modifier-hold vs spoken prefix)
- Streaming partial transcript design
- Per-app AXUIElement injection improvements
- Selection-aware command mode (read `AXSelectedText` as LLM context and
  replace the selection, so commands act on existing text, not just the
  captured utterance)
- Transcript history
- Multi-language support
- Personalization (deferred): Parakeet is a fixed pretrained model — the same
  weights on every utterance, with no adaptation to the speaker or their
  vocabulary. Any "it learns how I talk" behavior would be a separate feature,
  not a property of the runtime. Options to weigh if it is ever wanted:
  a decoder bias/custom-vocabulary list (targets names and jargon), or
  command-mode LLM correction against `Transcript history` (targets recurrent
  errors, adds a latency cost and can rewrite verbatim text). Fine-tuning on
  personal audio is out of scope — it conflicts with the local-first, no-ML-
  expertise shape of this project.
- System audio during capture (deferred): investigate how Siri accepts
  commands while audio is playing on the device (ducking or mixing the
  recognition stream against ongoing playback without stopping it). If we
  cannot recreate that behavior, fall back to muting device output audio
  while audio is being captured/recorded. Settle before v1 ships, since the
  fallback is a visible behavior change for anyone dictating over music or a
  call.
