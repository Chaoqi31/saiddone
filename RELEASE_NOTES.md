# SaidDone v1.2.0

Safer fast dictation, faster warm runs, and more reliable History persistence.

## What's new in v1.2

- **Safer Fast Dictation** — polished text only replaces the draft when SaidDone can verify the original app, input field, and exact draft suffix. It never sends a blind Undo; when a safe swap is impossible, the final text is copied for manual paste.
- **Faster Translation** — polishing and translation now share one LLM operation instead of two sequential requests.
- **Consistent three-mode pipeline** — Voice Input, Translation, and Ask Anything now share ASR cleanup, dictionary handling, progress, timeout, timing, and output normalization.
- **More reliable History** — audio and JSONL persistence run outside the insertion hot path, mutations are serialized, writes are atomic, and entry/audio cleanup stays consistent across edit, delete, and clear.
- **Warm provider reuse** — changing unrelated settings no longer rebuilds already-warm ASR or LLM providers.
- **Reliable local model discovery** — WhisperKit and MLX model locations/readiness use one shared implementation, while existing Whisper downloads in the legacy location continue to work.
- **Stronger polish behavior** — expanded handling for fillers, spoken cancellation, self-correction, prompt-like dictation, mixed Chinese/English technical terms, and empty-output safety.
- **Expanded regression coverage** — 107 tests cover the unified pipeline, History races and failures, provider reuse, model storage, polish output, and safe fast-draft replacement. The cloud corpus remains an explicit opt-in live smoke test.

## Upgrade notes

No configuration migration is required. Existing local Whisper models are detected automatically.

# SaidDone v1.1.0

Typeless-style three modes, smarter zh-en polish, and more reliable recording.

## What's new in v1.1

- **Three modes like Typeless** — Voice Input `⌃⌥D`, Translation `⌃⌥T`, Ask Anything `⌃⌥A` (edit selected text or ask a question)
- **Smarter zh-en polish** — LLM uses context to fix obvious ASR mis-hearings in mixed Chinese/English speech
- **More reliable mic capture** — auto-restart input when audio route changes (Bluetooth connect/disconnect); clearer errors when no audio is captured
- **Polish safety** — never drop your words: empty polish falls back to the ASR draft; fast-insert draft is kept if polish fails
- **Settings migration** — old `rewriteHotkey` in config.json maps to Ask Anything automatically

## Install

1. Download **`SaidDone.dmg`** from [Releases](../../releases/latest)
2. Open the DMG → drag **SaidDone** to **Applications**
3. First launch: allow past Gatekeeper once (see [INSTALL.md](INSTALL.md))
4. Complete the **Setup Assistant** (mic + Accessibility + engines)

## Requirements

- Apple Silicon Mac (M1+)
- macOS 14 (Sonoma) or later
- ~3.8 GB disk for all-local models (optional if using cloud LLM)

## Shortcuts (default)

| Shortcut | Mode |
|---|---|
| `⌃⌥D` | Voice Input — speak, insert at cursor |
| `⌃⌥T` | Translation — speak one language, insert target language |
| `⌃⌥A` | Ask Anything — edit/query selection or ask a question |

All rebindable in Settings — including mouse side buttons.

MIT licensed.
