"""Answer "Who's using this controller?" for a fresh virtual pad.

Only the virtual pad can answer the screen it caused, and until it does the PS5 ignores its input. So whenever a
client connects, the host looks for the dialog (template match on its title) and presses Cross through padd,
which picks the focused, logged-in user. It never presses blindly: no dialog, no press.

Side effect: the PS5 then turns the user's DualSense off. Pressing PS on the
DualSense and picking the same user brings it back, and both controllers work.
"""

from __future__ import annotations

import time
from collections.abc import Callable
from pathlib import Path

from PIL import Image

from . import vision

TEMPLATE = Path(__file__).with_name("assets") / "assign-dialog.png"
DIALOG_AT = (712, 168)   # where the title sits in a 1920x1080 frame
MIN_SCORE = 0.9
MAX_OFFSET = 24


def capture_frame(backend=None) -> Callable[[], Image.Image]:
    """Frame source from the running capture backend (or a direct grab)."""
    import tempfile

    from . import capture

    def frame() -> Image.Image:
        with tempfile.TemporaryDirectory() as scratch:
            image = Image.open(capture.snapshot(Path(scratch) / "frame.jpg", daemon=backend))
            image.load()
            return image.convert("RGB")
    return frame


def dialog_score(frame: Image.Image) -> float:
    """Match score of the dialog title at its expected place (0 if it is elsewhere)."""
    if frame.size != (1920, 1080):
        frame = frame.resize((1920, 1080))
    found = vision.match(vision.gray(frame), vision.gray(Image.open(TEMPLATE)))
    near = abs(found.x - DIALOG_AT[0]) <= MAX_OFFSET and abs(found.y - DIALOG_AT[1]) <= MAX_OFFSET
    return found.score if near else 0.0


def assign_if_asked(frame: Callable[[], Image.Image], press_cross: Callable[[], None], timeout: float = 6.0,
                    interval: float = 0.5, log: Callable[[str], None] = lambda _: None) -> bool:
    """Watch for the dialog for `timeout` seconds; press Cross once if it shows. Returns True if it answered."""
    deadline = time.monotonic() + timeout
    while True:
        try:
            score = dialog_score(frame())
        except Exception as exc:  # noqa: BLE001 - no frame means no evidence of a dialog; never press blind
            log(f"auto-assign: no frame ({exc})")
            score = 0.0
        if score >= MIN_SCORE:
            log(f"auto-assign: 'Who's using this controller?' visible (score {score:.3f}); pressing Cross")
            press_cross()
            time.sleep(1.0)
            try:
                still = dialog_score(frame()) >= MIN_SCORE
            except Exception:  # noqa: BLE001
                still = False
            if not still:
                log("auto-assign: done; turn the DualSense back on with its PS button if it went off")
                return True
            log("auto-assign: dialog still visible after Cross")
            return False
        if time.monotonic() >= deadline:
            return False
        time.sleep(interval)
