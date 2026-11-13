# Linux headless backend

Requires Python 3.12+, uv, FFmpeg with V4L2, lavfi and MJPEG support, and a C
compiler for the recording padd test stub. Linux selects the Python hub;
macOS continues to use the Swift app. Override with `PS5MCP_BACKEND=linux` or
`PS5MCP_BACKEND=native`.

Physical MJPEG 1080p60 has been validated on the local MACROSILICON card; see
[hardware results and remaining limits](linux-hardware-validation.md).

## One physical owner, many consumers

```text
Physical HDMI capture card
          |
     one FFmpeg process (V4L2 input)
          |
     Linux hub latest-frame cache
          +-- MCP session A screenshots
          +-- MCP session B screenshots
          +-- local MJPEG browser viewers
          +-- optional HTTP-to-v4l2loopback bridge --> existing capture viewer
```

All MCP sessions must use the same `PS5MCP_STATE` directory (default:
`~/.local/state/ps5-mcp`). Startup is serialized before child creation; the hub
also holds a lifetime process lock. A per-device lock, keyed by the resolved
device path, prevents two hubs in different state directories from opening the
same input. This lock coordinates PS5 MCP processes owned by the same Unix user;
it cannot lock out unrelated viewers or other users. Driver-reported busy errors
identify the device and explain how to switch to shared viewing. No viewer is
stopped or killed automatically.

Do not leave your existing viewer opening the physical card. Close its physical
input, then use the hub's browser viewer, open its MJPEG URL in a compatible
player, or select the virtual camera described below. Additional consumers never
start another physical capture process. The cache holds the newest immutable
JPEG only: slow HTTP readers can skip frames and never backpressure capture.

## Offline operation (no console or physical device)

```sh
uv sync
PS5MCP_VIDEO='lavfi:testsrc2=size=1280x720:rate=30' uv run ps5mcp capture start
uv run ps5mcp view
uv run ps5mcp snapshot -o /tmp/ps5-synthetic.png
uv run ps5mcp capture status
uv run ps5mcp capture stop
```

`view` prints the live browser URL; it does not launch a GUI application.
The viewer binds only to `127.0.0.1`, with an automatically selected port by
default. Choose a stable port with `--viewer-port 8090` on `capture start`, or
`PS5MCP_VIEWER_PORT=8090` before the hub starts. The URL is also in MCP `status`.

`PS5MCP_VIDEO=synthetic` retains the lightweight static Python image source and
is the default. `PS5MCP_VIDEO=file:/absolute/image.png` re-reads a local image
for deterministic tests. `lavfi:FILTER` runs a real, paced FFmpeg synthetic
source through exactly the same supervision and cache as physical capture.

The MCP server starts the shared hub automatically and leaves it running when
its session closes. To change settings, explicitly stop the hub and start it
again. Conflicting explicit input settings on a running hub are rejected.
Settings are process arguments/environment only, not personal configuration files.

## Physical capture configuration

Choose your own device path and a mode supported by your card. This mode was tested on one MACROSILICON card:

```sh
uv run ps5mcp capture start --backend linux \
  --video /dev/v4l/by-id/YOUR-CAPTURE-CARD-video-index0 \
  --video-format mjpeg --video-size 1920x1080 --video-fps 60 \
  --stale-s 2 --viewer-port 8090
```

Choose a mode actually supported by the card. A stable by-id path helps reconnect
after unplugging. `/dev/videoN` and `v4l2:/dev/videoN` are also accepted. Input format,
resolution and rate are mandatory for physical capture; nothing guesses a device
or silently falls back to another mode. The corresponding environment is:

| Variable | Meaning |
|---|---|
| `PS5MCP_VIDEO` | Explicit device, `synthetic`, `file:PATH`, or `lavfi:FILTER` |
| `PS5MCP_VIDEO_FORMAT` | V4L2 format/codec, e.g. `mjpeg` or `yuyv422` |
| `PS5MCP_VIDEO_SIZE` | `WIDTHxHEIGHT` |
| `PS5MCP_VIDEO_FPS` | Rate, including fractions such as `60000/1001` |
| `PS5MCP_VIDEO_STALE_S` | Fresh-frame timeout, default 2 seconds (0.1..60) |
| `PS5MCP_VIEWER_PORT` | Loopback HTTP port; 0 selects an available port |

FFmpeg's input options and supported format listing are documented in the
[official V4L2 documentation](https://ffmpeg.org/ffmpeg-devices.html#video4linux2_002c-v4l2).
Discovery that opens a card is intentionally not automatic. No audio or GPU
acceleration is requested. Physical MJPEG is passed through without recompression; raw/lavfi video is
JPEG-encoded once for fanout. Output frame synchronisation is passthrough. Linux screenshot
resizing uses Pillow rather than launching another FFmpeg process.

## Freshness, timestamps and recovery

Unix socket `snapshot` replies include `frame_sequence`, `frame_timestamp`
(monotonic seconds) and `frame_timestamp_unix` (Unix seconds). `include_data:true`
also returns `jpeg_base64` from that exact immutable frame. The adapter uses this
for screenshots, avoiding a race between metadata and the disk snapshot. Disk
`latest.jpg` publication remains atomic for existing integrations.

MCP `status().capture` exposes those fields, `frame_age_s`, `capture_error`,
`ffmpeg_pid`, `capture_starts`, `stale_after_s`, `video_config` and `viewer_url`.
Timestamps record arrival/publication at the hub, not HDMI hardware presentation
timestamps. A separate status call can describe a newer frame than a screenshot.

The hub terminates and reaps a stalled FFmpeg process before restarting it.
Exited/disconnected inputs retry once per second; a fresh frame is required to
clear the error. Old JPEGs are never returned as fresh during an outage.
Permission, busy-device and FFmpeg diagnostics are available in status. The
hub/API and controller connection stay alive during capture failure.

Viewer endpoints:

- `/`: lightweight live page, with recovery polling and reconnection.
- `/stream.mjpg`: multipart JPEG stream with per-frame sequence and timestamps.
- `/snapshot.jpg`: one fresh JPEG, with `X-Frame-Sequence`, `X-Frame-Timestamp`
  and `X-Frame-Timestamp-Unix` headers; HTTP 503 if unavailable.
- `/status.json`: hub/capture diagnostics.

Streams close when capture is lost; the included page reconnects after recovery.
Other players/consumers may need their own reconnect handling.

## Optional existing-viewer integration: v4l2loopback

The [upstream v4l2loopback documentation](https://github.com/v4l2loopback/v4l2loopback)
describes a kernel module that exposes application-generated video as a virtual
V4L2 camera. It needs a module built for the running CachyOS kernel; DKMS needs
matching kernel headers. `exclusive_caps=1` advertises output capability until a
producer attaches, then capture capability to readers. Start the producer before
selecting the virtual camera in the viewer.

After separately installing/loading the module and deliberately creating a virtual
output (for example `/dev/video10`), the bridge is an independent consumer:

```sh
# Example only: requires kernel-module/hardware setup, not performed by PS5 MCP.
# sudo modprobe v4l2loopback video_nr=10 card_label="PS5 MCP shared" exclusive_caps=1
ffmpeg -hide_banner -loglevel warning -nostdin \
  -f mpjpeg -i http://127.0.0.1:8090/stream.mjpg \
  -an -c:v rawvideo -pix_fmt yuv420p -threads 1 -f v4l2 /dev/video10
```

Confirm `/dev/video10` is your virtual output, not the physical input. Select that
virtual camera in your existing viewer. This bridge has no physical input and
cannot open the HDMI card; its conversion cost or failure does not stall the hub.
Its output uses FFmpeg's documented
[V4L2 output device](https://ffmpeg.org/ffmpeg-devices.html#v4l2).
Restart the bridge if its HTTP stream ends after capture loss. Module installation,
loading, viewer compatibility and actual virtual-device output remain untested;
none is done automatically. Offline tests verify the bridge's HTTP input and
raw-video conversion using a null output instead of a kernel device.

## Console access and controller integration

Console networking is disabled by default even with `PS5_HOST` set. An explicit
`PS5MCP_ALLOW_CONSOLE=1` plus a host enables the shared padd link;
`PS5MCP_PAD_PORT` defaults to 9305. Capture does not require console access.
Changing the endpoint or enabling an offline hub requires an explicit restart.

The Phase 3 controller manager supports ACK-checked input, cancellable holds,
sticks/triggers, sequences, virtual-controller management, FIFO claims and cached
status. Competing unclaimed input is rejected. Reconnects start neutral and never
resume old sequences. Phase 3 used local mocks/stubs. The authorised Phase 3.5
live runs verified handshake, existing-controller connection, profile assignment,
short Cross/PS presses and acknowledged neutral cleanup. A resumed run verified
a long PS hold to system home, short D-pad Left/Right and early timed-hold
cancellation. Physical active-hold disconnect/watchdog recovery remains untested.
See the [detailed live report](linux-controller-hardware-validation.md).

See [Linux controller setup, safety and limits](linux-controller.md). Automatic
user assignment, Remote Play, GUI/keyboard control, audio, frame metering and
`watch_change` remain unsupported. No payload is automatically deployed.

## Validation

```sh
make test-linux
make check-linux
```

Tests use generated images, FFmpeg lavfi, local Unix/HTTP sockets and loopback-only
padd-host. They cover multiple MCP clients/viewers, slow consumers, stale input,
process failure, simulated device loss/return, ownership locks, restart cleanup,
timestamps and the optional bridge's media path. No physical capture device,
PS5, kernel module or personal configuration is touched.

Native app/framework tests skip on Linux. Existing Remote Play helper/bridge
build limitations remain outside this target.
