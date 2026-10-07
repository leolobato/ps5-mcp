"""Installer task outcomes against faked Web File Manager responses; no console access."""

from __future__ import annotations

import pytest

from ps5mcp import installer


class TaskConsole:
    def __init__(self, snapshots, submitted=None):
        self.snapshots = iter(snapshots)
        self.last = {}
        self.submitted = submitted if submitted is not None else {"task_ids": [42]}
        self.calls = []

    def api(self, endpoint, params=None, form=False):
        self.calls.append((endpoint, params, form))
        if endpoint == "/api/tasks":
            self.last = next(self.snapshots, self.last)
            return self.last
        if endpoint == "/api/install-pkg":
            return self.submitted
        if endpoint == "/api/upload/prepare":
            return {"task_id": 42}
        if endpoint == "/api/upload/finish":
            return {"ok": True}
        if endpoint == "/api/space":
            return {"spaces": []}
        raise AssertionError(f"unexpected endpoint: {endpoint}")

    def ensure_dir(self, directory):
        assert directory == installer.PKG_DIR


@pytest.fixture(autouse=True)
def fake_clock(monkeypatch):
    now = [0.0]
    monkeypatch.setattr(installer.time, "monotonic", lambda: now[0])
    monkeypatch.setattr(installer.time, "sleep", lambda seconds: now.__setitem__(0, now[0] + seconds))
    return now


def wait(snapshots, op="upload", task_id=42, timeout=30):
    return installer._wait(TaskConsole(snapshots), op, timeout, lambda line: None, task_id)


def test_matching_completion_only_upload_is_confirmed_without_active_task():
    completion = {"id": 42, "op": "upload", "src": "game.pkg"}
    assert wait([{"tasks": [], "completion": completion}]) == {**completion, "state": "done"}


@pytest.mark.parametrize("op", ["upload", "pkg_install"])
@pytest.mark.parametrize("state", ["done", "failed", "canceled"])
def test_matching_completion_only_explicit_terminal_state(op, state):
    completion = {"id": 42, "op": op, "state": state, "error": "details"}
    assert wait([{"completion": completion}], op=op) == completion


@pytest.mark.parametrize("completion", [
    {"id": 99, "op": "upload", "state": "done"},
    {"id": 42, "op": "pkg_install", "state": "done"},
    {"id": 99, "op": "pkg_install", "state": "done"},
    {"id": 42, "state": "done"},
])
def test_unrelated_or_unidentified_completion_does_not_confirm_task(completion):
    with pytest.raises(TimeoutError, match="outcome unknown"):
        wait([{"completion": completion}], timeout=3)


def test_op_only_completion_without_observed_task_is_not_positive_evidence():
    with pytest.raises(TimeoutError, match="outcome unknown"):
        wait([{"completion": {"id": 42, "op": "upload"}}], task_id=None, timeout=3)


def test_package_completion_without_terminal_state_is_not_positive_evidence():
    with pytest.raises(TimeoutError, match="outcome unknown"):
        wait([{"completion": {"id": 42, "op": "pkg_install"}}], op="pkg_install", timeout=3)


@pytest.mark.parametrize("completion", [None,
    {"id": 99, "op": "upload", "state": "done"},
    {"id": 42, "op": "pkg_install", "state": "done"},
])
def test_running_task_disappearance_does_not_synthesize_success(completion):
    snapshots = [{"tasks": [{"id": 42, "op": "upload", "state": "running"}]},
                 {"tasks": [], "completion": completion}]
    with pytest.raises(RuntimeError, match="disappeared.*outcome unknown"):
        wait(snapshots)


def test_observed_upload_can_finish_via_success_only_completion():
    snapshots = [{"tasks": [{"id": 42, "op": "upload", "state": "running"}]},
                 {"tasks": [], "completion": {"id": 42, "op": "upload"}}]
    assert wait(snapshots, task_id=None)["state"] == "done"


def test_op_polling_latches_identity_instead_of_following_another_task():
    snapshots = [{"tasks": [{"id": 42, "op": "pkg_install", "state": "running"}]},
                 {"tasks": [{"id": 99, "op": "pkg_install", "state": "done"}]}]
    with pytest.raises(RuntimeError, match="task 42 disappeared"):
        wait(snapshots, op="pkg_install", task_id=None)


@pytest.mark.parametrize("state", ["done", "failed", "canceled"])
def test_observed_terminal_task_returns_actual_state(state):
    task = {"id": 42, "op": "upload", "state": state}
    assert wait([{"tasks": [task]}]) == task


@pytest.mark.parametrize("timeout, elapsed", [(3, 3), (30, 15)])
def test_never_seen_task_is_unknown_at_timeout_or_observation_limit(fake_clock, timeout, elapsed):
    with pytest.raises(TimeoutError, match="outcome unknown"):
        wait([{"tasks": []}], timeout=timeout)
    assert fake_clock[0] == elapsed


def test_nonterminal_task_timeout_is_unknown():
    with pytest.raises(TimeoutError, match="outcome unknown"):
        wait([{"tasks": [{"id": 42, "op": "upload", "state": "running"}]}], timeout=3)


@pytest.fixture
def package(tmp_path):
    path = tmp_path / "game.pkg"
    path.write_bytes(b"package")
    return path


def test_install_package_uses_submitted_identity(monkeypatch, package):
    console = TaskConsole([{"tasks": [{"id": 99, "op": "pkg_install", "state": "done"}]},
                           {"tasks": [{"id": 42, "op": "pkg_install", "state": "done"}]}])
    monkeypatch.setattr(installer, "Console", lambda host: console)
    monkeypatch.setattr(installer, "_upload", lambda *args: None)
    summary = installer.install_pkg("unused", package, lambda line: None, timeout=3)
    assert summary.startswith("installed game.pkg")
    assert len([call for call in console.calls if call[0] == "/api/tasks"]) == 2


@pytest.mark.parametrize("state", ["failed", "canceled"])
def test_install_package_reports_actual_terminal_failure(monkeypatch, package, state):
    console = TaskConsole([{"tasks": [{"id": 42, "op": "pkg_install", "state": state,
                                      "error": "installation stopped"}]}])
    monkeypatch.setattr(installer, "Console", lambda host: console)
    monkeypatch.setattr(installer, "_upload", lambda *args: None)
    with pytest.raises(RuntimeError, match=f"install of game.pkg {state}: installation stopped"):
        installer.install_pkg("unused", package, lambda line: None, timeout=3)


@pytest.mark.parametrize("snapshots", [
    [{"tasks": []}],
    [{"tasks": [{"id": 42, "op": "pkg_install", "state": "running"}]}, {"tasks": []}],
])
def test_install_package_never_returns_success_for_unknown_outcome(monkeypatch, package, snapshots):
    monkeypatch.setattr(installer, "Console", lambda host: TaskConsole(snapshots))
    monkeypatch.setattr(installer, "_upload", lambda *args: None)
    with pytest.raises((RuntimeError, TimeoutError), match="outcome unknown"):
        installer.install_pkg("unused", package, lambda line: None, timeout=3)


class UploadConnection:
    """Accept streaming bytes locally without making any HTTP request."""

    def __init__(self, *args, **kwargs):
        self.status = 200

    def putrequest(self, *args):
        pass

    def putheader(self, *args):
        pass

    def endheaders(self):
        pass

    def send(self, chunk):
        pass

    def getresponse(self):
        return self

    def read(self):
        return b""

    def close(self):
        pass


@pytest.mark.parametrize("state", [None, "done", "failed", "canceled"])
def test_upload_requires_confirmed_success_and_preserves_terminal_failures(monkeypatch, package, state):
    completion = {"id": 42, "op": "upload"}
    if state is not None:
        completion.update(state=state, error="upload stopped")
    console = TaskConsole([{"completion": completion}])
    monkeypatch.setattr(installer.http.client, "HTTPConnection", UploadConnection)
    if state in (None, "done"):
        installer._upload(console, "unused", package, installer.PKG_DIR, lambda line: None, timeout=3)
    else:
        with pytest.raises(RuntimeError, match=f"upload of game.pkg {state}: upload stopped"):
            installer._upload(console, "unused", package, installer.PKG_DIR, lambda line: None, timeout=3)


@pytest.mark.parametrize("task", [{}, {"state": "unknown"}])
def test_upload_caller_does_not_accept_unknown_wait_result(monkeypatch, package, task):
    monkeypatch.setattr(installer.http.client, "HTTPConnection", UploadConnection)
    monkeypatch.setattr(installer, "_wait", lambda *args: task)
    with pytest.raises(RuntimeError, match="upload of game.pkg unknown"):
        installer._upload(TaskConsole([]), "unused", package, installer.PKG_DIR, lambda line: None, timeout=3)


@pytest.mark.parametrize("submitted", [
    {}, {"task_ids": []}, {"task_ids": None}, {"task_ids": "42"},
    {"task_ids": [42, 99]}, {"task_ids": [None]}, {"task_ids": [True]},
    {"task_ids": ["42"]}, {"task_ids": [0]}, {"task_ids": [-1]},
])
def test_install_without_unambiguous_submitted_id_cannot_accept_unrelated_done(monkeypatch, package, submitted):
    console = TaskConsole([{"tasks": [{"id": 99, "op": "pkg_install", "state": "done"}]}], submitted)
    monkeypatch.setattr(installer, "Console", lambda host: console)
    monkeypatch.setattr(installer, "_upload", lambda *args: None)
    with pytest.raises(RuntimeError, match="no unambiguous task id.*outcome unknown"):
        installer.install_pkg("unused", package, lambda line: None, timeout=3)
    assert not any(call[0] == "/api/tasks" for call in console.calls)


def test_install_accepts_single_submitted_task_id(monkeypatch, package):
    console = TaskConsole([{"tasks": [{"id": 42, "op": "pkg_install", "state": "done"}]}],
                          submitted={"task_id": 42})
    monkeypatch.setattr(installer, "Console", lambda host: console)
    monkeypatch.setattr(installer, "_upload", lambda *args: None)
    assert installer.install_pkg("unused", package, lambda line: None, timeout=3).startswith("installed game.pkg")


def test_op_polling_selects_newest_task_first():
    snapshots = [{"tasks": [{"id": 42, "op": "upload", "state": "running"},
                            {"id": 99, "op": "upload", "state": "done"}]},
                 {"completion": {"id": 42, "op": "upload"}}]
    assert wait(snapshots, task_id=None)["id"] == 42


@pytest.mark.parametrize("task", [
    {"id": 99, "op": "upload", "state": "done"},
    {"id": 42, "op": "pkg_install", "state": "done"},
])
def test_unrelated_terminal_active_task_is_not_accepted(task):
    with pytest.raises(TimeoutError, match="outcome unknown"):
        wait([{"tasks": [task]}], timeout=3)


def test_unknown_upload_prevents_package_install_request(monkeypatch, package):
    console = TaskConsole([{"tasks": []}])
    monkeypatch.setattr(installer, "Console", lambda host: console)
    monkeypatch.setattr(installer.http.client, "HTTPConnection", UploadConnection)
    with pytest.raises(TimeoutError, match="upload.*outcome unknown"):
        installer.install_pkg("unused", package, lambda line: None, timeout=3)
    assert not any(call[0] == "/api/install-pkg" for call in console.calls)


@pytest.mark.parametrize("task", [{}, {"state": "unknown"}])
def test_install_caller_does_not_accept_unknown_wait_result(monkeypatch, package, task):
    monkeypatch.setattr(installer, "Console", lambda host: TaskConsole([]))
    monkeypatch.setattr(installer, "_upload", lambda *args: None)
    monkeypatch.setattr(installer, "_wait", lambda *args: task)
    with pytest.raises(RuntimeError, match="install of game.pkg unknown"):
        installer.install_pkg("unused", package, lambda line: None, timeout=3)
