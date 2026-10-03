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

## Ruled out / not covered

- **The PS button itself, and the quick menu (control center).** The pad can't send the button (above). No
  payload-callable service for the quick menu was found. `sceSystemServiceShowImposeMenuForPs2Emu` is
  PS2-emulator specific and was not tried. A short-press equivalent stays unavailable; the home and close
  commands cover going home and switching apps.
