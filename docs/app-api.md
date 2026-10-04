# PS5 app local API, version 1

The PS5 app (`build/PS5 MCP.app`, source in `app/`) owns the capture card and the only padd connection. Everything
else talks to it here. The Python client is `src/ps5mcp/hub.py`.

- **Socket:** `<state>/capture.sock` (state dir: `PS5MCP_STATE`, default `~/.local/state/ps5-mcp`), mode 0600.
  The old ps5-capture commands (`status`, `snapshot`, `show`, `hide`, `watch_change`, `quit`) work unchanged.
- **Framing:** one JSON object per line, both ways. Several clients can connect at once.
- **Requests:** `{"cmd": "...", "id": n, ...}`. `id` is optional. Every reply echoes it.
- **Replies:** `{"ok": true, ...}`, or `{"ok": false, "error": "text", "code": "..."}`. The codes are:
  `human_has_control`, `leased`, `not_connected`, `bad_request`, `pad_error`, `unknown_cmd`, `padd_busy`, `padd_unavailable`.
- **Events:** after `subscribe`, the app pushes `{"event": "...", ...}` lines. Events have no `id`.
- **Version:** `status` returns `"api": 1`.

Commands that can block run concurrently: `press`, `status`, `watch_change`, `command`, `ping`, `snapshot`,
`padd_start` and `padd_stop`. The other commands are answered in order on each connection.

## Pad state

The JSON fields carry raw protocol values (`docs/protocol.md`):

```json
{"buttons": 16384, "lx": 128, "ly": 128, "rx": 128, "ry": 128, "l2": 0, "r2": 0,
 "touch": [{"active": true, "id": 0, "x": 960, "y": 540}]}
```

- `buttons` is a bitmask, or a list of names such as `["cross", "up"]`.
- Fields you leave out are at rest. `touch` is optional.

## Input and merging

| cmd | fields | effect |
|---|---|---|
| `set` | `state`, `client?`, `wait?` | Sets this client's agent layer until it changes or the connection closes. Neutral clears it. |
| `press` | `state`, `hold_ms` (1..10000, default 80), `client?`, `wait?` (default 2) | Holds the state, releases it, waits the 60 ms release gap, then replies. |
| `release` | `client?` | Clears this client's layer. |
| `release_all` | | Clears every layer and every held key. |
| `key` | `key`, `down` | Keyboard input, the same path as the window (keymap below). |
| `state` | | Returns the merged state, the number of held keys and the agent layers. |

- **Layers:** each agent layer is keyed by connection and `client` (default `default`). The layers OR together, so
  several agents never get "busy".
- **Keyboard wins:** while any key is held, a non-neutral `set` or `press` fails with `human_has_control`. A key
  going down cancels every agent hold. When the last key is released, control goes back to the agents.
- **Taps:** a key tap shorter than 80 ms is stretched to 80 ms. A held key ignores auto-repeat.
- **Closing a connection** releases its layers and its held keys. Nothing else changes.
- **Link:** the app repeats the merged state every 100 ms (padd's watchdog is 1 s). After every (re)connect it resets
  all layers to neutral.
- **`wait`:** `set` and `press` wait up to `wait` seconds for the padd link, then fail with `not_connected`.

Keymap: arrows → D-pad; `enter`/`space` → Cross; `escape`/`backspace` → Circle; `[` `]` → Square, Triangle;
`q` `e` → L1, R1; `z` `c` → L2, R2; `wasd` → left stick; `ijkl` → right stick; `tab` → Options; `t` → touchpad
click; `h` → home (command).

## Sharing

One connection can claim the console; the others queue for it in order. Nobody has to claim: while the console is
free, every client drives it as before.

| cmd | fields | reply |
|---|---|---|
| `claim` | `reason`, `client?`, `idle_s?` (default 600, 10..3600) | Claims the console, or joins the queue. Claiming again keeps the place in the queue. |
| `unclaim` | | Gives up the claim or the place in the queue; `released` says whether there was one. |
| `lease` | | The lease as this connection sees it. |

- All three reply `granted`, `position` (0 = holder, n = nth in the queue, -1 = neither), `owner` (`client`,
  `reason`, `held_s`, `expires_in_s`, or null) and `queue` (`client`, `reason`, `waiting_s`). `status` has the same
  `owner` and `queue` under `lease`, and `status` events go out when they change.
- **Leased:** while another connection holds the claim, a non-neutral `set`, `press`, `command`, `padd_start` and
  `padd_stop` fail with `leased`. Neutral `set`, `release`, `release_all`, `key` and the read-only commands still work.
- **Lapses:** closing the connection gives up its claim. So do `idle_s` seconds without a request from the holder's
  connection. The next connection in the queue then gets the claim.
- **People win:** the keyboard, the window's buttons and auto-assign are never blocked. A held key still blocks the
  holder with `human_has_control`.

## Console

| cmd | fields | reply |
|---|---|---|
| `command` | `op`: `home` (`arg` = `suspend` (default), `system` or `shellcore`), `close`, `launch` (`arg` = title id) or `uninstall` (`arg` = title id; padd 1.3+) | `status`: padd's ACK status (0 ok, <0 SCE error) |
| `ping` | | `pong`: uptime, reports sent and failed, neutral events |
| `padd_start` | `firmware?` (default 13.60) | Pauses the link, runs `ps5mcp padd start` once, then resumes. Returns `status`, `run` (the `results/` dir), `exit` and `output`. |
| `padd_stop` | | The same flow, with `ps5mcp padd stop`. |

- `padd_start` deploys to the console. Nothing calls it on its own, and it never retries.
- The CLI writes the archive exactly as it does without the app.

## Frames and window

| cmd | fields | reply |
|---|---|---|
| `status` | `wait?` (seconds to wait for the padd link) | `pid`, `frames`, `frame_age`, `visible`, `now` (uptime clock = Python `time.monotonic`), `source`, `clients`, `pad` (link, hello, counters, `human_has_control`, `agent_layers`, `paused`), `title`, `notice`, `padd`, `auto_assign` |
| `snapshot` | | Writes `<state>/latest.jpg` now and returns `path` (it is also rewritten at 5 fps). |
| `watch_change` | `threshold` (6), `timeout_s` (2) | Two replies: `armed_at`, then `changed_at` and `diff`, or `ok: false` on timeout. |
| `show` / `hide` | | Shows or hides the window. |
| `quit` | | Releases input, drops the padd link (padd keeps running) and exits. |
| `subscribe` | `events`: `status`, `state` | `state` events are `{"t": uptime, "state": {...}}` for every change of the merged state. `status` events carry the `status` body. |

## Auto-assign

After every (re)connect the app looks for "Who's using this controller?" for 6 s. It presses Cross only when the
dialog is visible. The match uses the title template at (712, 168), within 24 px, with a score of at least 0.9, as
`assign.py` does. When it answers, `notice` says so, because answering turns the DualSense off
(see [findings](findings.md)). Disable it with `--no-auto-assign` or `PS5MCP_AUTO_ASSIGN=0`.

## Launch options

`"PS5 MCP" [--state-dir DIR] [--video NAME|file:PATH|synthetic] [--audio NAME|none] [--headless] [--host H] [--port N]
[--no-auto-assign] [--padd-cli EXE] [--snapshot-fps N]`

- The console address is `--host`, else `PS5_HOST`, else the address saved in Settings (UserDefaults key
  `consoleHost`). Saving in Settings also switches the running app to it.
- `--video file:PATH` (it re-reads the image when it changes) and `--video synthetic` run without the capture card.
  They are for development and tests.
- `PS5 --dialog-score IMAGE` prints the auto-assign match score and exits.
- `capture.NativeApp.start` launches the app. With the card it uses `open`, so macOS asks for camera and
  microphone permission for the app itself.
