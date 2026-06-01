<div align="center">

<img src="assets/logo.png" width="116" alt="SaidDone logo" />

# SaidDone

**Local-first voice-to-text for macOS.**
Press a hotkey, speak, and polished text lands at your cursor — in any app.

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-6.2-f05138?logo=swift&logoColor=white)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-555)
![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen)

</div>

---

> [!NOTE]
> An open-source alternative to paid cloud dictation tools (Typeless, Wispr Flow). SaidDone runs **fully on-device by default** — your audio and text never leave your Mac, no API key required — and can use a cloud LLM (DeepSeek / any OpenAI-compatible endpoint) when you want top-quality polishing and translation.

## ✨ Features

- 🎙 **Dictation** `⌃⌥D` — speak in any app, get clean text at your cursor.
- 🌐 **Translation** `⌃⌥T` — speak one language, insert another.
- ✍️ **Rewrite** `⌃⌥R` — select text, say an instruction ("make it formal", "as bullet points") and it's rewritten in place.
- 🔒 **Private by default** — on-device WhisperKit ASR, works offline. Cloud is opt-in and per-stage.
- 🧹 **Smart polishing** — punctuation, Simplified Chinese, auto bullet/paragraph structuring, filler & repeat removal, zh-en code-switching, subtitle-hallucination filtering, silence trimming.
- 📖 **Custom dictionary with auto-learn** — fix a word once in History and it's corrected automatically next time.
- 🧠 **Personalization** — tell the AI your role/jargon (like ChatGPT custom instructions); per-app tone profiles.
- 🕘 **History** — search, edit, re-insert, export, with the original audio saved on device.
- 🪄 **Polished app** — menu-bar + Dock, rebindable hotkeys, recording overlay (waveform + optional live preview), usage stats, onboarding, launch-at-login.

## ⌨️ Shortcuts

| Shortcut | Mode | What it does |
|---|---|---|
| `⌃⌥D` | **Dictation** | Press to start, press again to finish & insert. No silence auto-stop. |
| `⌃⌥T` | **Translation** | Speak in any language → inserts the configured target language. |
| `⌃⌥R` | **Rewrite** | Speak an instruction to rewrite the currently selected text. |

All shortcuts are rebindable in **Settings → General**.

## 🚀 Install

### Download
1. Grab `SaidDone.dmg` (build it with `./scripts/release.sh`, or from a [Release](../../releases)).
2. Open the DMG and drag **SaidDone** into **Applications**.
3. First launch: right-click **SaidDone → Open → Open** (it's open-source & ad-hoc signed, so macOS asks once). Or run `xattr -dr com.apple.quarantine /Applications/SaidDone.app`.
4. Grant **Microphone** and **Accessibility** when prompted.

### Build from source
```sh
git clone https://github.com/Chaoqi31/saiddone && cd saiddone
swift build && swift test     # build + run tests
./scripts/install.sh          # build the app and install it to /Applications
```

> [!IMPORTANT]
> Requires **Xcode 26+ / Swift 6.2** on **Apple Silicon**. MLX-backed local models also need the Metal toolchain: `xcodebuild -downloadComponent MetalToolchain`.

## 🧠 Models & Providers

ASR and LLM are independent — pick local or cloud for each in **Settings → Providers**. Whatever you select is exactly what runs (no silent fallback).

### On-device (default, offline)

| Stage | Engine | Notes |
|---|---|---|
| **Speech → text** | WhisperKit `large-v3-turbo` | Downloads once; runs fully offline after. Set your primary language for best zh-en mixing. |
| **Polish / translate** | Rule-based, or MLX **Qwen3** (`mlx-community/Qwen3-1.7B/4B/8B-4bit`) | Bigger model → better punctuation & structuring. Get it via the **Setup** tab or `./scripts/get-models.sh`. |

### Cloud (optional, best quality)

Add an OpenAI-compatible key in **Settings → Cloud**, then set the provider's location to **Cloud**.

| Provider | Base URL | Example model |
|---|---|---|
| **DeepSeek** | `https://api.deepseek.com` | `deepseek-v4-flash` |
| **OpenAI** | `https://api.openai.com/v1` | `gpt-4o-mini` / `gpt-4o-transcribe` |
| Any OpenAI-compatible | your endpoint | your model |

> [!TIP]
> Best daily setup for Chinese users: **local WhisperKit ASR** (offline, fast) + **cloud DeepSeek** for polish/translate.

## ⚙️ How it works

```
hotkey (toggle) → capture audio → trim silence → ASR → custom dictionary
   → polish  ┃ Dictation
   → translate ┃ Translation        → insert at cursor (clipboard paste) → save to History
   → rewrite  ┃ Rewrite (selection)
```

Native Swift / SwiftUI. Three Swift targets: `SaidDoneCore` (pure pipeline logic, unit-tested), `SaidDoneProviders` (ASR/LLM engines), `SaidDoneApp` (menu-bar + window UI).

## 🔐 Permissions

| Permission | Why | If missing |
|---|---|---|
| **Microphone** | Record your voice | Can't capture audio |
| **Accessibility** | Paste text at the cursor (synthesised ⌘V) | Text is transcribed & saved to History, but won't auto-insert |

## 🛠 Development

```sh
swift test                 # 37 unit tests (pipeline, dictionary, config, providers…)
./scripts/bundle-xcode.sh  # build a runnable SaidDone.app (with MLX metallib)
./scripts/release.sh       # build a shareable DMG
./scripts/notarize.sh      # notarized DMG (needs an Apple Developer account)
```

Contributions welcome — open an issue or PR.

## 📄 License

[MIT](LICENSE).
