# Quartet Desk

A native SwiftUI macOS app that runs every query past a **quartet** — a panel of
4 LLMs queried in parallel — then has an anchor model synthesize one answer with
**dissent surfaced explicitly**. It applies the multi-model judge-panel
philosophy (used as a PR quality gate elsewhere) to general questions:
"write me a marketing plan", "review this contract clause", "plan this launch".

The core bet: one model's answer hides its blind spots; four models' answers
*disagree* at exactly the points you should be thinking hardest about. Quartet
Desk makes that disagreement a first-class output — a run without a parseable
dissent record shows a **"dissent extraction failed"** banner rather than
pretending consensus.

## Status: v1

Engine, providers, UI, export, and history are implemented and unit-tested
(engine with fakes/canned frames, the transport with canned HTTP responses,
the app model's run lifecycle with injected resolvers). Live end-to-end runs
(all 4 seats + synthesis + dissent) have been verified against the real APIs —
you still need to add your own API keys in Settings first.

Streaming calls retry transient failures (429/5xx/529, pre-data truncation)
with bounded, jittered backoff — never after the first received byte, so a
partial answer is never duplicated — and every provider call runs under a
per-call wall-clock timeout so a wedged stream can't hang a run. Answers cut
off at the model's token limit are kept but explicitly flagged as INCOMPLETE
(per-seat banner, synthesis-prompt note, export note) rather than passed off
as whole.

## Branding

Quartet Desk is published by **Affirmi Inc.** The `tv.affirmi` reverse-DNS
namespace (bundle id, Keychain service, `os.Logger` subsystem) is the
publisher's own domain and is intentional — it carries no infrastructure
coupling (no hosts, project refs, or secrets).

## What it does

1. **Seats** — 4 configurable panelists (provider + model id). Defaults:
   | Seat | Provider | Model |
   |---|---|---|
   | 1 (anchor) | Anthropic (direct) | `claude-opus-4-8` |
   | 2 | OpenRouter | `openai/gpt-5.6-sol-pro` |
   | 3 | OpenRouter | `google/gemini-3.1-pro-preview` |
   | 4 | OpenRouter | `qwen/qwen3.7-max` |
2. **Run pipeline** — the same prompt fans out to all 4 seats in parallel
   (streamed live into per-seat panes). The anchor then receives all answers and
   produces (a) one synthesized answer and (b) a structured dissent list
   (`{"dissents":[{topic, who, position}]}`) behind a `===DISSENT===` marker.
   Optional **Deliberate** toggle (off by default) adds a round 2 where each
   seat sees the others' answers and revises before synthesis.
3. **Result tabs** — ANSWER (synthesized, rendered markdown), PANEL (4 cards
   with each seat's full answer + usage + per-seat cost), DISSENT (disagreement
   list, or the fail-closed banner).
4. **Cost** — computed from provider-reported usage × an editable price table.
   Models without a configured price show **"price not set"** — the app never
   invents a number. Bundled prices: `claude-opus-4-8` $5/$25, `gpt-5.6-sol-pro`
   $5/$30, `gpt-5.6-terra` $2.5/$15, `gpt-5.6-luna` $1/$6 per MTok. Gemini/Qwen
   prices are intentionally unbundled — set them in Settings → Prices.
5. **Images** — drag-drop / paste / file-pick images into the composer; they're
   downscaled to ≤2048px long side and re-encoded as JPEG ≤4MB, then sent to all
   seats as multimodal content blocks.
6. **Export** — ANSWER or the full run to `.md` (toolbar → Export). PDF export
   is a stubbed, disabled menu item (see TODO in `RootView.swift`).
7. **History** — every run persists as JSON under
   `~/Library/Application Support/QuartetDesk/runs/`; sidebar lists past runs.
8. **Keys** — stored in the macOS Keychain (`kSecClassGenericPassword`, service
   `tv.affirmi.quartetdesk`), one item per provider. Settings has a **Test**
   button per key making a cheap live call (models list / key introspection).

## Architecture

```
App/                          @main shell (xcodegen app target)
Sources/
  QuartetEngine/              UI-free, network-free core  ← unit tested
    Models.swift              Seat, ChatMessage, ImageAttachment, TokenUsage
    StreamTypes.swift         StreamChunk, ProviderStreaming, ProviderResolving
    SSE/                      SSELineSplitter → SSEParser → per-provider decoders
    Prompt/PromptAssembly     panelist / synthesis / deliberation prompts
    Dissent/DissentParser     fail-closed ===DISSENT=== + JSON extraction
    Pricing/PriceTable        price lookup + CostCalculator
    Run/QuartetOrchestrator   fan-out → deliberate → synthesize → record
  QuartetProviders/           URLSession streaming clients + Keychain + KeyTester
    AnthropicClient           Messages API (x-api-key, anthropic-version, SSE events)
    OpenAIChatClient          OpenAI + OpenRouter (Bearer, chat/completions SSE)
  QuartetExport/              MarkdownExporter + RunHistoryStore
  QuartetUI/                  SwiftUI views + @Observable AppModel + ImagePipeline
Tests/
  QuartetEngineTests/         SSE, decoders, dissent, prices, prompts, orchestrator,
                              retry policy, timeout, truncation
  QuartetProvidersTests/      shared SSE transport vs canned HTTP (retry, envelopes)
  QuartetUITests/             AppModel run lifecycle (Stop, usage math, attachments)
```

Key boundaries:
- **The engine never touches the network or AppKit.** Providers implement
  `ProviderStreaming`; the orchestrator is tested end-to-end with fakes.
- **Fail closed everywhere.** SSE decoders require an explicit terminal frame
  (`message_stop` / `[DONE]`); a stream that ends without one throws
  `truncatedStream` and the seat is marked failed — a half answer is never shown
  as complete. Dissent JSON that doesn't parse → banner, not silent consensus.
- **No silent failures.** Every network call checks HTTP status (error body
  captured), every catch logs via `os.Logger` (subsystem
  `tv.affirmi.quartetdesk`), and errors surface in the UI.

## Build

```bash
# Libraries + engine tests (headless)
swift build
swift test

# The actual .app (requires xcodegen: brew install xcodegen)
xcodegen generate
xcodebuild -project QuartetDesk.xcodeproj -scheme QuartetDesk -configuration Debug build
# or: open QuartetDesk.xcodeproj and hit Run
```

First run: open Settings (Cmd+,) → API Keys, paste keys for Anthropic and/or
OpenRouter (the defaults need those two), hit **Test** on each, then run a query.

## Adding a seat model or a provider

- **New model on an existing provider**: Settings → Seats, edit the model id.
  Optionally add its price in Settings → Prices.
- **New provider**:
  1. Add a case to `ProviderKind` (`QuartetEngine/Models.swift`).
  2. If it speaks OpenAI chat-completions, add a `Flavor` to
     `OpenAIChatClient`; otherwise write a client conforming to
     `ProviderStreaming` (+ an SSE decoder in the engine so it's testable with
     canned frames — see `AnthropicSSEDecoder` for the pattern).
  3. Wire it in `KeychainProviderResolver.client(for:)` and add a Test call in
     `KeyTester`.
  4. The Settings key UI picks up the new `ProviderKind` case automatically.

## Getting started: keys

First launch opens a Setup Assistant. You need at minimum an
[OpenRouter](https://openrouter.ai/keys) key (covers seats routed through
OpenRouter — which can be all four, including Claude via
`anthropic/claude-opus-4.8`). Direct [Anthropic](https://console.anthropic.com/)
and [OpenAI](https://platform.openai.com/api-keys) keys are optional and only
needed if you point a seat at those providers directly.

Keys are stored **only in your Mac's Keychain** (app-owned items, so macOS
won't nag you with permission dialogs) and are only ever sent to the provider
you configured for that seat. Nothing else ever sees them. The Setup Assistant
is re-runnable from Help → Setup Assistant.

## What it costs (the FAQ everyone asks)

- A full run on four **frontier** seats costs roughly **$0.30–0.50**. Our first
  real run asked for a marketing plan and got four budgets back: $650, $1.5k,
  $4.2k, $12k. A single model hands you one of those numbers with full
  confidence — the spread *was* the answer. That's what the money buys.
- Panels can be **cheaper** than one big model: a jury of small, diverse models
  beat a single GPT-4 judge at ~1/7th the cost
  ([Verga et al. 2024](https://arxiv.org/abs/2404.18796)). Seats are fully
  configurable — a DeepSeek/Qwen/Llama budget quartet runs for **about a penny**.
- You don't quartet everything. You quartet decisions.
- The argument ages badly: frontier per-token prices dropped ~6× in a single
  model generation (gpt-5.5-pro → gpt-5.6-sol-pro).

## Security & privacy

- **Keys**: macOS Keychain only, sent only to the provider you chose. No
  proxy, no middleman, no telemetry of key material — the engine's secret
  redactor additionally scrubs anything key-shaped from user-facing errors.
- **Crash reports are double-gated**: the Sentry SDK initializes only if you
  opt in (Settings toggle, **default off**) *and* a DSN is present — and the
  DSN committed to this repo is an **empty string**, so source builds have
  telemetry compiled out no matter what the toggle says. Official release
  builds get a DSN injected at build time. Prompts, answers, and keys are
  never attached to any event (`beforeSend` scrubber, no content breadcrumbs).
- **Run history** stays local: JSON under
  `~/Library/Application Support/QuartetDesk/`.

Why a quartet at all? The long version, with the research and the production
PR gate this design comes from:
[Why the Quartet](https://appspace.affirmi.tv/blog#08-why-the-quartet).

## Known gaps (v1)

- Markdown rendering is modest (paragraph + fenced-code blocks, inline styles);
  headers/lists/tables render as plain-ish text.
- Synthesis and deliberation requests resend text only; images go to round-1
  panelist calls (and deliberation), not the synthesis call.
- Image attachments aren't persisted into history (only the count).
- PDF export is stubbed disabled.
- No notarization / Developer ID signing yet (ad-hoc signed, hardened runtime
  enabled). App icon is generated by `swift scripts/generate-appicon.swift`
  into the committed `App/Assets.xcassets`.
