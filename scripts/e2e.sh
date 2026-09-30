#!/usr/bin/env bash
# End-to-end check without the microphone or the UI: macOS voices speak three sample sentences, and each one runs
# through the real engines with saiddone-cli, printing what was heard and what would be typed.
#
#   scripts/e2e.sh                                          # on-device Whisper + DeepSeek (SAIDDONE_KEY_DEEPSEEK)
#   scripts/e2e.sh --speech whisper:compact --ai ollama:qwen3   # any `saiddone-cli run` options
#
# Needs the Tingting and Samantha voices (System Settings → Accessibility → Spoken Content) and, for on-device
# speech, a downloaded model: `swift run saiddone-cli download whisper`.
set -euo pipefail
cd "$(dirname "$0")/.."

CLIPS="$(mktemp -d)"
trap 'rm -rf "$CLIPS"' EXIT
say -v Tingting -o "$CLIPS/list.aiff" "嗯，我今天要做的事情，首先修复登录页面的 bug，然后写单元测试，最后把新版本部署到生产环境。"
say -v Tingting -o "$CLIPS/meeting.aiff" "那个，我们明天下午三点开会，讨论一下 API 的设计，呃，不对，改成四点吧。"
say -v Samantha -o "$CLIPS/english.aiff" "Um, so I think we should, like, move the meeting to Friday. Actually no, let's do Monday morning instead."

swift build --product saiddone-cli
for clip in "$CLIPS"/*.aiff; do
  echo "== $(basename "$clip" .aiff)"
  .build/debug/saiddone-cli run "$clip" --terms "API,bug" "$@" || true
done
