# PS button, home and app control

## The pad can send it

Bit `0x10000` of the virtual pad's button word is the PS button. A 100 ms tap through padd opened the control center, and the
frame after a second tap looked closed again (13.60, 2026-11-02, padd 1.8, Remote Play not used). No
padd change was needed, because padd passes the button word through. [AnyController](https://github.com/BallerIsLeet/AnyController)
(`include/sce_pad.h`) documents the same bit on 13.60, and [AnyPad](https://github.com/S-Mohammad-A/AnyPad-PS5-English) has a
PS button of its own on 10.01.

This replaces an earlier conclusion here, from FGG-XSense's tests on 11.60, that no unused bit of the report reaches the system.
That has not been rechecked on 11.60.

`press("ps")`, `hold`, `ps_button(hold_ms)`, the **P** key and the sidebar's **PS** button all use it, on the selected controller.

**A hold takes over control.** When another user owns the console, the pad's input is ignored, and pressing anything shows "To take
over control, press and hold the PS button" under the user the console assigned the pad to. A 1 s hold through padd took over: the
foreground user became that user and input worked again (13.60, 2026-11-02, padd 1.9). AnyPad reports the same priority behaviour.
A hold with no owner to take over from has not been tested, and neither has PS during a game.

**padd's user and the console's can differ.** After a padd update, a plain Cross on the focused profile gave controller 1 to
`leolobato-jb`, not the `User1` padd added the pad for, while HELLO and `status` still said `User1`. The app now steers controller 1
to its user's profile too. A person can still pick another profile; when the app asked them to answer, it reads the pick
and padd 1.10 records it (see [Auto-assign](app-api.md#auto-assign)). PS does nothing while "Who's using this controller?" is open: the console shows a blocked icon.

## Other ways to go home and control apps (verified on 13.60, padd 1.1)

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
DualSense. That controller can send the PS button (`rp_button` in the app's API, for older MCP servers) and the session can
fill the PS5 on-screen keyboard:

- `type_text(text, submit)` and `close_keyboard(accept)` use Chiaki's keyboard messages: the console tells the client
  when a text field opens, the client replaces the field's text, the console echoes it, and the client can accept
  (close, keeping the text) or reject. Reject does not discard: the text stays and the PS5 shows its own keyboard.

The app window has **Type…** while the PS5 waits for a Remote Play keyboard. Window input ignores agent claims, like the
other keys.

Verified on 13.60 (2026-10-17, worktree app, User1 session): the keyboard handshake did not change connection or
streaming; a 100 ms tap opened and closed the control center; a 1 s hold went home from Search (where padd's
`home` does nothing); `type_text` replaced the Search text and was echoed (`confirmed`), with and without submit;
reject showed the PS5's own keyboard with the text kept; padd input worked before and after. While the handshake is
on, a text field shows "Use the keyboard on your Remote Play device" in place of the PS5 keyboard.

This is a narrow exception to "padd is the only input route", not a migration: only these inputs use the
Remote Play controller. The input is sent as the Remote Play user's controller (User1 on the test console). Whether
pressing PS there changes which controller a running game listens to is not yet measured; see the open items in
[Remote Play](remote-play.md#validation-status).

The pinned chiaki-ng is built in Release, so the `assert`s that check keyboard message lengths from the console
are compiled out. A malformed keyboard message from the paired console could make Chiaki read past its buffer. The
console is the authenticated peer, and Chiaki handles these messages whether or not the app enables the keyboard,
so enabling it does not add the exposure. The upstream code is unchanged here.

## Ruled out / not covered

