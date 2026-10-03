import pytest

from ps5mcp import protocol as p
from ps5mcp.protocol import PadState, Touch


def test_state_roundtrip_is_28_bytes_after_header():
    state = PadState(buttons=p.BUTTONS["cross"] | p.BUTTONS["up"], lx=0, ly=255, r2=200,
                     touch=(Touch(True, 3, 960, 540), Touch()))
    frame = p.encode_state(7, state)
    assert frame[:4] == b"PMCP" and frame[4] == 1 and frame[5] == p.Type.STATE
    assert len(frame) == 8 + 28 and frame[6:8] == b"\x1c\x00"
    [(_, payload)] = p.Reader().feed(frame)
    assert p.decode_state(payload) == (7, state)


def test_neutral_has_centred_sticks():
    frame = p.encode_state(1, PadState())
    assert frame[8 + 8:8 + 12] == b"\x80\x80\x80\x80"
    assert PadState().is_neutral() and not PadState(lx=0).is_neutral()


def test_reader_handles_split_and_coalesced_frames():
    data = p.encode_ping(1) + p.encode_state(2, PadState())
    reader = p.Reader()
    assert reader.feed(data[:5]) == []
    messages = reader.feed(data[5:])
    assert [m[0] for m in messages] == [p.Type.PING, p.Type.STATE]


def test_reader_rejects_bad_magic_and_version():
    with pytest.raises(p.ProtocolError, match="magic"):
        p.Reader().feed(b"NOPE\x01\x01\x00\x00")
    with pytest.raises(p.ProtocolError, match="version"):
        p.Reader().feed(b"PMCP\x02\x01\x00\x00")


def test_button_names_and_sticks():
    assert p.button_mask(["Cross", "dpad_right"]) == 0x4020
    with pytest.raises(ValueError, match="unknown button"):
        p.button_mask(["ps"])
    assert p.stick_byte(-1) == 0 and p.stick_byte(0) == 0x80 and p.stick_byte(1) == 255


def test_merge_ors_buttons_and_keeps_strongest_axis():
    merged = PadState(buttons=1, lx=0).merged(PadState(buttons=2, lx=0x90, ry=255))
    assert merged.buttons == 3 and merged.lx == 0 and merged.ry == 255


def test_command_argument_limit():
    assert len(p.encode_command(1, p.Command.LAUNCH, "PPSA01325")) == 8 + 40
    with pytest.raises(ValueError):
        p.encode_command(1, p.Command.LAUNCH, "x" * 32)
