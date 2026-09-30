# How to install and set up SaidDone

SaidDone needs an Apple silicon Mac (M1 or later) with macOS 14 or later.

## Install the app

1. Download [SaidDone.dmg](https://github.com/Chaoqi31/saiddone/releases/latest/download/SaidDone.dmg) from the latest release.
2. Open the DMG and drag **SaidDone** onto the **Applications** folder in the same window.

## Open it the first time

SaidDone is ad-hoc signed, not notarized, so macOS blocks the first open with "Apple cannot verify…". Allow it once:

- On macOS 14, right-click **SaidDone** in Applications, choose **Open**, then click **Open**.
- On macOS 15 or later, double-click **SaidDone**. Then open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.
- On any version, you can run this in Terminal instead, then open the app normally:

  ```sh
  xattr -dr com.apple.quarantine /Applications/SaidDone.app
  ```

After that, SaidDone opens like any other app.

## Follow the Setup Assistant

The Setup Assistant opens on first launch. To run it again later, open **Settings → General** and click **Setup Assistant…**.

1. **Welcome.** Choose the interface language and the language you speak. If you mix English words into Chinese, keep Chinese: SaidDone handles the mix.
2. **Allow access.**
   - Click **Allow** next to **Microphone**.
   - Click **Allow** next to **Accessibility**. macOS opens System Settings. Turn on **SaidDone** in the list, then come back. The shortcuts and pasting both need this.
   - To use `fn` alone, click **Open Keyboard Settings** and set **Press 🌐 key to** to **Do Nothing**. Otherwise pressing `fn` also switches input sources or shows emoji.
3. **Choose your engines.** The defaults are on-device Whisper for speech and DeepSeek for the AI.
   - Click **Download** next to the speech model. You can continue while it downloads.
   - Paste your DeepSeek API key, or click **Get a Key** to create one. To avoid keys entirely, set the AI engine to **On this Mac** and download Qwen3 4B.
   - Click **Test** to check an engine end to end.
4. **Your shortcuts.** Keep the defaults, or click **Add Shortcut…** and press the keys or mouse button you want.
5. **Try it.** Click in the text box, press `fn`, say a sentence, and press `fn` again. The text appears in the box. Then click **Done**.

The first time a model loads, macOS prepares it for your Mac, which takes a few minutes. SaidDone starts this as soon as the download finishes, and later launches load in seconds.

## Dictate anywhere

Click into any text field in any app, then:

| Shortcut | Mode |
|---|---|
| `fn` or `⌃⌥D` | **Voice Input**: speak, and polished text appears at your cursor. |
| `fn` `⇧` or `⌃⌥T` | **Translation**: speak any language, and the translation appears. |
| `fn` `⌃` or `⌃⌥A` | **Ask Anything**: select text first and say what to change, or ask a question. |

Tap a shortcut to talk hands-free and tap it again to finish, or hold it while you talk and let go. Press `Esc` to cancel.

## Download models from mainland China

If a download stalls, open **Settings → Speech & AI**, turn on **Download models through hf-mirror.com**, and click **Download** again. To send cloud requests through your VPN app, turn on **Use a proxy for cloud services** and enter its host and port, such as `127.0.0.1` and `7890`.

## Fix common problems

- **"SaidDone is damaged and can't be opened."** This is the download quarantine flag, not damage. Run `xattr -dr com.apple.quarantine /Applications/SaidDone.app` and open it again.
- **Pressing the shortcut does nothing.** Accessibility is off. Open **System Settings → Privacy & Security → Accessibility** and turn on SaidDone. If it is already on after an update, turn it off and on again.
- **The text was copied instead of typed.** You switched apps before it finished, or the cursor was not in a text field. Press `⌘V` to paste it. The text is also in **History**.
- **Nothing was heard.** Open **Settings → Microphone** and watch the input level while you speak. With AirPods or another Bluetooth headset, **Automatic** records from the Mac's own microphone on purpose; pick the headset there if you want it.
- **A job failed.** The voice bar shows why, with **Retry**. Every failed recording stays in **History** for at least a day, where **Run Again** processes it with your current engines.

## Upgrade from SaidDone 1.x

SaidDone 2 starts fresh and does not read 1.x settings, history or models. Run the Setup Assistant, enter your API keys again, and download the models again. The 1.x models in `~/Documents/huggingface` can be deleted.
