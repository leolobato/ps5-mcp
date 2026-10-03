# Virtual pad ABI (`/dev/hid`)

Interface values used by `payload/system_ps5.c`. Source of the constants: the FGG-XSense README and source
(https://github.com/FGGstore/FGG-XSense, GPL-3.0), verified there on firmware 11.60 only. This repo's code is
a separate implementation; only the interface values below are reused. The device ioctls and report layout have also been validated on firmware 13.60.

## ioctls

| Operation | Request | Encoded size |
|---|---|---|
| AddDevice | `0xC018482A` (`_IOWR('H', 0x2A, 24)`) | 24 |
| InsertData (report) | `0x8018482C` (`_IOW('H', 0x2C, 24)`) | 24 |
| DeleteDevice | `0x80104850` (`_IOW('H', 0x50, 16)`) | 16 |

24-byte request: `u32 op_or_handle; u32 unused; void *in; void *out`.

- AddDevice: `op = 3`, `in` = device descriptor, `out` = `int32` handle.
- InsertData: first field = handle, `in` = report, `out` = NULL.

16-byte DeleteDevice request: `u8 op = 5; u8 unused[7]; u32 handle; u32 unused`.

## Device descriptor (168 bytes)

| Offset | Value |
|---|---|
| 0x00 | protocol `3` (standard pad) |
| 0x1C | user id (`int32`): this is how the pad is bound to a user |
| 0x20 | class `1` |

There is no separate "bind to user" call.

## Input report (0xA0 bytes)

This is not `ScePadData`: libScePad reshapes it before the ioctl. The ioctl validates only the 24-byte request, so a
wrong layout is accepted silently.

| Offset | Field |
|---|---|
| 0x0C | buttons, `u32` |
| 0x10..0x13 | sticks lx, ly, rx, ry (`0x80` = centre) |
| 0x14 / 0x15 | L2 / R2 analogue |
| 0x17 | `1` (always set) |
| 0x78 | motion block, eight floats; quaternion w (`1.0f`) at +12 |

A zeroed report is not neutral: zero sticks mean full up-left.

Button bits: L3 `0x2`, R3 `0x4`, Options `0x8`, Up `0x10`, Right `0x20`, Down `0x40`, Left `0x80`, L2 `0x100`, R2 `0x200`,
L1 `0x400`, R1 `0x800`, Triangle `0x1000`, Circle `0x2000`, Cross `0x4000`, Square `0x8000`, Touchpad click `0x100000`.
The PS button is not reachable through this report.
