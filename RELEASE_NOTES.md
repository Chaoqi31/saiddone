# SaidDone v0.9.0 (Beta)

First public beta. Local-first voice-to-text for macOS: press a hotkey, speak, and AI-polished text lands at your cursor — in any app.

> **Beta** — core flows work end-to-end and are tested, but this is an early release. Expect rough edges; please file issues.

## Highlights

- **Guided first-run Setup Assistant** — permissions, engine choice, model download, and a live "try it" check, all in one flow.
- **Two simple choices, each Local or Cloud:**
  - **Speech → text (ASR):** WhisperKit on-device, or any OpenAI-compatible cloud.
  - **AI polish (LLM):** MLX Qwen3 on-device, or cloud (DeepSeek / OpenAI / compatible).
- **The polish is always an AI model** — never plain rule-based cleanup. Real punctuation, structuring, Simplified Chinese, zh-en code-switching, and translation/rewrite.
- **Private by default** — with no cloud key, everything runs on-device and offline.
- **China-friendly downloads** — optional `hf-mirror.com` mirror for model downloads.

## Install

1. Download `SaidDone.dmg` below.
2. Open it and drag **SaidDone** onto **Applications**.
3. First launch is blocked by Gatekeeper — allow it once:
   - **macOS 14:** right-click **SaidDone → Open → Open**.
   - **macOS 15+:** double-click, then **System Settings → Privacy & Security → "Open Anyway"**.
   - Or: `xattr -dr com.apple.quarantine /Applications/SaidDone.app`
4. Follow the Setup Assistant.

Full walkthrough: **[INSTALL.md](INSTALL.md)**.

## Requirements

- **Apple Silicon** Mac (M1 or later)
- **macOS 14 (Sonoma)** or later
- ~**3.8 GB** free disk for the default all-local models (Whisper turbo + Qwen3-4B), downloaded once

## Shortcuts

| Shortcut | Mode |
|---|---|
| `⌃⌥D` | Dictation |
| `⌃⌥T` | Translation |
| `⌃⌥R` | Rewrite selected text |

## Known limitations

- **Gatekeeper warning on first open.** The app is ad-hoc signed, not notarized (notarization needs a paid Apple Developer account). The one-time "Open Anyway" steps above are expected and safe for an open-source build.
- **First-run download is large (~3.8 GB)** for the all-local default. Use a smaller local model (Qwen3 1.7B/0.6B) or a cloud LLM to reduce it.
- **Local AI polish needs HuggingFace access.** On restricted networks, enable the `hf-mirror.com` mirror in the Setup Assistant.
- **Fully-local with the 4B model may exceed the ~2s end-to-end target** on shorter Macs. For the fastest path, use a cloud LLM for polish, or a smaller local model.
- If the small local model occasionally returns a degenerate result, SaidDone inserts your **raw (dictionary-corrected) transcript** instead — it never emits garbage and never loses your words.

## Building from source

```sh
git clone https://github.com/Chaoqi31/saiddone && cd saiddone
swift build && swift test
./scripts/release.sh   # build a shareable DMG (needs the Metal toolchain)
```

MIT licensed. Issues and PRs welcome.
