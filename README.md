<div align="center">

<img src="assets/logo.png?v=2" width="116" alt="SaidDone logo" />

# SaidDone

**Talk instead of typing, in any Mac app.**

Press fn, speak, and clean, punctuated text appears at your cursor.

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/Chaoqi31/saiddone/actions/workflows/ci.yml/badge.svg)](https://github.com/Chaoqi31/saiddone/actions/workflows/ci.yml)
![Platform](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Apple silicon](https://img.shields.io/badge/Apple%20silicon-required-555)

<br />

[![Download SaidDone for macOS](https://img.shields.io/badge/Download-SaidDone.dmg-007AFF?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/Chaoqi31/saiddone/releases/latest/download/SaidDone.dmg)

[Install guide](INSTALL.md) · [Release notes](RELEASE_NOTES.md)

</div>

---

SaidDone is a free, open-source alternative to Typeless and Wispr Flow. Speech recognition and the AI that tidies your words are chosen separately: run either one on your Mac, where nothing leaves it, or on a cloud service with your own key.

## What it does

| Mode | Default shortcut | What you get |
|---|---|---|
| **Voice Input** | `fn` or `⌃⌥D` | What you said, with filler words, false starts and self-corrections removed, and punctuation fixed. |
| **Translation** | `fn` `⇧` or `⌃⌥T` | What you said, translated into your target language. |
| **Ask Anything** | `fn` `⌃` or `⌃⌥A` | Select text and say what to do with it ("make this more formal"), or ask a question and read the answer in a floating panel. "Search swift actors on YouTube" opens the results page. |

Every shortcut works two ways:

- **Tap** it, talk hands-free, and tap it again to finish.
- **Hold** it while you talk, and let go to finish.

While holding `fn`, add `⇧` or `⌃` to switch to Translation or Ask Anything. `Esc` cancels. You can start the next recording while the last one is still processing; results arrive in order.

Also included:

- **History.** Every recording is saved with its audio before any engine runs, so a crash, a quit or a network failure never loses what you said. Failed entries keep their recording and can run again. Search, copy, and filter by mode.
- **Dictionary.** Add names and jargon SaidDone gets wrong, with the ways it mishears them. When you fix a word right after SaidDone types it, SaidDone learns the fix. CSV import and export.
- **Personalization.** Describe yourself ("iOS developer, I mix English tech terms into Chinese"), set a default tone, and give specific apps their own tone.
- **Stats.** Words dictated, typing time saved, and speaking pace.
- **Shortcuts your way.** Any mode can have several shortcuts: `fn` combinations, right-side modifier keys, key combinations, function keys, or mouse buttons.
- **English and Simplified Chinese interface.** It switches instantly, without a restart.

## Engines

Pick an engine for each half in **Settings → Speech & AI**. What you pick is what runs; SaidDone never switches engines behind your back.

| | On your Mac | Cloud, with your key |
|---|---|---|
| **Speech recognition** | Whisper large-v3 turbo (1.64 GB, recommended), turbo compact (646 MB), large-v3 (3.09 GB) | OpenAI, Groq, SiliconFlow, Volcengine (Doubao), or any OpenAI-compatible endpoint |
| **AI** | Qwen3 4B (2.28 GB, recommended), 1.7B, 8B | DeepSeek (default), OpenAI, Zhipu GLM, Moonshot Kimi, SiliconFlow, OpenRouter, Groq, Ollama, LM Studio, or any OpenAI-compatible endpoint |

The default setup is on-device Whisper for speech and DeepSeek for the AI, which needs a DeepSeek API key. For a setup with no key at all, choose **On this Mac** for both halves.

On-device models download once from Hugging Face. Where Hugging Face is slow or blocked, turn on **Download models through hf-mirror.com**. Cloud requests can go through an HTTP proxy.

## Privacy

- With both halves on your Mac, your audio and text never leave it, and SaidDone works offline.
- A cloud speech engine receives your audio. A cloud AI receives the transcript, your dictionary terms, your personalization text, and, in Ask Anything, the text you selected.
- History, the dictionary and settings stay in `~/Library/Application Support/SaidDone`. API keys are in the Keychain.
- SaidDone reads another app's text field in two cases only: the selection you ask about, and the field it just typed into, for 20 seconds, to learn your corrections. **Learn from my corrections** turns the second off.

## Install

1. Download [SaidDone.dmg](https://github.com/Chaoqi31/saiddone/releases/latest/download/SaidDone.dmg) and drag **SaidDone** into **Applications**.
2. Open it. The first time, macOS asks you to confirm an app from the internet; [INSTALL.md](INSTALL.md) shows how.
3. Follow the Setup Assistant: permissions, engines, shortcuts, and a first dictation.

SaidDone needs an Apple silicon Mac with macOS 14 or later.

## Build from source

```sh
git clone https://github.com/Chaoqi31/saiddone && cd saiddone
scripts/test.sh          # run the tests
scripts/install.sh       # build SaidDone.app and copy it to /Applications
```

You need a Swift 6 toolchain: Xcode, or only the Command Line Tools. On-device AI runs on MLX, whose Metal shaders only Xcode compiles. `scripts/bundle.sh` uses Xcode when its Metal toolchain is installed:

```sh
xcodebuild -downloadComponent MetalToolchain
```

A build made with only the Command Line Tools runs everything except on-device AI, and says so in the app.

## How it works

```
shortcut → record → trim silence → speech engine → remove hallucinated phrases → dictionary
        → AI: polish (Voice Input), translate (Translation), or edit and answer (Ask Anything)
        → paste at the cursor, or copy if you switched apps → History
```

The code is three layers:

| Target | Role |
|---|---|
| `SaidDoneCore` | Pure logic with no dependencies: the shortcut recognizer, the recording and job state machine, prompts and reply parsing, the pipeline, the dictionary, history and settings types. |
| `SaidDoneEngines` | Speech and AI engines behind two protocols: WhisperKit, MLX, OpenAI-compatible cloud APIs, and Volcengine. Also model downloads and audio encoding. |
| `SaidDoneApp` | The menu-bar app: the keyboard tap, microphone, pasting, stores, and every window. |

`saiddone-cli` runs the real engines on an audio file, without the microphone or the app:

```sh
swift run saiddone-cli download whisper
SAIDDONE_KEY_DEEPSEEK=sk-... swift run saiddone-cli run memo.m4a --terms "Vercel,SaidDone"
```

## Development

| Command | What it does |
|---|---|
| `scripts/test.sh` | Runs the Swift Testing suite, including with only the Command Line Tools. |
| `SAIDDONE_UI=1 scripts/test.sh --filter RenderTests` | Draws every screen in English and Chinese to `/tmp/saiddone-render`. |
| `scripts/e2e.sh` | Speaks three sample sentences with macOS voices and runs them through the real engines. |
| `scripts/bundle.sh [debug]` | Builds `dist/SaidDone.app`. |
| `scripts/release.sh` | Builds `dist/SaidDone.dmg`, ad-hoc signed. |
| `scripts/notarize.sh` | Builds a notarized DMG with a Developer ID. |

To release, push a version tag, such as `git tag v2.0.0 && git push origin v2.0.0`. GitHub Actions builds the DMG and attaches it to the release.

Issues and pull requests are welcome.
