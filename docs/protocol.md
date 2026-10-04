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
| 8 | COMMAND | client → server | `u32 seq, u32 op, char arg[32]`. Op 1 = go home (`arg` = method: `system`, `shellcore`, `suspend`), op 2 = launch title `arg`, op 3 = close the running game, op 4 = uninstall title `arg` (padd 1.3+, HELLO flag `0x8`; an id that is not 4 letters and 5 digits answers `EINVAL` (22), and the ACK comes once the console accepts the request. For a ShadowMountPlus title (`/user/app/<id>/mount.lnk`), padd first deletes its source through ShadowMountPlus and waits up to 6 s: `EBUSY` (16) and `EINPROGRESS` (36) mean retry, `ECONNREFUSED` (61) means ShadowMountPlus is not running, `EIO` (5) means it refused or cancelled the delete, `ENOTSUP` (45) means it has no source delete, and a failed delete job answers its own errno, such as `EACCES` (13); in all these cases the title stays installed). Answered by ACK (ops added in padd 1.1 and 1.3 without a protocol change: unknown ops already answered ERROR) |
| 9 | GET_USER | both | Empty request; reply `i32 status, i32 user_id, char name[64]` (72 B). Name is the NUL-terminated UTF-8 local profile name for the user assigned to the pad. On lookup failure, status is nonzero and name is empty. Added in padd 1.2; clients request it only when HELLO flags include `0x4`. |

STATE payload: `u32 seq, u32 buttons, u8 lx, ly, rx, ry, u8 l2, r2, u8 reserved[2]`, then two touch points
`{u8 active, u8 id, u16 x, u16 y}`. Sticks rest at `0x80`. Button bits: `docs/vpad-abi.md`.

New optional messages may extend v1 when capability-gated; changing existing layouts requires a new protocol version.

Flags: `0x8` uninstall supported, `0x4` user-name lookup supported, `0x1` pad ready, `0x2` touch coordinates unmapped (accepted but not delivered; the touchpad *click* button works).

## Timing and safety

- padd re-sends the current state to the pad every 8 ms, like a real controller.
- No STATE for 1 s: the state becomes neutral (`neutral` event, reason `watchdog`). Clients that hold input send
  the same state again every 100 ms or less.
- No bytes at all for 5 s: the client is dropped.
- Disconnect, SHUTDOWN, SIGTERM/SIGINT: neutral, then the pad is removed.
- The listening port is the single-instance lock. A second padd logs `already_running` and exits with code 3.
