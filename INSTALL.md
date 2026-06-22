# Installing SaidDone

SaidDone is a menu-bar voice-to-text app for **Apple Silicon Macs running macOS 14 (Sonoma) or later**.

---

## 1. Download

Download **[SaidDone.dmg](https://github.com/Chaoqi31/saiddone/releases/latest/download/SaidDone.dmg)** from the latest [Release](../../releases).

<!-- screenshot: GitHub Releases page with SaidDone.dmg asset highlighted -->

## 2. Install

Open the DMG and **drag SaidDone onto the Applications folder** shown in the window.

<!-- screenshot: mounted DMG window — SaidDone icon + arrow + Applications shortcut + "READ ME FIRST" -->

## 3. First launch (allow it past Gatekeeper)

SaidDone is open-source and **ad-hoc signed, not notarized** (notarization needs a paid Apple Developer account). So the first open is blocked with *"Apple cannot verify…"*. This is expected — allow it **once**:

- **macOS 14 (Sonoma):** in Applications, **right-click SaidDone → Open**, then **Open** in the dialog.
- **macOS 15 (Sequoia) and later:** double-click SaidDone (it gets blocked), then go to **System Settings → Privacy & Security**, scroll down, and click **"Open Anyway"**. Confirm once more.
- **Terminal alternative (any version):**
  ```sh
  xattr -dr com.apple.quarantine /Applications/SaidDone.app
  ```
  then open the app normally.

<!-- screenshot: macOS 15 System Settings → Privacy & Security → "Open Anyway" button -->

After this one-time approval, SaidDone opens normally every time.

## 4. Setup Assistant

On first launch a **Setup Assistant** opens and walks you through everything:

1. **Welcome** — what SaidDone does and the system requirements.
2. **Permissions** — grant:
   - **Microphone** *(required)* — to hear your speech.
   - **Accessibility** *(recommended)* — to paste the result into the app you're typing in. Without it, results are still saved to History but won't auto-insert.
3. **Choose your engines** — independently pick where each stage runs:
   - **Speech → text (ASR):** Local (WhisperKit, on-device) or Cloud.
   - **AI polish (LLM):** Local (MLX Qwen3, on-device) or Cloud.
   - No cloud key? Keep both **Local** — that's the default.
4. **Set up** — download the local models (with progress), and/or enter and **test** your cloud API key.
5. **Try it** — record a sentence and confirm the whole pipeline works (this won't type anywhere).
6. **Done** — review the shortcuts and optionally enable launch-at-login.

<!-- screenshot: Setup Assistant "Choose your engines" step -->

You can re-run it any time from the menu-bar icon → **Setup Assistant…**

## 5. Models & download size

The default is **fully local** (private, offline, no API key):

| Stage | Default model | Size |
|---|---|---|
| Speech → text | WhisperKit `large-v3-turbo` | ~1.5 GB |
| AI polish | MLX `Qwen3-4B-4bit` | ~2.3 GB |

→ **~3.8 GB total, downloaded once.** They live in `~/Documents/huggingface/models/`.

**On a mainland-China network**, downloads from `huggingface.co` often stall. In the Setup Assistant's download step, turn on **"Use the China mirror (hf-mirror.com)"** and retry.

Prefer a smaller/faster local model? Pick **Qwen3 1.7B** or **0.6B** in the engines step (or later in **Settings → Providers**). Prefer top quality with a key? Choose **Cloud** for AI polish (e.g. DeepSeek) — best for Chinese day-to-day.

## 6. Use it

Click into any text field, then:

| Shortcut | Mode |
|---|---|
| `⌃⌥D` | **Voice Input** — speak, get clean text at your cursor |
| `⌃⌥T` | **Translation** — speak one language, insert another |
| `⌃⌥A` | **Ask Anything** — edit/query selected text, or ask a question |

Press once to start, press again to finish & insert. Everything is saved to **History** (searchable, editable, re-insertable).

---

## Troubleshooting

- **"SaidDone is damaged and can't be opened."** This is a quarantine flag, not real damage. Run `xattr -dr com.apple.quarantine /Applications/SaidDone.app` and reopen.
- **Model download stuck at 0% / very slow.** Enable the **hf-mirror.com** mirror in the Setup Assistant, or check your network/proxy.
- **Dictation transcribes but nothing is inserted.** Accessibility permission is off — grant it in **System Settings → Privacy & Security → Accessibility** (your text is still in History).
- **First polish is slow.** The model loads into memory on first use (one-time, per launch). The Setup Assistant warms it for you.
- **No audio captured / "未录到声音".** Check **System Settings → Sound → Input** (levels move when you speak). If using Bluetooth headphones, try built-in mic or toggle **Record from built-in mic** in Settings → General.

Requires **Apple Silicon** (M1 or later) and **macOS 14+**. Building from source additionally needs Xcode 26 / Swift 6.2 and the Metal toolchain — see the [README](README.md).
