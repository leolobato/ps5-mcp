"""PMCP wire protocol v1 (mirror of payload/protocol.h; spec in docs/protocol.md)."""

from __future__ import annotations

import struct
from dataclasses import dataclass, field, replace
from enum import IntEnum

MAGIC = b"PMCP"
VERSION = 1
PORT = 9305
HEADER = struct.Struct("<4sBBH")
MAX_PAYLOAD = 256


class Type(IntEnum):
    HELLO = 1
    STATE = 2
    PING = 3
    ACK = 4
    ERROR = 5
    SHUTDOWN = 6
    GET_STATE = 7
    COMMAND = 8
    GET_USER = 9


class Command(IntEnum):
    HOME = 1
    LAUNCH = 2
    CLOSE = 3
    UNINSTALL = 4  # padd 1.3+ (FLAG_UNINSTALL)


HOME_METHODS = ("system", "shellcore", "suspend")


class Error(IntEnum):
    BAD_MAGIC = 1
    BAD_VERSION = 2
    BAD_LENGTH = 3
    UNKNOWN_TYPE = 4
    BUSY = 5
    NO_PAD = 6


FLAG_PAD_READY = 0x1
FLAG_TOUCH_UNMAPPED = 0x2
FLAG_USER_NAME = 0x4
FLAG_UNINSTALL = 0x8

# Uninstall ACK statuses besides 0 and SCE errors. ShadowMountPlus titles have their source deleted first.
UNINSTALL_RETRY = {16, 36}  # EBUSY (SMP busy or a game running), EINPROGRESS (source still being deleted)
UNINSTALL_ERRORS = {
    5: "ShadowMountPlus refused to delete the source (an image shared by several titles?)",
    13: "ShadowMountPlus may not delete some of the source's files (written by the game?); still installed",
    16: "busy: a game is running or ShadowMountPlus is moving files",
    22: "not a title id (4 letters and 5 digits)",
    36: "ShadowMountPlus is still deleting the source",
    45: "this ShadowMountPlus cannot delete sources (update it); still installed",
    61: "ShadowMountPlus manages this title but is not running; it would install it again",
}


def uninstall_text(status: int) -> str:
    if status == 0:
        return "uninstall requested"
    return UNINSTALL_ERRORS.get(status, f"refused, status {status & 0xFFFFFFFF:#010x}")

BUTTONS = {
    "l3": 0x2, "r3": 0x4, "options": 0x8,
    "up": 0x10, "right": 0x20, "down": 0x40, "left": 0x80,
    "l2": 0x100, "r2": 0x200, "l1": 0x400, "r1": 0x800,
    "triangle": 0x1000, "circle": 0x2000, "cross": 0x4000, "square": 0x8000,
    "touchpad": 0x100000,
}
CENTER = 0x80

_STATE = struct.Struct("<II6B2x" + "BBHH" * 2)
_HELLO = struct.Struct("<HHiiII")
_PONG = struct.Struct("<IHHQiIQII")
_ACK = struct.Struct("<Ii")
_USER = struct.Struct("<ii64s")
_COMMAND = struct.Struct("<II32s")
assert _STATE.size == 28 and _HELLO.size == 20 and _PONG.size == 40 and _ACK.size == 8 and _COMMAND.size == 40


class ProtocolError(RuntimeError):
    pass


def button_mask(names) -> int:
    mask = 0
    for name in names:
        key = name.lower().replace("dpad_", "").replace("dpad-", "")
        if key not in BUTTONS:
            raise ValueError(f"unknown button {name!r}; known: {', '.join(BUTTONS)}")
        mask |= BUTTONS[key]
    return mask


@dataclass(frozen=True)
class Touch:
    active: bool = False
    id: int = 0
    x: int = 0
    y: int = 0


@dataclass(frozen=True)
class PadState:
    buttons: int = 0
    lx: int = CENTER
    ly: int = CENTER
    rx: int = CENTER
    ry: int = CENTER
    l2: int = 0
    r2: int = 0
    touch: tuple[Touch, Touch] = field(default=(Touch(), Touch()))

    def is_neutral(self) -> bool:
        return self == PadState()

    def merged(self, other: PadState) -> PadState:
        """Buttons OR'd; axes from whichever side is further from rest."""
        def axis(a, b):
            return a if abs(a - CENTER) >= abs(b - CENTER) else b
        return replace(self, buttons=self.buttons | other.buttons, lx=axis(self.lx, other.lx),
                       ly=axis(self.ly, other.ly), rx=axis(self.rx, other.rx), ry=axis(self.ry, other.ry),
                       l2=max(self.l2, other.l2), r2=max(self.r2, other.r2))


def stick_byte(value: float) -> int:
    """-1.0..1.0 (up/left negative) to 0..255 with 0x80 at rest."""
    value = max(-1.0, min(1.0, float(value)))
    return max(0, min(255, round(CENTER + value * 127.5)))


def encode(type_: int, payload: bytes = b"") -> bytes:
    if len(payload) > MAX_PAYLOAD:
        raise ValueError("payload too long")
    return HEADER.pack(MAGIC, VERSION, int(type_), len(payload)) + payload


def encode_state(seq: int, state: PadState) -> bytes:
    touches = []
    for t in state.touch:
        touches += [int(t.active), t.id, t.x, t.y]
    return encode(Type.STATE, _STATE.pack(seq & 0xFFFFFFFF, state.buttons, state.lx, state.ly, state.rx, state.ry,
                                          state.l2, state.r2, *touches))


def decode_state(payload: bytes) -> tuple[int, PadState]:
    v = _STATE.unpack(payload)
    touch = (Touch(bool(v[8]), v[9], v[10], v[11]), Touch(bool(v[12]), v[13], v[14], v[15]))
    return v[0], PadState(v[1], v[2], v[3], v[4], v[5], v[6], v[7], touch)


def encode_ping(token: int) -> bytes:
    return encode(Type.PING, struct.pack("<I", token & 0xFFFFFFFF))


def encode_command(seq: int, op: Command, arg: str = "") -> bytes:
    raw = arg.encode()
    if len(raw) > 31:
        raise ValueError("command argument longer than 31 bytes")
    return encode(Type.COMMAND, _COMMAND.pack(seq & 0xFFFFFFFF, int(op), raw))


@dataclass(frozen=True)
class Hello:
    protocol: int
    payload_version: int
    pad_handle: int
    user_id: int
    flags: int
    add_status: int

    @property
    def pad_ready(self) -> bool:
        return bool(self.flags & FLAG_PAD_READY)


@dataclass(frozen=True)
class Pong:
    token: int
    protocol: int
    payload_version: int
    uptime_ms: int
    pad_handle: int
    flags: int
    reports_sent: int
    report_failures: int
    neutral_events: int


def decode_hello(payload: bytes) -> Hello:
    return Hello(*_HELLO.unpack(payload))


@dataclass(frozen=True)
class User:
    status: int
    user_id: int
    name: str


def decode_user(payload: bytes) -> User:
    status, user_id, raw = _USER.unpack(payload)
    return User(status, user_id, raw.split(b"\0", 1)[0].decode("utf-8", errors="replace"))


def decode_pong(payload: bytes) -> Pong:
    return Pong(*_PONG.unpack(payload))


def decode_ack(payload: bytes) -> tuple[int, int]:
    return _ACK.unpack(payload)


def decode_error(payload: bytes) -> tuple[int, str]:
    code = struct.unpack_from("<I", payload)[0]
    return code, payload[4:].decode(errors="replace")


class Reader:
    """Incremental decoder: feed bytes, get (type, payload) messages."""

    def __init__(self):
        self.buffer = bytearray()

    def feed(self, data: bytes) -> list[tuple[int, bytes]]:
        self.buffer += data
        messages = []
        while len(self.buffer) >= HEADER.size:
            magic, version, type_, length = HEADER.unpack_from(self.buffer)
            if magic != MAGIC:
                raise ProtocolError("bad magic")
            if version != VERSION:
                raise ProtocolError(f"unsupported protocol version {version}")
            if length > MAX_PAYLOAD:
                raise ProtocolError("payload too long")
            if len(self.buffer) < HEADER.size + length:
                break
            messages.append((type_, bytes(self.buffer[HEADER.size:HEADER.size + length])))
            del self.buffer[:HEADER.size + length]
        return messages


def version_string(packed: int) -> str:
    return f"{packed >> 8}.{packed & 0xFF}"
