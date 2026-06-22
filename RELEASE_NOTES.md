# SaidDone v1.0.0

First stable release. Local-first voice-to-text for macOS — press a hotkey, speak, and polished text lands at your cursor in any app.

## What's new in v1.0

- **Faster dictation** — optional “insert draft immediately, then polish in place” (see Settings → General)
- **Deterministic progress bar** — 0→1 overlay with transcribe / polish / insert stages
- **Mouse side-button shortcuts** — bind dictation to a mouse button (needs Accessibility)
- **Cloud polish timeout** — auto-extends for long speech so polish is not skipped
- **Keychain for API keys** — never stored in exported JSON
- **`.env` support** — drop `DEEPSEEK_API_KEY` in `~/Library/Application Support/SaidDone/.env`
- **History metadata** — shows pipeline time and “unpolished” when polish was skipped

## Install

1. Download `SaidDone.dmg` from [Releases](../../releases) or build with `./scripts/release.sh`
2. Open and drag to Applications; allow past Gatekeeper once (see [INSTALL.md](INSTALL.md))
3. Complete the Setup Assistant

## Requirements

- Apple Silicon Mac (M1+)
- macOS 14 (Sonoma) or later
- ~3.8 GB disk for all-local models (optional if using cloud LLM)

## Shortcuts (default)

| Shortcut | Mode |
|---|---|
| `⌃⌥D` | Dictation |
| `⌃⌥T` | Translation |
| `⌃⌥R` | Rewrite selected text |

All rebindable in Settings — including mouse buttons.

MIT licensed.
