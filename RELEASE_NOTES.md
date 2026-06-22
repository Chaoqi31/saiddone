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
