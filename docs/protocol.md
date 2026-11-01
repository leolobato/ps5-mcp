# PMCP wire protocol, version 1 (existing layouts frozen)

TCP port **9305** on the console. One client at a time. A second client gets `ERROR BUSY` and is closed.
Source of truth: `payload/protocol.h`. Python mirror: `src/ps5mcp/protocol.py`.

## Header (8 bytes, little-endian)

| Field | Size | Value |
|---|---|---|
| magic | 4 | `PMCP` |
| version | u8 | `1` |
| type | u8 | see below |
| length | u16 | payload bytes (≤ 256) |

A bad magic, an unknown version or an oversized length gets `ERROR` and closes the connection.

## Messages

| Type | Name | Direction | Payload |
|---|---|---|---|
| 1 | HELLO | server → client, on connect | `u16 protocol, u16 payload_version, i32 pad_handle, i32 user_id, u32 flags, u32 add_status` (20 B) |
| 2 | STATE | client → server | full pad state (28 B, below), answered by ACK; also server → client in reply to GET_STATE |
| 3 | PING | both | client: `u32 token`; server: `u32 token, u16 protocol, u16 payload_version, u64 uptime_ms, i32 pad_handle, u32 flags, u64 reports_sent, u32 report_failures, u32 neutral_events` (40 B) |
| 4 | ACK | server → client | `u32 seq, i32 status` (0 ok, >0 errno, <0 SCE error, 6 = no pad) |
| 5 | ERROR | server → client | `u32 code` + UTF-8 text. Codes: 1 bad magic, 2 bad version, 3 bad length, 4 unknown type, 5 busy, 6 no pad |
| 6 | SHUTDOWN | client → server | none. ACK with seq 0, then the pad is set neutral and removed, and padd exits |
| 7 | GET_STATE | client → server | none |
| 8 | COMMAND | client → server | `u32 seq, u32 op, char arg[32]`. Op 1 = go home (`arg` = method: `system`, `shellcore`, `suspend`), op 2 = launch title `arg`, op 3 = close the running game, op 4 = uninstall title `arg` (padd 1.3+, HELLO flag `0x8`; an id that is not 4 letters and 5 digits answers `EINVAL` (22), and the ACK comes once the console accepts the request. For a ShadowMountPlus title (`/user/app/<id>/mount.lnk`), padd first deletes its source through ShadowMountPlus and waits up to 6 s: `EBUSY` (16) and `EINPROGRESS` (36) mean retry, `ECONNREFUSED` (61) means ShadowMountPlus is not running, `EIO` (5) means it refused or cancelled the delete, `ENOTSUP` (45) means it has no source delete, and a failed delete job answers its own errno, such as `EACCES` (13); in all these cases the title stays installed). Op 5 = padd 1.5 only: give its one pad to `foreground`, `second` or a user id (HELLO flag `0x10`); padd 1.7 answers ERROR. Op 6 = second controller (padd 1.7+, HELLO flag `0x40`): `arg` = `connect` adds pad 2 for the second signed-in user (the first one in `sceUserServiceGetLoginUserIdList` that is not the foreground one) and does not select it; `connect <user id>` (decimal, padd 1.8+) adds it for that user, and for a user who is not signed in the console shows its sign-in picker with that user selected; already connected: 0, nothing changes; `ENOENT` (2): nobody else is signed in; `ENOSYS` (78): no sign-in list; another errno or SCE code: the add failed and nothing changes. `disconnect` releases and removes pad 2 and selects pad 1 (not connected: 0). `EINVAL` (22): another `arg`. Op 7 = select the pad STATE drives (padd 1.7+): `arg` = `1` or `2`; the other pad is released. `ENOENT` (2): that pad is not connected; `EINVAL` (22): another `arg`. Afterwards HELLO, PING, GET_USER and GET_STATE describe the selected pad. From padd 1.5, op 2 launches for the foreground user even while pad 2 is selected. Answered by ACK (ops added in padd 1.1, 1.3, 1.5 and 1.7 without a protocol change: unknown ops already answered ERROR) |
| 9 | GET_USER | both | Empty request; reply `i32 status, i32 user_id, char name[64]` (72 B). Name is the NUL-terminated UTF-8 local profile name for the user assigned to the pad (the selected pad's, padd 1.7). On lookup failure, status is nonzero and name is empty. Added in padd 1.2; clients request it only when HELLO flags include `0x4`. |
| 10 | GET_USERS | both | Empty request; reply `i32 status, i32 foreground`, then 4 × `{i32 user_id, char name[56]}` (248 B): the foreground user's id (-1 if unknown) and the signed-in users in `sceUserServiceGetLoginUserIdList` order, an empty slot `user_id` -1. A failed name lookup leaves that name empty. `status` is the list's: `ENOSYS` (78) when it is not available, and then every slot is empty. Added in padd 1.7; clients request it only when HELLO flags include `0x20`. |
| 11 | GET_PADS | both | Empty request; reply `u8 active, u8 reserved[3]`, then 2 × `{i32 handle, i32 user_id}` (20 B): the selected pad (1 or 2) and each pad's handle (-1: not connected) and user. Added in padd 1.7; clients request it only when HELLO flags include `0x40`. |

STATE payload: `u32 seq, u32 buttons, u8 lx, ly, rx, ry, u8 l2, r2, u8 reserved[2]`, then two touch points
`{u8 active, u8 id, u16 x, u16 y}`. Sticks rest at `0x80`. Button bits: `docs/vpad-abi.md`.

New optional messages may extend v1 when capability-gated; changing existing layouts requires a new protocol version.

Flags: `0x40` two pads supported, `0x20` signed-in users list supported, `0x10` pad user switch supported (padd 1.5 only), `0x8` uninstall supported, `0x4` user-name lookup supported, `0x1` pad ready, `0x2` touch coordinates unmapped (accepted but not delivered; the touchpad *click* button works).

## Timing and safety

- padd re-sends the current state to the pad every 8 ms, like a real controller.
- No STATE for 1 s: the state becomes neutral (`neutral` event, reason `watchdog`). Clients that hold input send
  the same state again every 100 ms or less.
- No bytes at all for 5 s: the client is dropped. Time padd spends running a COMMAND (a launch can block for
  seconds) does not count.
- Disconnect, SHUTDOWN, SIGTERM/SIGINT: neutral, then the pad is removed.
- The listening port is the single-instance lock. A second padd logs `already_running` and exits with code 3.
