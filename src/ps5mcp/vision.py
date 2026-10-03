"""Template matching for `wait_for`: find a saved screen crop in the current frame.

Frames and templates are compared as grayscale at quarter resolution (480x270 for the 1080p source) using
normalised cross-correlation, computed with FFTs so a full-frame search takes a few milliseconds.
"""

from __future__ import annotations

import io
import json
import re
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image

SCALE = 4  # search at 1/4 resolution
_NAME = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


def templates_dir(root: Path) -> Path:
    path = root / "templates"
    path.mkdir(parents=True, exist_ok=True)
    return path


def check_name(name: str) -> str:
    if not _NAME.match(name):
        raise ValueError("template names use letters, digits, - and _ (max 64)")
    return name


def gray(image: Image.Image) -> np.ndarray:
    small = image.convert("L").resize((max(1, image.width // SCALE), max(1, image.height // SCALE)),
                                      Image.Resampling.BILINEAR)
    return np.asarray(small, dtype=np.float64)


def load(data: bytes) -> Image.Image:
    return Image.open(io.BytesIO(data))


@dataclass(frozen=True)
class Match:
    score: float  # -1..1, 1 = identical
    x: int        # top-left in full-resolution frame pixels
    y: int
    width: int
    height: int


def match(frame: np.ndarray, template: np.ndarray) -> Match:
    """Best normalised cross-correlation position of `template` inside `frame` (both from gray())."""
    fh, fw = frame.shape
    th, tw = template.shape
    if th > fh or tw > fw:
        raise ValueError("template larger than frame")
    t = template - template.mean()
    t_norm = np.sqrt((t * t).sum())
    if t_norm == 0:
        raise ValueError("template has no contrast")
    shape = (fh + th - 1, fw + tw - 1)
    # Correlation via FFT: sum over window of frame * t.
    corr = np.fft.irfft2(np.fft.rfft2(frame, shape) * np.fft.rfft2(t[::-1, ::-1], shape), shape)
    corr = corr[th - 1:fh, tw - 1:fw]
    # Window sums of frame and frame^2 via integral images, for the local normalisation.
    def window_sum(a):
        s = np.pad(a.cumsum(0).cumsum(1), ((1, 0), (1, 0)))
        return s[th:, tw:] - s[:-th, tw:] - s[th:, :-tw] + s[:-th, :-tw]
    n = th * tw
    sums, sums2 = window_sum(frame), window_sum(frame * frame)
    variance = np.maximum(sums2 - sums * sums / n, 1e-9)
    scores = corr / (np.sqrt(variance) * t_norm)
    y, x = np.unravel_index(int(np.argmax(scores)), scores.shape)
    return Match(float(scores[y, x]), int(x) * SCALE, int(y) * SCALE, tw * SCALE, th * SCALE)


def save_template(root: Path, name: str, frame: Image.Image, x: int, y: int, width: int, height: int) -> Path:
    check_name(name)
    if width < 16 or height < 16:
        raise ValueError("template must be at least 16x16 pixels")
    if x < 0 or y < 0 or x + width > frame.width or y + height > frame.height:
        raise ValueError(f"region outside the {frame.width}x{frame.height} frame")
    # Snap to the search grid so the template downsamples exactly like the frame does.
    x, y = x - x % SCALE, y - y % SCALE
    width, height = width - width % SCALE, height - height % SCALE
    folder = templates_dir(root)
    path = folder / f"{name}.png"
    frame.crop((x, y, x + width, y + height)).save(path)
    (folder / f"{name}.json").write_text(json.dumps({"x": x, "y": y, "width": width, "height": height}) + "\n")
    return path


def load_template(root: Path, name: str) -> tuple[np.ndarray, dict]:
    folder = templates_dir(root)
    path = folder / f"{check_name(name)}.png"
    if not path.exists():
        raise ValueError(f"no template named {name!r}; save one with save_template")
    meta = json.loads((folder / f"{name}.json").read_text())
    return gray(Image.open(path)), meta


def list_templates(root: Path) -> list[str]:
    return sorted(p.stem for p in templates_dir(root).glob("*.png"))
