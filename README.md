# SaidDone

Open-source, local-first voice-to-text for macOS — **said and done**. Press a hotkey, speak, and your words land at the cursor in any app, cleaned up and ready to use. Open-source alternative to paid cloud dictation tools (e.g. Typeless).

- **Local-first, private, offline, zero-key.** A fully on-device path is guaranteed — audio and text never leave your Mac, no API key required. (See [ADR-0001](docs/adr/0001-local-cloud-coequal-providers.md).)
- **Cloud is a co-equal option, not an afterthought.** Bring your own key for max-quality polish/translation when you want it.
- **Modes:** Dictation (transcribe + local polish, handles zh-en code-switching), Translation (speak one language → insert another), Custom Dictionary, per-app tone (App Profile).

## Status

v1 in progress. Core pipeline + menu-bar app skeleton implemented and unit-tested. See [GOALS.md](GOALS.md) for the success criteria and [ARCHITECTURE.md](ARCHITECTURE.md) for the design.

## Architecture (short)

```
hotkey (toggle) → capture audio → ASR Provider → Custom Dictionary
  → Polish [Dictation] / Polish→Translate [Translation]  → Insert at cursor (clipboard paste)
```

- **Default local engines:** Qwen3-ASR-1.7B (MLX) for speech, Qwen3.5-0.8B (MLX) for polish/translate, WhisperKit (large-v3-turbo) as the speed/compatibility fallback. (ADR-0003/0004)
- **Stack:** native Swift / SwiftUI, Apple Silicon, macOS 14+. (ADR-0002)

Full docs: [GOALS.md](GOALS.md) · [CONTEXT.md](CONTEXT.md) · [ARCHITECTURE.md](ARCHITECTURE.md) · [docs/adr/](docs/adr/)

## Build

```sh
swift build      # build core + app
swift test       # run unit tests
./scripts/bundle.sh   # package a runnable SaidDone.app (menu-bar)
```

Requires Xcode 26+ / Swift 6.2, Apple Silicon.

## License

[MIT](LICENSE).
