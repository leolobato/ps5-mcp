"""Recording input (agent or keyboard) as timed steps that `sequence` / `play_recording` replay."""

from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from pathlib import Path

from . import protocol as p
from .protocol import PadState
from .vision import check_name

MAX_STEP_MS = 10_000
MAX_RECORDING_S = 300


def state_to_step(state: PadState, duration_ms: int) -> dict:
    step: dict = {"duration_ms": duration_ms}
    names = [name for name, bit in p.BUTTONS.items() if state.buttons & bit]
    if names:
        step["buttons"] = names
    for axis in ("lx", "ly", "rx", "ry"):
        value = getattr(state, axis)
        if value != p.CENTER:
            step[axis] = round((value - p.CENTER) / 127.5, 4)
    for trigger in ("l2", "r2"):
        value = getattr(state, trigger)
        if value:
            step[trigger] = round(value / 255, 4)
    return step


def step_to_state(step: dict) -> PadState:
    def unit(value):
        return max(0.0, min(1.0, float(value)))
    return PadState(
        buttons=p.button_mask(step.get("buttons", [])),
        lx=p.stick_byte(step.get("lx", 0)), ly=p.stick_byte(step.get("ly", 0)),
        rx=p.stick_byte(step.get("rx", 0)), ry=p.stick_byte(step.get("ry", 0)),
        l2=round(255 * unit(step.get("l2", 0))), r2=round(255 * unit(step.get("r2", 0))))


@dataclass
class Recorder:
    """Timeline of merged pad states. `changes` holds (monotonic time, state) on every change."""
    started: float = field(default_factory=time.monotonic)
    changes: list[tuple[float, PadState]] = field(default_factory=list)

    def note(self, state: PadState, at: float | None = None) -> None:
        at = time.monotonic() if at is None else at
        if not self.changes or self.changes[-1][1] != state:
            self.changes.append((at, state))

    def steps(self, end: float | None = None) -> list[dict]:
        end = time.monotonic() if end is None else end
        if not self.changes:
            return []
        steps = []
        ends = [at for at, _ in self.changes[1:]] + [end]
        for (at, state), next_at in zip(self.changes, ends, strict=True):
            remaining = round((next_at - at) * 1000)
            while remaining > 0:  # sequence steps are limited to MAX_STEP_MS each
                chunk = min(remaining, MAX_STEP_MS)
                steps.append(state_to_step(state, chunk))
                remaining -= chunk
        while steps and set(steps[0]) == {"duration_ms"}:  # leading idle time is not part of the input
            steps.pop(0)
        if steps and set(steps[-1]) == {"duration_ms"}:
            steps.pop()
        return steps


def recordings_dir(root: Path) -> Path:
    path = root / "recordings"
    path.mkdir(parents=True, exist_ok=True)
    return path


def save(root: Path, name: str, steps: list[dict], source: str) -> Path:
    path = recordings_dir(root) / f"{check_name(name)}.json"
    path.write_text(json.dumps({"name": name, "source": source, "recorded_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                                "duration_ms": sum(s["duration_ms"] for s in steps), "steps": steps}, indent=2) + "\n")
    return path


def load(root: Path, name: str) -> list[dict]:
    path = recordings_dir(root) / f"{check_name(name)}.json"
    if not path.exists():
        raise ValueError(f"no recording named {name!r}")
    return json.loads(path.read_text())["steps"]


def list_recordings(root: Path) -> list[dict]:
    out = []
    for path in sorted(recordings_dir(root).glob("*.json")):
        data = json.loads(path.read_text())
        out.append({"name": data["name"], "duration_ms": data["duration_ms"], "steps": len(data["steps"]),
                    "source": data.get("source")})
    return out
