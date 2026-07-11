# Contributing to Quartet Desk

Thanks for looking. Ground rules — they're the same ones the app itself was
built under:

## Build & test

```bash
swift build && swift test        # engine/providers/export/UI-model — must be green
brew install xcodegen            # once
xcodegen generate
xcodebuild -project QuartetDesk.xcodeproj -scheme QuartetDesk -configuration Debug build
```

## PR expectations

1. **Tests come with the change.** Engine and provider changes need unit tests
   (the SSE decoders are tested with canned frames — follow that pattern; no
   live API calls in the test suite).
2. **No silent failures.** Every error path surfaces to the UI and logs via
   `os.Logger`. Empty `catch {}` blocks will not merge.
3. **Fail closed.** A truncated stream, an unparseable dissent block, or a
   missing price must present as exactly what it is — never as a clean result.
4. **No secrets, ever.** No API keys, DSNs, tokens, or provider account
   details in code, tests, fixtures, or commit history. The committed
   `SENTRY_DSN` stays an empty string.
5. **Honest labels.** If a seat, model, or feature is degraded or stubbed, the
   UI says so. (The PDF export menu item is disabled on purpose.)

AI-agent-authored PRs are welcome — they get reviewed like everyone else's,
and yes, we review with a multi-model panel. That's kind of the whole thing.
