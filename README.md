# SaidDone

Open-source, local-first voice-to-text for macOS — **said and done**. Press a hotkey, speak, and your words land at the cursor in any app, cleaned up and ready to use. An open-source alternative to paid cloud dictation tools (e.g. Typeless).

## Features

- **Three modes:** Dictation · Translation · **Rewrite** (speak an instruction to rewrite the selected text).
- **Local-first & private:** on-device ASR (WhisperKit, offline) — audio and text can stay on your Mac, no API key required.
- **Cloud is a co-equal option:** bring your own OpenAI-compatible key (e.g. DeepSeek) for top-quality polish/translation.
- **Smart polish:** punctuation, Simplified Chinese, auto bullet/paragraph structuring, filler removal, zh-en code-switching, subtitle-hallucination filtering, silence trimming.
- **Custom dictionary with auto-learn:** fix a word in History and the correction is learned for next time.
- **Personalization** (tell the AI your background/jargon), per-app tone (App Profile), and history you can search, edit, re-insert, export — with the original audio saved.
- **Polished app:** menu-bar + Dock, rebindable hotkeys, recording overlay (waveform + optional live preview), interaction sounds, mute-while-recording, launch-at-login, usage stats, onboarding.

## Install

### Download
1. Get `SaidDone.dmg` (build it with `./scripts/release.sh`, or from a Release).
2. Open the DMG and drag **SaidDone** to **Applications**.
3. First launch: right-click **SaidDone → Open → Open** (it's open-source and ad-hoc signed, so macOS asks once). Or: `xattr -dr com.apple.quarantine /Applications/SaidDone.app`.
4. Grant **Microphone** and **Accessibility** when prompted (Accessibility is needed to paste at the cursor).

### Build from source
```sh
swift build && swift test     # build + run tests
./scripts/install.sh          # build the app and install it to /Applications
```
Requires Xcode 26+ / Swift 6.2 on Apple Silicon. MLX-backed local models need the Metal toolchain: `xcodebuild -downloadComponent MetalToolchain`.

### Models
- Speech model (WhisperKit) downloads on first use — or from the **Setup** tab, or `./scripts/get-models.sh`.
- For a local MLX LLM: `./scripts/get-models.sh mlx-community/Qwen3-1.7B-4bit`, then pick it in **Settings → Providers**.

### Notarized distribution (optional — needs an Apple Developer account)
For a build strangers can open with no Gatekeeper prompt:
```sh
export DEVID="Developer ID Application: NAME (TEAMID)" APPLE_ID="…" TEAM_ID="…" APP_PW="…"
./scripts/notarize.sh
```

## Hotkeys

`⌃⌥D` Dictation · `⌃⌥T` Translation · `⌃⌥R` Rewrite — all rebindable in **Settings → General**.

## Cloud (optional, best quality)

**Settings → Cloud** → add an OpenAI-compatible key, then set the LLM (and/or ASR) location to **Cloud** in **Providers**. Example (DeepSeek): Base URL `https://api.deepseek.com`, model `deepseek-v4-flash`.

## License

[MIT](LICENSE).
