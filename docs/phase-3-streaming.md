# Phase 3 — Streaming hold-to-talk (plan)

Status: planned, not started. This is the working design for the first Phase 3
slice (`docs/roadmap.md` → "Streaming partial transcripts in a floating
indicator"). It records the decisions made before implementation so a later
session can pick it up without re-deriving them.

## Goal

End-state interaction described in `docs/product.md`: *holding* the chord
streams live transcription (Apple-STT style); *tapping* keeps the batch toggle.
Press duration disambiguates.

- Tap Right-⌥+Space → start/stop a batch recording (today's behaviour).
- Hold Right-⌥+Space → stream partials while held; insert the final transcript
  on release.
- Shift applies to either: Right-⌥+⇧ held → the final transcript is
  post-processed by the Foundation Model before insertion (command mode).

The 320 ms streaming export is already staged:
`models/parakeet-unified-en-0.6b/parakeet_unified_encoder_streaming_70_2_2_int8.mlmodelc`,
matching `UnifiedConfig(leftFrames: 70, chunkFrames: 2, rightFrames: 2)`.
The Phase 0 addendum measured ~30 ms compute per 160 ms chunk (≈5x real-time
headroom) on this hardware.

## Decisions (with reasoning)

### 1. Unify on the streaming manager — one encoder

`StreamingUnifiedAsrManager` serves **both** tap-batch and hold-stream. Tap
accumulates and `finish()`es at stop; hold additionally surfaces
`getPartialTranscript()` live.

Why: the two encoders are ~565 MB each on disk (`..._encoder_int8.mlmodelc`
and `..._encoder_streaming_70_2_2_int8.mlmodelc`). Keeping the offline batch
manager *and* the streaming manager resident would load ~1.1 GB of encoders at
once on an 8 GB machine. Unifying keeps only the streaming encoder resident —
about the same footprint as today, and one code path.

Accepted cost: batch accuracy moves from the offline encoder's 1.83% to the
streaming encoder's 2.14% WER on LibriSpeech test-clean (FluidAudio's own
numbers). Both are far below what dictation needs. This supersedes the Phase 0
"offline batch" baseline and must be recorded as a re-baseline in
`docs/roadmap.md`, not left as a stale number.

### 2. Tap-batch must process incrementally too

Because a single streaming manager is used, tap-batch **cannot** buffer the
whole clip and only process at stop: `finish()` would then pay the full
per-chunk cost for all audio at once (≈2 s for a 10 s utterance, over the 1 s
insertion budget). So tap and hold run the same incremental session; tap simply
suppresses partial presentation. This replaces the coordinator's current
"record → transcribe(full buffer)" path rather than extending it.

### 3. Shift+hold is command mode

Hold with Shift streams raw partials, then runs the final transcript through
the existing `CommandProcessor` before insertion, reusing Phase 2. Partials in
the floater are raw; only the inserted text is post-processed.

### 4. Press-duration gate

Threshold: 300 ms. While `idle`, pressing the chord arms a timer; release
before it is a **tap** (batch), the timer firing while still held is a
**hold** (stream). While a batch recording is already active, any chord press
immediately stops it (no duration ambiguity — the mode was decided at start).
The gate is a pure state machine so it is testable with an injected clock.

## Design

### Backend: `StreamingTranscriber`

Replaces the batch `Transcriber` seam with a streaming one, implemented on
`StreamingUnifiedAsrManager` (replacing `FluidAudioTranscriber`'s current
`UnifiedAsrManager` backend).

```swift
public protocol StreamingTranscriber: Sendable {
    var isReady: Bool { get async }
    func begin() async throws
    func append(_ samples: [Float]) async throws
    func partialTranscript() async -> String
    func finish() async throws -> String
    func cancel() async
}
```

- Preflight file list changes to the streaming encoder
  (`..._streaming_70_2_2_int8.mlmodelc`) plus decoder/joint/vocab.
- The actor serialises sessions; only one utterance runs at a time.
- `ModelHub.offlineMode = true` stays (local-directory-only loads).
- First-ever ANE compile (~30 s) is hidden by preloading at launch, as today;
  subsequent launches are warm (< 0.5 s).

### Recorder: live chunk delivery

Add an optional sink to the recorder without churning existing call sites:

```swift
func start(onSamples: (@Sendable ([Float]) -> Void)?) throws
```

The existing AVAudioEngine tap already converts each buffer to 16 kHz mono
`[Float]`; it additionally hands each converted buffer to the sink. Bridge the
sink into the transcriber through a single `AsyncStream<[Float]>` consumer so
chunk order is preserved and per-chunk `Task`s cannot reorder. Backpressure is
a non-issue: ~30 ms compute per 160 ms of audio.

### Hotkey: press/release, not toggle

`HotkeyWatcher` reports raw chord edges; the gesture layer decides intent.

```swift
public enum ChordEvent: Equatable, Sendable {
    case pressed(mode: ChordMode)   // initial Space keyDown, not autorepeat
    case released                   // chord ended
}
```

- Track `chordDown`; the chord ends on Space keyUp **or** Right-⌥ up while
  chordDown. A lone Right-⌥ press stays inert (current accepted tradeoff).
- Autorepeats are swallowed and never re-fire.
- The mode reported at `finish` is the mode latched at `pressed`.
- `ChordHandler` becomes `(ChordEvent) -> Void`.
- Existing classification test `spaceKeyUpIsNeverTheChord` changes to expect a
  release event, not `.other`.

### Gesture routing

- `ChordGesture` (pure, `pfeiferCore`): `pressed(at:mode:)`,
  `released(at:)`, `thresholdElapsed()` → returns actions
  (`.toggleBatch`, `.beginStream(mode)`, `.endStream`, `.none`). Driven by
  explicit timestamps so tests need no real timers.
- `ChordRouter` (MainActor): owns the 300 ms timer, calls the coordinator, and
  delegates the tap path to the existing `DictationCoordinator`.

### Coordinator: one session, two presentations

- New `.streaming` state alongside `idle/recording/transcribing/processing/injecting`.
- `beginStreaming(command:)`, `endStreaming()`, `cancelStreaming()`.
- Tap = begin with partials suppressed; hold = begin with partials presented.
- `endStreaming` → `finish()` → optional `CommandProcessor.process` → injector.
  The never-lost guarantee is unchanged: on failure the transcript goes to the
  clipboard with a notification; on command failure the raw text is inserted.
- Partial delivery goes through an injected `PartialTranscriptPresenting`
  protocol (the floater implements it; a mock records calls in tests).

### Floating indicator

`FloatingIndicatorController` (AppKit, in the app target):

- Borderless, `.nonactivatingPanel` `NSPanel` at `.floating` level,
  `ignoresMouseEvents = true`, `collectionBehavior` `[.canJoinAllSpaces,
  .stationary]`, top-centre under the menu bar.
- Non-activating is load-bearing: it must never steal focus from the target
  app, or injection misplaces the text.
- Shows "Listening…" until the first partial (~4 s in at this tier), then live
  text. Plain partial text for v1; FluidAudio's `PunctuationCommitLayer`
  (committed vs ghost styling) is a possible later polish.

Status item gains a `.streaming` display ("Pfeifer — listening…", waveform
symbol).

## Commit boundaries

Each commit leaves `swift build` and `swift test` green (AGENTS.md): confirm a
non-zero test count, never a silent zero-test run.

1. Backend unification: `StreamingTranscriber` + streaming-backed
   implementation + preflight/tests. Replaces the `Transcriber` seam and its
   mocks, so this is the largest churn and must keep the tree compiling.
2. Recorder live chunk sink.
3. `HotkeyWatcher` press/release classification + tests.
4. `ChordGesture` + `ChordRouter` + tests.
5. Coordinator streaming session + partial presenter + tests.
6. Floater + app wiring + status display.
7. Docs: `architecture.md` (streaming path, floater, press-duration;
   `StreamingTranscriber` seam), `roadmap.md` (mark this slice done; add the
   ASR re-baseline), `product.md` if interaction wording changes, AGENTS.md
   test count.

## Tests

Pure/unit (no mic, no model):

- Hotkey: press/release, lone-⌥, autorepeat, shift latched at press.
- `ChordGesture`: tap vs hold, timer fire, stop-while-recording, ignore while
  busy, mode latch.
- Coordinator: partials forwarded during hold and suppressed on tap; final
  inserted; Shift+hold post-processed; finish failure notified; cancel
  discards; empty transcript no-op.
- `MockStreamingTranscriber` replaces `MockTranscriber`; `MockRecorder` gains
  the sink.

Manual (permission/model gated, same policy as the ASR backend):

- `make app OPEN=1`: tap = old batch toggle; hold = live partials then insert
  on release; Shift+hold = post-processed; release slightly past threshold
  behaves as a hold; no focus steal; Apple Intelligence off still dictates.

## Risks

- Audio-thread → actor ordering/backpressure: solved by the single
  `AsyncStream` consumer; worth a focused test on the sink bridge if feasible.
- First streaming-encoder ANE compile (~30 s first-ever): preload in the
  background at launch, as the current backend does.
- Replacing the `Transcriber` seam ripples through coordinator tests and
  `InjectionTests`; grouped into commit 1.
- Streaming batch invalidates the Phase 0 batch numbers; the roadmap
  re-baseline must be written, not skipped.
- 8 GB machine: unified single encoder keeps resident memory roughly flat; do
  not regress into loading both encoders.

## Deferred (not in this slice)

- Selection-aware command mode is **not** deferred here: it moved into the
  Phase 2 command-mode rework (`docs/design-command-mode.md`). This slice
  must not re-defer or duplicate it.
- Per-app AXUIElement injection reliability.
- Transcript history.
- Settings UI (hotkey/model/trigger); the 300 ms threshold and chord stay
  hardcoded until then.
- Committed/ghost partial styling via `PunctuationCommitLayer`.
