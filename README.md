# Pfeifer

**A native macOS voice layer: push-to-talk dictation into any app, transcribed
on-device with Parakeet, with an opt-in command mode powered by Apple
Foundation Models.**

Pfeifer is a menu-bar utility. Tap a global hotkey, speak, tap again, and the
text is inserted at the cursor in whatever app has focus. Audio never leaves
the machine.

> **Status:** dictation is used daily and is the stable path. Command mode
> (the Foundation Models cleanup/transform pass) is **experimental and under
> rework** — treat its output as untrusted and expect the design to change.

## How it works

```
Hotkey ──▶ Recorder ──▶ Transcriber ──▶ Command mode ──▶ Injector
(global)   (mic audio)   (local Parakeet)  (opt-in LLM)     (pasteboard + ⌘V)
```

- **Dictation** — hold the chord to record, release to transcribe. Parakeet
  Unified EN 0.6B runs locally on the Neural Engine via
  [FluidAudio](https://github.com/FluidInference/FluidAudio); the text is
  inserted at the cursor. If insertion fails, the transcript goes to the
  clipboard with a notification — it is never silently lost.
- **Command mode** (opt-in, one-shot) — post-process the utterance with Apple
  Foundation Models before insertion. The instruction/content boundary is
  resolved in code, not by the model. See
  [`docs/design-command-mode.md`](docs/design-command-mode.md).

Deeper detail lives in [`docs/`](docs/): [`product.md`](docs/product.md),
[`architecture.md`](docs/architecture.md), [`roadmap.md`](docs/roadmap.md).

## Requirements

- Apple Silicon (M-series) Mac
- macOS 26 or newer
- Apple Intelligence enabled (required by the Foundation Models framework)

Intel Macs and silent cloud fallbacks are explicitly out of scope.

## Permissions

| Permission | Needed for | When |
| --- | --- | --- |
| Microphone | Recording | First use |
| Accessibility (trusted) | Global hotkey, text insertion | First launch — manual grant in System Settings |
| Notifications | Clipboard-fallback notice | On fallback |

Global hotkeys and synthetic `⌘V` require Accessibility trust, which is why the
app is non-sandboxed and not distributed via the App Store.

## Build and run

Requires the Swift toolchain (CommandLineTools is sufficient; Xcode is not).
The project is verified against Swift 6.4.

```bash
make build      # swift build -c release
make test       # swift test
make app        # assemble and codesign Pfeifer.app
make app OPEN=1 # ...and launch it
```

For Accessibility grants to survive rebuilds, create the self-signed
`Pfeifer Development` signing identity once (otherwise the app is signed
ad-hoc and re-prompts after every rebuild):

```bash
make cert
```

## Model weights

The Parakeet Unified EN 0.6B CoreML weights are **not** bundled in this repo
(`models/` is gitignored). Download them from Hugging Face into
`models/parakeet-unified-en-0.6b/`:

```bash
huggingface-cli download FluidInference/parakeet-unified-en-0.6b-coreml \
  --local-dir models/parakeet-unified-en-0.6b
```

The app resolves the model directory from `PFEIFER_MODEL_DIR` first, then from
`models/parakeet-unified-en-0.6b/` at the repo root. Loads are local-directory
only — the app never fetches models at runtime.

## License

[MIT](LICENSE). The Parakeet models and the FluidAudio dependency are
distributed under their own terms.
