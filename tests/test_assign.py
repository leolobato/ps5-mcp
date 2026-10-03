from pathlib import Path

import pytest
from PIL import Image

from ps5mcp import assign

ROOT = Path(__file__).resolve().parents[1]
DIALOG = ROOT / "tests/fixtures/assignment-dialog.png"
DIALOG_2 = ROOT / "tests/fixtures/assignment-dialog-scaled.jpg"
HOME = ROOT / "tests/fixtures/home-assigned.png"
HOME_2 = ROOT / "tests/fixtures/home.png"

pytestmark = pytest.mark.skipif(not (DIALOG.exists() and HOME.exists()), reason="test fixtures not present")


def frame(path):
    return Image.open(path).convert("RGB")


def test_detects_the_dialog_on_real_frames_and_nothing_else():
    assert assign.dialog_score(frame(DIALOG)) > 0.99
    assert assign.dialog_score(frame(DIALOG_2)) > 0.99  # a 960-wide archive frame, scaled up
    assert assign.dialog_score(frame(HOME)) < 0.6
    assert assign.dialog_score(frame(HOME_2)) < 0.6


def test_presses_cross_once_when_the_dialog_shows():
    frames = iter([frame(HOME), frame(DIALOG), frame(HOME)])
    presses = []
    assert assign.assign_if_asked(lambda: next(frames), lambda: presses.append(1), timeout=3, interval=0.01)
    assert presses == [1]


def test_never_presses_without_the_dialog():
    presses = []
    assert not assign.assign_if_asked(lambda: frame(HOME), lambda: presses.append(1), timeout=0.2, interval=0.05)
    assert not assign.assign_if_asked(lambda: (_ for _ in ()).throw(OSError("no card")), lambda: presses.append(1),
                                      timeout=0.2, interval=0.05)
    assert presses == []
