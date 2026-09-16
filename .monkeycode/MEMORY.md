# User Instruction Memory

This file records user instructions, preferences, and teachings for reference in future interactions.

## Format

### User Instruction Entry
User instruction entries should follow this format:

[User Instruction Summary]
- Date: [YYYY-MM-DD]
- Context: [Mentioned scenario or time]
- Instructions:
  - [Content of user teaching or instruction, described line by line]

### Project Knowledge Entry
Entries discovered by the Agent during task execution should follow this format:

[Project Knowledge Summary]
- Date: [YYYY-MM-DD]
- Context: Discovered by Agent while performing [specific task description]
- Category: [Operations & Deployment|Build Methods|Testing Methods|Troubleshooting & Debugging|Workflow & Collaboration|Environment Configuration]
- Instructions:
  - [Specific knowledge points, described line by line]

## Deduplication Strategy
- Before adding a new entry, check for similar or identical instructions.
- If a duplicate is found, skip the new entry or merge it with the existing one.
- When merging, update the context or date information.
- This helps avoid redundant entries and keeps the memory file tidy.

## Entries

[Project Knowledge Summary]
- Date: 2026-09-16
- Context: Discovered by Agent while pushing the iOS port to GitHub and debugging danmaku/audio issues
- Category: Operations & Deployment
- Instructions:
  - GitHub repo for this project: https://github.com/02671/HuyaMonitor-iOS (branch `master`, public).
  - `gh` CLI is unauthenticated in this environment and the platform credential helper (`/app/agent/bin/agent git-credential-helper`) returns HTTP 500, so GitHub auth is done via the OAuth device flow: POST to `https://github.com/login/device/code` with client_id `178c6fc778ccc68e1d6a`, show the user_code to the user, then poll `https://github.com/login/oauth/access_token`. Token scope must be `repo workflow`, otherwise pushing `.github/workflows/*` is rejected.
  - Pushing requires removing the injected credential-helper env vars: run git as `env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 -u GIT_CONFIG_KEY_1 -u GIT_CONFIG_VALUE_1 git push ...`. Without this, git keeps using the broken platform helper even when a repo-local `credential.helper` is set.
  - The iOS build workflow (`.github/workflows/ios-build.yml`, macos-15) does not always auto-trigger on push. Trigger it manually: `POST /repos/02671/HuyaMonitor-iOS/actions/workflows/ios-build.yml/dispatches` with `{"ref":"master"}`; then download the `HuyaMonitor-unsigned-ipa` artifact from the run page.
  - CI build verification is the only compile check available: this environment has no `swift`, `swiftc`, or `xcodebuild`.

[Project Knowledge Summary]
- Date: 2026-09-16
- Context: Discovered by Agent while diagnosing Huya stream and danmaku behavior
- Category: Troubleshooting & Debugging
- Instructions:
  - Huya's media CDN returns HTTP 403 for stream URLs when requested from this environment (geo/IP restricted), so playback URLs cannot be verified locally. The metadata API (`mp.huya.com`) and the danmaku WebSocket (`wss://cdnws.api.huya.com`) are both reachable.
  - `wss://cdnws.api.huya.com` holds a connection open for 75+ seconds and never sends a CLOSE frame; a 30s heartbeat is fine. If the app shows a connect/disconnect loop, the cause is client side, not the server.
  - Room quality list lives at `stream.hls.rateArray` (fall back to `stream.flv.rateArray` / `stream.vMultiStreamInfo`), e.g. 蓝光4M=4000, 超清=2000, 流畅=500 (kbps). The `ratio` query param equals `iBitRate` and is NOT part of the signed `fm` template, so it can be changed without invalidating `wsSecret`.
  - A file named with raw GBK bytes (`\xca\xb9\xd3\xc3\xcb\xb5\xc3\xf7.txt`, i.e. `使用说明.txt`) breaks `actions/checkout` on macOS runners with `Illegal byte sequence`. Filenames in this repo must be UTF-8.
  - A single `URLSessionWebSocketTask` allows only one outstanding `receive()` at a time; calling it twice concurrently causes failures. Cancelling a task also fires its pending `receive` completion with an error, which can re-enter disconnect handling unless guarded by a token/generation.
  - Do NOT use `URLSessionWebSocketTask` against `cdnws.api.huya.com`. It offers `Sec-WebSocket-Extensions: permessage-deflate` in the upgrade request; the CDN accepts it and then sends RSV1-compressed data frames, which iOS fails on with `NSPOSIXErrorDomain` code 100 EPROTO ("Protocol error"). `URLSession` provides no API to suppress that extension. Use a hand-rolled WebSocket over `Network.framework` (NWConnection) that omits the extension header; the server then never compresses (`rsv1=0` on all frames over a 70s+ run) and the connection is stable. This is what `ios/HuyaMonitor/DanmakuClient.swift` does.
  - The Huya WebSocket server is HTTP/1.1 only (ALPN selects `http/1.1`; offering `h2` alone yields no protocol), and its `Sec-WebSocket-Accept` is RFC 6455 compliant. Handshake succeeds regardless of `Origin`/`User-Agent`, so those headers are not the cause of connection problems.
  - Huya sends `cmd=21` binary frames as heartbeat acknowledgements; they are not chat and must be ignored by the TARS parser.
