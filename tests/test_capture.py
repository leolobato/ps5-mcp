from types import SimpleNamespace

import pytest

from ps5mcp import capture, cli

LISTING = """\
[AVFoundation indev @ 0xaaec14140] AVFoundation video devices:
[AVFoundation indev @ 0xaaec14140] [0] USB Capture Video
[AVFoundation indev @ 0xaaec14140] [1] Built-in Camera
[AVFoundation indev @ 0xaaec14140] AVFoundation audio devices:
[AVFoundation indev @ 0xaaec14140] [0] USB Headset
[AVFoundation indev @ 0xaaec14140] [1] USB Capture Audio
[in#0 @ 0xaaec14000] Error opening input: Input/output error
"""


def test_parse_device_list_splits_video_and_audio():
    devices = capture.parse_device_list(LISTING)
    assert devices.video == ["USB Capture Video", "Built-in Camera"]
    assert devices.audio == ["USB Headset", "USB Capture Audio"]


def test_daemon_command_has_one_device_input_and_two_outputs(tmp_path):
    command = capture.daemon_command(tmp_path / "latest.jpg", video="USB Capture Video", audio="USB Capture Audio")
    assert command.count("-i") == 1
    assert "USB Capture Video:USB Capture Audio" in command
    assert f"udp://127.0.0.1:{capture.STREAM_PORT}?pkt_size=1316" in command
    assert command[-1] == str(tmp_path / "latest.jpg")
    assert command[command.index("-atomic_writing") + 1] == "1"


def test_daemon_command_without_audio_maps_only_video(tmp_path):
    command = capture.daemon_command(tmp_path / "latest.jpg", video="USB Capture Video", audio=None)
    assert "USB Capture Video:none" in command
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
    with pytest.raises(capture.CaptureError, match="No video for"):
        capture.snapshot(tmp_path / "out.jpg", daemon=daemon)


def test_live_stream_is_420_for_hardware_decoders(tmp_path):
    command = capture.daemon_command(tmp_path / "latest.jpg", video="USB Capture Video", audio="USB Capture Audio")
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


@pytest.fixture
def native_launch(tmp_path, monkeypatch):
    """Observe arguments crossing the native process boundary without launching AVFoundation."""
    monkeypatch.delenv("PS5MCP_VIDEO", raising=False)
    monkeypatch.delenv("PS5MCP_AUDIO", raising=False)
    binary = tmp_path / "PS5 MCP.app/Contents/MacOS/PS5 MCP"
    binary.parent.mkdir(parents=True)
    binary.touch()
    app = capture.NativeApp(tmp_path, binary=binary)
    replies = iter([None, {"pid": 1234, "frames": 1, "frame_age": 0, "source": "camera"}])
    monkeypatch.setattr(app, "status", lambda: next(replies))
    launches = []
    process = SimpleNamespace(poll=lambda: None, kill=lambda: pytest.fail("healthy app killed"))
    monkeypatch.setattr(capture.subprocess, "run", lambda args, **kwargs: launches.append(args))
    monkeypatch.setattr(capture.subprocess, "Popen", lambda args, **kwargs: launches.append(args) or process)
    return app, launches


@pytest.mark.parametrize("entrypoint", ["start", "capture", "view"])
def test_native_launch_leaves_saved_device_choices_to_app(native_launch, monkeypatch, entrypoint):
    app, launches = native_launch
    if entrypoint == "start":
        assert app.start() == 1234
    else:
        monkeypatch.setattr(cli, "_backend", lambda args: app)
        assert cli.main(["capture", "start"] if entrypoint == "capture" else ["view"]) == 0
    assert "--video" not in launches[0]
    assert "--audio" not in launches[0]


@pytest.mark.parametrize("entrypoint", ["start", "cli"])
def test_native_launch_uses_explicit_device_over_environment(native_launch, monkeypatch, entrypoint):
    app, launches = native_launch
    monkeypatch.setenv("PS5MCP_VIDEO", "Other Video")
    monkeypatch.setenv("PS5MCP_AUDIO", "Other Audio")
    if entrypoint == "start":
        assert app.start(video="USB Capture Video", audio="USB Capture Audio") == 1234
    else:
        monkeypatch.setattr(cli, "_backend", lambda args: app)
        assert cli.main(["capture", "start", "--video", "USB Capture Video",
                         "--audio", "USB Capture Audio"]) == 0
    args = launches[0]
    assert args[args.index("--video") + 1] == "USB Capture Video"
    assert args[args.index("--audio") + 1] == "USB Capture Audio"


def test_native_launch_respects_device_environment(native_launch, monkeypatch):
    app, launches = native_launch
    monkeypatch.setenv("PS5MCP_VIDEO", "USB Capture Video")
    monkeypatch.setenv("PS5MCP_AUDIO", "USB Capture Audio")
    assert app.start() == 1234
    args = launches[0]
    assert args[args.index("--video") + 1] == "USB Capture Video"
    assert args[args.index("--audio") + 1] == "USB Capture Audio"


@pytest.mark.parametrize("entrypoint", ["start", "cli"])
def test_native_launch_can_explicitly_disable_saved_audio(native_launch, monkeypatch, entrypoint):
    app, launches = native_launch
    monkeypatch.setenv("PS5MCP_AUDIO", "USB Capture Audio")
    if entrypoint == "start":
        assert app.start(audio=None) == 1234
    else:
        monkeypatch.setattr(cli, "_backend", lambda args: app)
        assert cli.main(["capture", "start", "--no-audio"]) == 0
    args = launches[0]
    assert args[args.index("--audio") + 1] == "none"


@pytest.mark.parametrize("video", ["synthetic", "file:/tmp/input.mp4"])
def test_native_test_sources_disable_audio(native_launch, video):
    app, launches = native_launch
    assert app.start(video=video) == 1234
    args = launches[0]
    assert args[0] == str(app.binary)
    assert args[args.index("--video") + 1] == video
    assert args[args.index("--audio") + 1] == "none"


@pytest.mark.parametrize("bundled", [True, False])
def test_native_start_accepts_unavailable_source_without_killing_app(native_launch, monkeypatch, bundled):
    app, launches = native_launch
    if not bundled:
        app.binary = app.root / "bin/native-test-app"
        app.binary.parent.mkdir()
        app.binary.touch()
    replies = [None]
    unavailable = {"pid": 1234, "frames": 0, "frame_age": -1, "source": "unavailable"}
    monkeypatch.setattr(app, "status", lambda: replies.pop() if replies else unavailable)
    assert app.start(video="Missing Card", timeout=0.5) == 1234
    assert len(launches) == 1


@pytest.mark.parametrize("entrypoint", ["command", "start", "snapshot"])
def test_ffmpeg_requires_explicit_video_device(tmp_path, monkeypatch, entrypoint):
    monkeypatch.delenv("PS5MCP_VIDEO", raising=False)
    with pytest.raises(capture.CaptureError, match="PS5MCP_VIDEO|--video"):
        if entrypoint == "command":
            capture.daemon_command(tmp_path / "latest.jpg")
        elif entrypoint == "start":
            capture.Daemon(tmp_path).start()
        else:
            capture.grab_direct(tmp_path / "snapshot.png")


def test_ffmpeg_uses_explicit_environment_devices(tmp_path, monkeypatch):
    monkeypatch.setenv("PS5MCP_VIDEO", "USB Capture Video")
    monkeypatch.setenv("PS5MCP_AUDIO", "USB Capture Audio")
    command = capture.daemon_command(tmp_path / "latest.jpg")
    assert "USB Capture Video:USB Capture Audio" in command


def test_capture_status_handles_running_app_without_frames(tmp_path, monkeypatch, capsys):
    app = capture.NativeApp(tmp_path)
    monkeypatch.setattr(app, "status", lambda: {"pid": 1234, "frames": 0, "frame_age": -1})
    monkeypatch.setattr(cli, "_backend", lambda args: app)
    assert cli.main(["capture", "status"]) == 0
    assert "1234" in capsys.readouterr().out


@pytest.mark.parametrize("audio_environment", [None, "none", ""])
def test_ffmpeg_without_selected_audio_maps_only_video(tmp_path, monkeypatch, audio_environment):
    if audio_environment is None:
        monkeypatch.delenv("PS5MCP_AUDIO", raising=False)
    else:
        monkeypatch.setenv("PS5MCP_AUDIO", audio_environment)
    command = capture.daemon_command(tmp_path / "latest.jpg", video="USB Capture Video")
    assert "USB Capture Video:none" in command
    assert "0:a" not in command and "aac" not in command


def test_native_test_source_waits_until_frames_are_ready(native_launch, monkeypatch):
    app, _launches = native_launch
    replies = iter([None, {"pid": 1234, "frames": 0, "frame_age": -1, "source": "synthetic"},
                    {"pid": 1234, "frames": 1, "frame_age": 0, "source": "synthetic"}])
    last_status = []

    def status():
        reply = next(replies)
        last_status[:] = [reply]
        return reply

    monkeypatch.setattr(app, "status", status)
    monkeypatch.setattr(capture.time, "sleep", lambda delay: None)
    assert app.start(video="synthetic") == 1234
    assert last_status[0]["frames"] == 1


def test_ffmpeg_requests_generic_capture_rate(tmp_path):
    command = capture.daemon_command(tmp_path / "latest.jpg", video="USB Capture Video", audio=None)
    assert command[command.index("-framerate") + 1] == "60"


def test_remoteplay_start_returns_diagnostics_before_first_frame(native_launch, monkeypatch):
    app, launches = native_launch
    replies = [None]
    connecting = {"pid": 1234, "frames": 0, "frame_age": -1, "source": "remoteplay",
                  "remote_play": {"state": "connecting"}}
    monkeypatch.setattr(app, "status", lambda: replies.pop() if replies else connecting)
    assert app.start(video="remoteplay", timeout=0.01) == 1234
    args = launches[0]
    assert args[args.index("--video") + 1] == "remoteplay"


@pytest.mark.parametrize("entrypoint", ["command", "snapshot"])
def test_remoteplay_cannot_fall_back_to_ffmpeg_camera(tmp_path, entrypoint):
    with pytest.raises(capture.CaptureError, match="Remote Play.*native app"):
        if entrypoint == "command":
            capture.daemon_command(tmp_path / "latest.jpg", video="remoteplay")
        else:
            capture.grab_direct(tmp_path / "frame.jpg", video="remoteplay")


def test_app_binary_prefers_override_then_installed_release(tmp_path, monkeypatch):
    monkeypatch.setenv("PS5MCP_APP", str(tmp_path / "Other.app"))
    assert capture.app_binary() == tmp_path / "Other.app/Contents/MacOS/PS5 MCP"
    monkeypatch.delenv("PS5MCP_APP")
    installed = tmp_path / "Applications/PS5 MCP.app"
    monkeypatch.setattr(capture, "INSTALLED_APP", installed)
    assert capture.app_binary() == capture.NATIVE_BINARY
    installed.mkdir(parents=True)
    assert capture.app_binary() == installed / "Contents/MacOS/PS5 MCP"


def test_stop_then_start_reopens_a_visible_window(native_launch, monkeypatch):
    app, launches = native_launch
    monkeypatch.setattr(app, "status", lambda: {"pid": 1234, "visible": True})
    monkeypatch.setattr(app, "request", lambda cmd, **kwargs: [{"ok": True}])
    monkeypatch.setattr(capture.os, "kill", lambda pid, sig: (_ for _ in ()).throw(ProcessLookupError()))
    assert app.stop() is True
    replies = iter([None, {"pid": 1234, "frames": 1, "frame_age": 0, "source": "camera"}])
    monkeypatch.setattr(app, "status", lambda: next(replies))
    assert app.start() == 1234
    assert "--headless" not in launches[0]
    assert not app.reopen_visible.exists()


def test_stop_of_a_headless_app_starts_headless_again(native_launch, monkeypatch):
    app, launches = native_launch
    monkeypatch.setattr(app, "status", lambda: {"pid": 1234, "visible": False})
    monkeypatch.setattr(app, "request", lambda cmd, **kwargs: [{"ok": True}])
    monkeypatch.setattr(capture.os, "kill", lambda pid, sig: (_ for _ in ()).throw(ProcessLookupError()))
    app.stop()
    replies = iter([None, {"pid": 1234, "frames": 1, "frame_age": 0, "source": "camera"}])
    monkeypatch.setattr(app, "status", lambda: next(replies))
    app.start()
    assert "--headless" in launches[0]


@pytest.mark.parametrize(("age", "lost"), [(12.4, "No video for 12 s"), (None, "No video since the app started")])
def test_stale_snapshot_says_the_signal_dropped_and_not_to_restart(tmp_path, monkeypatch, age, lost):
    app = capture.NativeApp(tmp_path)
    monkeypatch.setattr(app, "pid", lambda: 1234)
    monkeypatch.setattr(app, "frame_age", lambda: age)
    with pytest.raises(capture.CaptureError) as error:
        capture.snapshot(tmp_path / "frame.jpg", daemon=app)
    assert lost in str(error.value) and "Do not restart" in str(error.value)
