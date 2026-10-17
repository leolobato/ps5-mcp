# PS button, home and app control

## Why the pad cannot send it

FGG-XSense tested all 16 unused bits of the button word and 17 unused report bytes on 11.60. None of them
reached the system as a PS-button press. The system handles the PS button above the virtual-pad layer, so this
project does not try to send it through the report.

## What padd does instead (verified on 13.60, padd 1.1)

padd calls system services directly from the payload process (`COMMAND` messages, `docs/protocol.md`). All of
these need `sceLncUtilInitialize()` first. Without it, LncUtil calls log `getAppStatus: 0x80940004`.

| Need | Call | Result on 13.60 |
|---|---|---|
| **Home from a game** (`home`, method `suspend`, the default) | `sceLncUtilGetAppIdOfRunningBigApp()`, then `sceLncUtilSuspendApp(app_id, 0)` | **Works.** Home screen shows, game suspended; Cross on its tile resumes it where it was. |
| Home (method `system`) | `sceSystemServiceNavigateToGoHome()` | Returns 0, **no visible effect** (from Settings and from a game). |
| Home (method `shellcore`) | `sceShellCoreUtilNavigateToGoHome()` | Returns 0, **no visible effect** from a game. |
| **Close the game** (`close_app`) | `sceLncUtilKillApp(app_id)` | **Works.** Game process gone, home screen shows. |
| **Launch by title id** (`launch`) | `sceLncUtilLaunchApp(title_id, NULL, &param)`, `param = {u32 size=32, u32 user_id, u32 app_opt=0, u64 crash_report=0, u32 check_flag}` | **Works with `check_flag = 0`**: the game started in the foreground. With `check_flag = 2` it started in the background (Cross on its tile brought it up). Homebrew FMGR88888 → `0x80940033`. |

The game takes input only from the side that launched it: after `launch`, the physical DualSense is ignored; after a
start from the physical controller, the virtual pad is ignored.

Return values: bit 31 set means an SCE error; any other value from LaunchApp is the new app id. The prototypes
match public headers (StubMaker `LncUtil.h`). The launch parameter layout and flag order come from zftpd (MIT),
which also reports 13.60 success. All imports are weak, so a missing one answers `ENOSYS`.

From system screens such as Settings, there is no running big app to suspend, so `home` does nothing. Circle
backs out of those screens instead. The MCP `home()` docstring says so.

MCP tools: `home(method)`, `close_app()`, `launch(title_id)`, `list_apps()` (lists `/user/app` through Web File
Manager). Keyboard: `H` goes home.

## Through Remote Play (13.60, implementation 2026-10-17)

When Remote Play is the video source, its session has a controller of its own, separate from padd's virtual
DualSense. That controller can send the PS button, and the session can fill the PS5 on-screen keyboard:

- `ps_button(hold_ms)` sets Chiaki's PS bit on the Remote Play controller, then releases it. A tap is expected to open
  the control center and a hold of about one second to go home (PS5 defaults).
- `type_text(text, submit)` and `close_keyboard(accept)` use Chiaki's keyboard messages: the console tells the client
  when a text field opens, the client replaces the field's text, the console echoes it, and the client can accept
  (close, keeping the text) or reject. Reject does not discard: the text stays and the PS5 shows its own keyboard.

The app window has the same controls for people: **PS** (click = tap, ⌥-click = one-second hold), the **P** key,
and **Type…** while the PS5 waits for a Remote Play keyboard. Window input ignores agent claims, like the other keys.

Verified on 13.60 (2026-10-17, worktree app, User1 session): the keyboard handshake did not change connection or
streaming; a 100 ms tap opened and closed the control center; a 1 s hold went home from Search (where padd's
`home` does nothing); `type_text` replaced the Search text and was echoed (`confirmed`), with and without submit;
reject showed the PS5's own keyboard with the text kept; padd input worked before and after. While the handshake is
on, a text field shows "Use the keyboard on your Remote Play device" in place of the PS5 keyboard.

This is a narrow exception to "padd is the only input route", not a migration: only these two inputs use the
Remote Play controller. The input is sent as the Remote Play user's controller (User1 on the test console). Whether
pressing PS there changes which controller a running game listens to is not yet measured; see the open items in
[Remote Play](remote-play.md#validation-status).

The pinned chiaki-ng is built in Release, so the `assert`s that check keyboard message lengths from the console
are compiled out. A malformed keyboard message from the paired console could make Chiaki read past its buffer. The
console is the authenticated peer, and Chiaki handles these messages whether or not the app enables the keyboard,
so enabling it does not add the exposure. The upstream code is unchanged here.

## Ruled out / not covered

- **The PS button itself, and the quick menu (control center), through padd.** The pad can't send the button
  (above); with Remote Play as the source, use `ps_button()`. No
  payload-callable service for the quick menu was found. `sceSystemServiceShowImposeMenuForPs2Emu` is
  PS2-emulator specific and was not tried. Without Remote Play, a short-press equivalent stays unavailable; the
  home and close commands cover going home and switching apps.
