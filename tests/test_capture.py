from ps5mcp import capture

LISTING = """\
[AVFoundation indev @ 0xaaec14140] AVFoundation video devices:
[AVFoundation indev @ 0xaaec14140] [0] eEver USB Video Device
[AVFoundation indev @ 0xaaec14140] [1] MacBook Pro Camera
[AVFoundation indev @ 0xaaec14140] AVFoundation audio devices:
[AVFoundation indev @ 0xaaec14140] [0] CalDigit Thunderbolt 3 Audio
[AVFoundation indev @ 0xaaec14140] [1] eEver USB Audio Device
[in#0 @ 0xaaec14000] Error opening input: Input/output error
"""


def test_parse_device_list_splits_video_and_audio():
    devices = capture.parse_device_list(LISTING)
    assert devices.video == ["eEver USB Video Device", "MacBook Pro Camera"]
    assert devices.audio == ["CalDigit Thunderbolt 3 Audio", "eEver USB Audio Device"]


def test_daemon_command_has_one_device_input_and_two_outputs(tmp_path):
    command = capture.daemon_command(tmp_path / "latest.jpg")
    assert command.count("-i") == 1
    assert "eEver USB Video Device:eEver USB Audio Device" in command
    assert f"udp://127.0.0.1:{capture.STREAM_PORT}?pkt_size=1316" in command
    assert command[-1] == str(tmp_path / "latest.jpg")
    assert command[command.index("-atomic_writing") + 1] == "1"


def test_daemon_command_without_audio_maps_only_video(tmp_path):
    command = capture.daemon_command(tmp_path / "latest.jpg", audio=None)
    assert "eEver USB Video Device:none" in command
    assert "0:a" not in command and "aac" not in command


def test_stale_pidfile_is_not_running(tmp_path):
    daemon = capture.Daemon(tmp_path)
    daemon.pidfile.write_text("999999\n")
    assert daemon.pid() is None
    assert daemon.stop() is False
    assert not daemon.pidfile.exists()


def test_snapshot_refuses_stale_daemon_frame(tmp_path, monkeypatch):
    import os

    import pytest
    daemon = capture.Daemon(tmp_path)
    daemon.pidfile.write_text(f"{os.getpid()}\n")  # any live pid
    daemon.latest.write_bytes(b"jpeg")
    old = daemon.latest.stat().st_mtime - 60
    os.utime(daemon.latest, (old, old))
    with pytest.raises(capture.CaptureError, match="stale"):
        capture.snapshot(tmp_path / "out.jpg", daemon=daemon)


def test_live_stream_is_420_for_hardware_decoders(tmp_path):
    command = capture.daemon_command(tmp_path / "latest.jpg")
    assert command[command.index("-pix_fmt") + 1] == "yuv420p"


def test_view_prefers_mpv_with_locked_aspect(monkeypatch, tmp_path):
    monkeypatch.setattr(capture.shutil, "which", lambda name: "/usr/bin/mpv" if name == "mpv" else None)
    command = capture.view_command(ipc=tmp_path / "mpv.sock")
    assert command[0] == "mpv" and "--keepaspect-window=yes" in command
    assert f"--input-ipc-server={tmp_path / 'mpv.sock'}" in command


def test_view_falls_back_to_ffplay_at_16_9(monkeypatch):
    monkeypatch.setattr(capture.shutil, "which", lambda name: None)
    command = capture.view_command()
    assert command[0] == "ffplay"
    assert command[command.index("-x") + 1] == "1280" and command[command.index("-y") + 1] == "720"
