# SaidDone v2.0.0

SaidDone 2 is a rewrite. It adds the `fn` key, hands-free and hold-to-talk recording, a durable history with retry, and a dictionary that learns from your corrections.

## New

- **The `fn` key.** `fn` starts Voice Input, `fn` `⇧` Translation, and `fn` `⌃` Ask Anything. `⌃⌥D`, `⌃⌥T` and `⌃⌥A` still work.
- **Tap or hold.** Tap a shortcut to talk hands-free, or hold it and let go to finish. While holding `fn`, add `⇧` or `⌃` to switch modes.
- **Any shortcut.** Each mode takes several shortcuts: `fn` combinations, right-side modifier keys, key combinations, function keys, and mouse buttons.
- **No waiting.** A new recording can start while the previous one is processing. Results arrive in order.
- **Durable history.** Each recording is saved with its audio before any engine runs. A crash, quit or network failure keeps it, and **Run Again** processes it later.
- **A dictionary that learns.** When you fix a word right after SaidDone types it, the fix is added. Words you add can list the ways they get misheard. CSV import and export.
- **Better on-device recognition of your words.** Dictionary terms reach Whisper as a sentence in the language you speak, which fixes terms like "bug" without breaking punctuation or switching Chinese to Traditional characters.
- **Voice bar.** Shows the live level, the elapsed time, the processing stage, and what happened, with **Retry** and **Copy text** when a job fails.
- **Ask Anything answers** open in a floating panel with **Copy** and **Insert**. Spoken searches, such as "search swift actors on YouTube", open the results page.
- **Stats.** Words dictated, typing time saved, and words per minute.
- **Engines.** OpenAI GPT-5.6 and `gpt-transcribe`, DeepSeek `deepseek-flash`, Zhipu GLM-5.2, Volcengine (Doubao) speech with a single API key, and a **Test** button for each engine.
- **Interface language** switches between English and Simplified Chinese without a restart.
- **Mute other audio** while recording, and a Bluetooth headset no longer drops to call quality: **Automatic** uses the Mac's own microphone instead.

## Changed

- Models now live in `~/Library/Application Support/SaidDone/Models`, next to history and settings.
- API keys are stored in one Keychain item, so macOS asks at most once after an update.
- **Show in Dock** is on by default.
- History keeps failed entries for at least a day, whatever the retention setting.

## Removed

- Fast draft insertion, voice commands, settings export and import, editing and reinserting history entries, and the AI timeout setting. SaidDone sets the AI time limit from the recording's length.
- Reading keys from a `.env` file.
- Migration from 1.x. See the [upgrade notes](INSTALL.md#upgrade-from-saiddone-1x).
