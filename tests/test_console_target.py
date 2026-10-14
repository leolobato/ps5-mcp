"""Console selection must agree with the running app; no console or capture hardware is contacted."""

from unittest.mock import Mock

import pytest

from ps5mcp import capture


@pytest.fixture
def native(tmp_path, monkeypatch):
    monkeypatch.delenv("PS5_HOST", raising=False)
    app = capture.NativeApp(tmp_path)
    app.status = Mock(return_value={"pid": 123, "frames": 10, "pad": {"host": "192.0.2.10"}})
    app.request = Mock()
    monkeypatch.setattr(capture.subprocess, "Popen", Mock())
    monkeypatch.setattr(capture.subprocess, "run", Mock())
    return app


def test_start_reuses_matching_host_before_showing(native):
    assert native.start(host="192.0.2.10", visible=True) == 123
    native.request.assert_called_once_with("show")
    capture.subprocess.Popen.assert_not_called()
    capture.subprocess.run.assert_not_called()


@pytest.mark.parametrize("configured_by", ["argument", "environment"])
def test_start_refuses_mismatched_console_without_any_side_effect(native, monkeypatch, configured_by):
    kwargs = {}
    if configured_by == "argument":
        kwargs["host"] = "192.0.2.20"
    else:
        monkeypatch.setenv("PS5_HOST", "192.0.2.20")
    with pytest.raises(capture.CaptureError, match="targeting.*192.0.2.10.*requested.*192.0.2.20"):
        native.start(visible=True, **kwargs)
    native.request.assert_not_called()
    capture.subprocess.Popen.assert_not_called()
    capture.subprocess.run.assert_not_called()


def test_explicit_host_overrides_environment(native, monkeypatch):
    monkeypatch.setenv("PS5_HOST", "192.0.2.20")
    assert native.start(host="192.0.2.10") == 123
    assert native.target_host(host="192.0.2.10") == "192.0.2.10"


def test_start_without_configured_host_reuses_saved_app_target(native):
    assert native.start() == 123
    assert native.target_host() == "192.0.2.10"


@pytest.mark.parametrize("status", [
    {"pid": 123}, {"pid": 123, "pad": {"host": ""}}, {"pid": 123, "pad": None},
    {"pid": 123, "pad": []}, {"pid": 123, "pad": {"host": 123}},
])
def test_start_refuses_unverifiable_console_when_host_is_requested(native, status):
    native.status.return_value = status
    with pytest.raises(capture.CaptureError, match="unknown console"):
        native.start(host="192.0.2.10")
    native.request.assert_not_called()


def test_target_host_rechecks_settings_changes_and_refuses_pinned_mismatch(native, monkeypatch):
    monkeypatch.setenv("PS5_HOST", "192.0.2.10")
    assert native.target_host() == "192.0.2.10"
    native.status.return_value["pad"]["host"] = "192.0.2.20"
    with pytest.raises(capture.CaptureError, match="requested console"):
        native.target_host()
    monkeypatch.delenv("PS5_HOST")
    assert native.target_host() == "192.0.2.20"


@pytest.mark.parametrize("status", [
    None, {"pid": 123, "pad": {"host": ""}}, {"pid": 123}, {"pid": 123, "pad": None},
    {"pid": 123, "pad": []}, {"pid": 123, "pad": {"host": 123}},
])
def test_target_host_requires_a_running_app_with_known_target(native, status):
    native.status.return_value = status
    with pytest.raises(capture.CaptureError, match="console address"):
        native.target_host()


def test_start_without_requested_host_allows_capture_only_app(native):
    native.status.return_value = {"pid": 123, "pad": None}
    assert native.start() == 123


def test_start_validates_console_that_appears_after_launch(native, tmp_path):
    native.binary = tmp_path / "app"
    native.binary.touch()
    native.status.side_effect = [None, {"pid": 456, "frames": 10, "pad": {"host": "192.0.2.20"}}]
    capture.subprocess.Popen.return_value.poll.return_value = None
    with pytest.raises(capture.CaptureError, match="requested console"):
        native.start(video="synthetic", host="192.0.2.10")
    native.request.assert_not_called()
    capture.subprocess.Popen.assert_called_once()


def test_start_passes_requested_console_to_new_app(native, tmp_path):
    native.binary = tmp_path / "app"
    native.binary.touch()
    native.status.side_effect = [None, {"pid": 456, "frames": 10, "pad": {"host": "192.0.2.10"}}]
    capture.subprocess.Popen.return_value.poll.return_value = None
    assert native.start(video="synthetic", host="192.0.2.10") == 456
    command = capture.subprocess.Popen.call_args.args[0]
    assert command[command.index("--host") + 1] == "192.0.2.10"
