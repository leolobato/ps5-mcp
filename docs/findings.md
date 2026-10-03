# Implementation findings

These findings were validated on PS5 firmware 13.60. The interface details are in
[Virtual-pad ABI](vpad-abi.md), [Wire protocol](protocol.md), and [App API](app-api.md).

## Virtual controller assignment

Creating the virtual pad shows “Who's using this controller?”. Until the virtual pad
answers with Cross, the console ignores its input. Matching the dialog title before
pressing Cross avoids sending input to unrelated screens; no SceShellCore patch is needed.

Assigning the virtual pad turns the physical DualSense off. Press its PS button and
select the same user again to use both controllers together. Dismissing the assignment
dialog leaves the virtual pad unusable.

## Input and cleanup

- The `/dev/hid` AddDevice, InsertData, and DeleteDevice ioctls work on 13.60.
  The user ID belongs in the device descriptor; no separate binding call is needed.
- An accepted report does not prove its layout is correct: the ioctl validates the
  request header. A zeroed report is also not neutral; centered sticks use `0x80`.
- Touch coordinates are accepted by the protocol but are not mapped to the console.
  The touchpad click button works.
- Killing the payload through Payload Manager can bypass device removal and leave
  a phantom controller until reboot. Stop it through the app or `ps5mcp padd stop`.
- Disconnects and the input watchdog release held input. Reconnecting starts neutral.

## Home and app control

The virtual-pad report cannot send the PS button or open the quick menu. Suspending
the running game, closing it, and launching a title work through system services.
The other Home methods returned success without visibly navigating home.
See [PS button and app control](ps-button.md) for calls, return values, and limitations.

Only the side that launched a game can control it. When the MCP launches a title (`launch`), the game takes input
from the virtual pad only and ignores the physical DualSense. When the physical controller starts it, the game ignores
the virtual pad. To drive a game through the MCP, launch it through the MCP.

## Payload Manager and Web File Manager

Two services on the console do the file work. **Payload Manager** (port 8084) keeps a library of ELF payloads:
`/manage:upload` adds one, `/list_payloads` lists them and `/loadpayload:<path>` runs one. `padd start` and
`ps5mcp install` (for `.elf`) use it. **PS5 Web File Manager** (port 8888, itself a payload) lists and transfers
files and installs packages. The app's game/app list and `ps5mcp install` (for `.pkg`) use it.

- Web File Manager runs one task at a time. `/api/download/prepare` and `/api/upload/prepare` create a task, and the
  task blocks every other call, `/api/list` included, with HTTP 409 "another task is running" until it is downloaded
  or finished with `/api/upload/finish`. Fetch files one at a time and always finish a prepared task.
- A missing file answers HTTP 404 with `ok: false`.
- `/api/install-pkg` (`paths`) installs a `.pkg` that is already on the console and runs as a `pkg_install` task.
- Neither service uninstalls apps. padd 1.3 does, with `sceAppInstUtilAppUnInstall` (COMMAND op 4). It returns
  once the request is accepted and the files go away afterwards; the console refuses while a game is running.
- ShadowMountPlus (API on 127.0.0.1:10101 only) marks its titles with `/user/app/<id>/mount.lnk` and installs them
  again from their source on its next scan, so a plain uninstall does not last. padd deletes the source first with
  ShadowMountPlus's `/api/v1/games/delete` job (it unmounts the title, refuses an image shared by several titles and
  holds the scanner), waits for the job, then uninstalls.
- ShadowMountPlus registers only `PPSA`, `CUSA` and `FAKE` title ids; a folder in `/data/homebrew` with any other id is
  ignored. A new `FAKE` folder there is registered within about 10 s.
- Verified on 13.60: a `.pkg` installs through `ps5mcp install` (Web File Manager upload, then `/api/install-pkg`),
  and both a regular title and a ShadowMountPlus title uninstall through padd and stay uninstalled.
- Game names are in `/user/appmeta/<id>/param.json` (`localizedParameters`); the icon is `icon0.png`. System apps
  and homebrew may have no `appmeta`.

## macOS capture

Only one process can own the capture card, so the native app owns both capture and
the payload connection. Agents and keyboard input share that app through its local API.
Video uses `AVCaptureVideoPreviewLayer`; audio uses `AVCaptureAudioPreviewOutput`.

HDCP must be disabled. Launching the signed bundle through `open` gives the app its
own camera and microphone permissions. The ffmpeg fallback needs terminal permissions;
a daemonized terminal session may never show the permission prompt.
