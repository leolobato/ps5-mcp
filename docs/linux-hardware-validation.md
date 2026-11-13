# Linux HDMI hardware validation — 2026-11-13

Physical capture was tested on CachyOS using a MACROSILICON USB3.0 UVC card in
MJPEG 1920×1080 at 60 FPS. This public summary excludes device serial numbers,
console identifiers and captured pictures. Raw measurements and screenshots stay
under gitignored `build/`.

## Observed results

- Physical MJPEG now passes through FFmpeg without recompression. A ten-second
  comparison delivered approximately 60 FPS while reducing FFmpeg CPU from 54.2%
  to 0.40% of one logical core on the tested host. Raw/lavfi sources still encode JPEG.
- Twelve-second samples measured 60.01 FPS baseline and 60.09 FPS with three MCP
  clients and three simultaneous MJPEG viewers. All shared one FFmpeg process.
- Forty-five MCP screenshots scaled to 1280 pixels had median round-trip 32.93 ms
  and p95 34.73 ms. These are local RPC timings, not HDMI end-to-end latency.
- A separate V4L2 mmap reader dequeued 600 frames with zero driver sequence gaps.
  Consumer cache skips in the hub do not measure USB capture drops.
- A stalled capture child was detected after about two seconds; stale screenshots
  were refused, HTTP snapshots returned 503 and fresh capture recovered after a
  replacement child opened the card. A second hub was refused by the device lock.
- Shutdown removed the hub socket and released the physical input; a separate
  reader reopened it successfully afterward.

Capture-only measurements disabled console networking. No PS5 settings, files,
payloads or application state were changed by those measurements.

## Remaining limits and reproduction

Other advertised modes, physical USB unplug/replug, HDMI loss/relock and reboot
were not tested. The optional v4l2loopback bridge has offline media-path coverage,
but kernel-device output and existing-viewer compatibility remain unverified.
No module was loaded or installed during validation. No audio or GPU acceleration
is implemented for Linux. Measurements are short samples on one host/card.

The capture-only manual helper requires an explicit device and closes its resources:

```sh
uv run python scripts/validate-linux-capture.py \
  --device /dev/v4l/by-id/YOUR-CAPTURE-CARD-video-index0 \
  --output build/validation-capture --seconds 12
```

Close other physical-device viewers first. The helper disables console access,
uses the fixed tested 1080p60 MJPEG mode, exercises child-process recovery and
writes local screenshots/status/results only to the chosen output directory.
Use `make check-linux` for offline validation without a physical card.
