<div align="center">

<img src="assets/logo.png?v=2" width="116" alt="SaidDone logo" />

# SaidDone

**AI voice-to-text for macOS — cloud-quality by default, fully local when you want it.**

Press a hotkey, speak, and polished text lands at your cursor — in any app.

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/Chaoqi31/saiddone/actions/workflows/ci.yml/badge.svg)](https://github.com/Chaoqi31/saiddone/actions/workflows/ci.yml)
![Platform](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-6.2-f05138?logo=swift&logoColor=white)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-555)
![Tests](https://img.shields.io/badge/tests-100%2B%20passing-brightgreen)

<br />

[![Download SaidDone for macOS](https://img.shields.io/badge/Download-SaidDone.dmg-007AFF?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/Chaoqi31/saiddone/releases/latest/download/SaidDone.dmg)

<br />

[Latest release notes](https://github.com/Chaoqi31/saiddone/releases/latest) · [Install guide](INSTALL.md)

</div>

---

> [!NOTE]
> An open-source alternative to paid cloud dictation tools (Typeless, Wispr Flow). Setup Assistant defaults to a cloud provider (DeepSeek or any OpenAI-compatible endpoint) for the most reliable transcription and polish. Switch any stage to fully on-device in Settings — your audio and text never leave your Mac, no API key required, works offline. Typeless has no equivalent to that path at all.

## Features

| | |
|---|---|
| **Voice Input** `⌃⌥D` | Speak in any app; get clean text at your cursor. |
| **Translation** `⌃⌥T` | Speak one language; insert another. |
| **Ask Anything** `⌃⌥A` | Select text and speak an instruction, or ask a question — like Typeless. |
| **Local/private path** | On-device WhisperKit ASR + MLX Qwen run offline after model download. Cloud is explicit and per-stage. |
| **Faithful polishing** | Punctuation, Simplified Chinese, filler removal, **context-aware zh-en ASR fixes**, subtitle-hallucination filtering, silence trimming — cleans up what you said without rewriting or inventing. |
| **Custom dictionary** | Fix a word once in History; it's corrected automatically next time. |
| **Personalization** | User profile + per-app tone profiles (like ChatGPT custom instructions). |
| **History** | Search, edit, re-insert, export — with original audio saved on device. |
| **Polished UX** | Setup Assistant, bilingual UI (中文 / English), menu-bar + Dock, rebindable hotkeys (keyboard **or mouse side buttons**), recording overlay with 0→1 progress, launch-at-login, VoiceOver support. |
| **Fast dictation** | Optional: insert the ASR draft immediately, then swap in the polished text when ready. |

**v1.2 highlights:** safer fast-draft replacement · faster one-pass translation · resilient History persistence · warm provider reuse.

## Shortcuts

| Shortcut | Mode | Behavior |
|---|---|---|
| `⌃⌥D` | Voice Input | Press to start, press again to finish and insert. |
| `⌃⌥T` | Translation | Speak in any language → inserts the configured target language. |
| `⌃⌥A` | Ask Anything | Edit/query selected text, or ask a question with no selection. |

All shortcuts are rebindable in **Settings → General**.

## Install

### Download

**[⬇ Download SaidDone.dmg](https://github.com/Chaoqi31/saiddone/releases/latest/download/SaidDone.dmg)** (Apple Silicon · macOS 14+)

1. Open the DMG and drag **SaidDone** onto **Applications**.
2. First launch is blocked by Gatekeeper (open-source builds are ad-hoc signed, not notarized). Allow it **once**:
   - **macOS 14 (Sonoma):** right-click **SaidDone → Open → Open**.
   - **macOS 15 (Sequoia):** double-click it, then **System Settings → Privacy & Security → "Open Anyway"**.
   - Or in Terminal: `xattr -dr com.apple.quarantine /Applications/SaidDone.app`
3. The **Setup Assistant** opens automatically — grants Microphone + Accessibility permissions, lets you pick local/cloud engines, and downloads models.

See **[INSTALL.md](INSTALL.md)** for the full walkthrough.

### Build from source

```sh
git clone https://github.com/Chaoqi31/saiddone && cd saiddone
swift build && swift test     # build + run 100+ unit tests
./scripts/install.sh          # build the app and install to /Applications
```

> [!IMPORTANT]
> Requires **Xcode 26+ / Swift 6.2** on **Apple Silicon**. MLX-backed local models also need the Metal toolchain:
>
> ```sh
> xcodebuild -downloadComponent MetalToolchain
> ```

## Models and providers

ASR and LLM are independent — pick local or cloud for each in **Settings → Providers**. Whatever you select is exactly what runs (no silent fallback).

### Cloud (default, most reliable)

Pick a provider and add its key in **Settings → Cloud** (stored in Keychain), then set the stage's location to **Cloud**. 11 built-in OpenAI-compatible providers ship in the picker (DeepSeek, OpenAI, Moonshot, Zhipu, SiliconFlow, Groq, Cerebras, xAI, OpenRouter, Ollama, LM Studio), and the Base URL/model fields stay editable for compatible endpoints.

| Provider | Base URL | Example model |
|---|---|---|
| **DeepSeek** | `https://api.deepseek.com` | `deepseek-chat` |
| **OpenAI** | `https://api.openai.com/v1` | `gpt-4o-mini` / `gpt-4o-transcribe` |
| Any OpenAI-compatible | your endpoint | your model |

### On-device (optional, offline, zero-key)

| Stage | Engine | Notes |
|---|---|---|
| **Speech → text** | WhisperKit `large-v3-turbo` | Downloads once; runs fully offline after. Set your primary language for best zh-en mixing. |
| **Polish / translate** | MLX **Qwen3** (`0.6B` / `1.7B` / `4B` / `8B` 4-bit, default **4B**) | Always an AI model, never plain rules. Bigger → better Chinese and structuring. |

First all-local run downloads **~3.8 GB once** (Whisper turbo ~1.5 GB + Qwen3-4B ~2.3 GB). Models live in `~/Documents/huggingface/models/`. On-device models are smaller and can mishear technical terms or mixed-language speech more often than cloud — see [ADR-0007](docs/adr/0007-cloud-default-local-optional.md).

> [!TIP]
> On a mainland-China network, enable the **hf-mirror.com** mirror in the Setup Assistant if downloads stall.

## How it works

```
hotkey (toggle) → capture audio → trim silence → ASR → custom dictionary
   → polish  ┃ Voice Input
   → translate ┃ Translation        → insert at cursor (⌘V paste) → save to History
   → ask       ┃ Ask Anything
```

If a Mode's AI operation exceeds your **AI step timeout** (Settings → General, default 8 s), SaidDone shows a timeout instead of silently inserting stale text. With fast dictation enabled, the already-inserted ASR draft stays in place so your words are not lost.

## Architecture

Native Swift / SwiftUI, three targets:

| Target | Role |
|---|---|
| `SaidDoneCore` | Pipeline, dictionary, config, history — pure logic, heavily unit-tested |
| `SaidDoneProviders` | ASR/LLM engines (WhisperKit, MLX, cloud) |
| `SaidDoneApp` | Menu-bar shell: capture, hotkeys, insertion, UI |

## Permissions

| Permission | Why | If missing |
|---|---|---|
| **Microphone** | Record your voice | Can't capture audio |
| **Accessibility** | Paste text at the cursor (synthesised ⌘V) | Text is transcribed and saved to History, but won't auto-insert |

## Development

```sh
swift test                 # 100+ unit tests (core pipeline, providers, app-layer)
./scripts/bundle.sh        # fast runnable SaidDone.app for day-to-day dev
./scripts/bundle-xcode.sh  # full SaidDone.app with MLX metallib
./scripts/release.sh       # build a shareable DMG
./scripts/notarize.sh      # notarized DMG (needs an Apple Developer account)
```

**Releases:** push a version tag (`git tag v1.2.0 && git push origin v1.2.0`) — GitHub Actions builds `SaidDone.dmg` and attaches it to the Release automatically.

Contributions welcome — open an issue or PR.
