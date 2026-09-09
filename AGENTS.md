# AGENTS.md

Guidelines for AI agents working in this repository. These apply to every tool
you use and every command you run.

## What this project is

Pfeifer is a native macOS voice layer: push-to-talk dictation into any app,
local Parakeet ASR, opt-in command mode via Apple Foundation Models. Read
`docs/product.md`, `docs/architecture.md`, and `docs/roadmap.md` before
changing anything — they are the source of truth for scope, settled design
decisions (with reasoning), and the ASR benchmark decision rule.

## Toolchain

- Native Swift/SwiftUI app for macOS 26+ on Apple Silicon, with Apple
  Intelligence assumed available (see the platform floor in `docs/product.md`).
- This is NOT a containerized project. There is no Docker, no npm, no web
  backend — never introduce them.
- Build and verify with the host toolchain: `swift build` and `swift test`
  for package targets, Xcode/`xcodebuild` for the app target.
- Prefer Apple frameworks (AVFoundation, AppKit, FoundationModels) over
  third-party dependencies. Every new SwiftPM dependency needs a reason.

## Downloads: ask first (internet is on a budget)

- **Always ask the user before downloading anything** — new SwiftPM packages,
  model weights (Parakeet models are hundreds of MB to ~2 GB; they live in
  the gitignored `models/` directory), or any new tool.
- **When a download might be warranted, present every viable option —
  including the one that needs a new package or model — with its tradeoffs,
  give a recommendation, then let the user decide.** Do not silently default
  to whichever path happens to avoid a download; reusing what is already
  present locally is one option to weigh on its merits, not the automatic
  winner.

## Permissions are manual gates

Microphone and Accessibility permissions require interactive grants in System
Settings. If a run fails on permissions, report that — do not retry in a loop
or try to work around the gate.

## Multi-phase work: commit per phase

- **For any change spanning more than one phase, commit after each phase** —
  at logically-complete boundaries where `swift build` passes.
- **Keep the tree compiling at every commit.** Group tightly-coupled changes
  into one commit when splitting them would break the build.
- **Stage only intended files.** Never commit secrets, `.env*` files,
  downloaded model weights (`models/`), or Xcode user state (`xcuserdata/`).
- **Write commit messages that explain why, not just what.** Do not amend,
  force-push, or use interactive rebase unless asked.
- If a phase cannot be completed cleanly, leave it uncommitted and report the
  blocker rather than committing a broken intermediate state.

## Voice-transcribed requests

- User messages may be voice-transcribed. If a technical term is ambiguous,
  malformed, or could have multiple interpretations, do not silently infer it.
- Ask a short clarification question and state the interpretation being
  checked.

## General

- Read existing code before changing it, and follow the conventions already
  in place.
- Prefer minimal, targeted changes over adding new files and dependencies.
