"""TCP client for padd, and the controller that streams merged agent + keyboard state."""

from __future__ import annotations

import itertools
import socket
import threading
import time
from dataclasses import dataclass

from . import protocol as p
from .protocol import PadState


class PadError(RuntimeError):
    pass


class PadBusy(PadError):
    pass


class PadLink:
    """One connection to padd. A reader thread routes replies; calls are thread-safe."""

    def __init__(self, host: str, port: int = p.PORT, timeout: float = 3.0):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.timeout = timeout
        self._send_lock = threading.Lock()
        self._cond = threading.Condition()
        self._acks: dict[int, int] = {}
        self._replies: dict[int, list[bytes]] = {}
        self._seq = itertools.count(1)
        self.closed = False
        self.error: str | None = None
        self.last_ack_seq = 0
        reader = p.Reader()
        self.sock.settimeout(timeout)
        while True:
            data = self.sock.recv(4096)
            if not data:
                raise PadError("padd closed the connection during HELLO")
            messages = reader.feed(data)
            if messages:
                break
        type_, payload = messages[0]
        if type_ == p.Type.ERROR:
            code, message = p.decode_error(payload)
            self.sock.close()
            raise (PadBusy if code == p.Error.BUSY else PadError)(message)
        if type_ != p.Type.HELLO:
            raise PadError(f"expected HELLO, got type {type_}")
        self.hello = p.decode_hello(payload)
        self.sock.settimeout(None)
        self._reader = reader
        for message in messages[1:]:
            self._dispatch(*message)
        threading.Thread(target=self._read_loop, daemon=True, name="padd-reader").start()

    def next_seq(self) -> int:
        return next(self._seq)

    def _dispatch(self, type_: int, payload: bytes) -> None:
        with self._cond:
            if type_ == p.Type.ACK:
                seq, status = p.decode_ack(payload)
                self._acks[seq] = status
                self.last_ack_seq = max(self.last_ack_seq, seq)
                if len(self._acks) > 512:  # streamed states are rarely awaited
                    for old in sorted(self._acks)[:256]:
                        del self._acks[old]
            elif type_ == p.Type.ERROR:
                code, message = p.decode_error(payload)
                self.error = f"{p.Error(code).name if code in p.Error._value2member_map_ else code}: {message}"
            else:
                self._replies.setdefault(type_, []).append(payload)
            self._cond.notify_all()

    def _read_loop(self) -> None:
        try:
            while True:
                data = self.sock.recv(4096)
                if not data:
                    break
                for message in self._reader.feed(data):
                    self._dispatch(*message)
        except (OSError, p.ProtocolError) as exc:
            self.error = self.error or str(exc)
        finally:
            with self._cond:
                self.closed = True
                self._cond.notify_all()

    def _send(self, data: bytes) -> None:
        if self.closed:
            raise PadError(self.error or "connection closed")
        with self._send_lock:
            try:
                self.sock.sendall(data)
            except OSError as exc:
                self.closed = True
                raise PadError(str(exc)) from exc

    def _wait(self, predicate, timeout: float | None):
        deadline = time.monotonic() + (timeout or self.timeout)
        with self._cond:
            while not (result := predicate()):
                if self.closed:
                    raise PadError(self.error or "connection closed")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise PadError("timed out waiting for padd")
                self._cond.wait(remaining)
            return result

    def send_state(self, state: PadState, wait: bool = False, timeout: float | None = None) -> int:
        seq = self.next_seq()
        self._send(p.encode_state(seq, state))
        if wait:
            return self.wait_ack(seq, timeout)
        return 0

    def wait_ack(self, seq: int, timeout: float | None = None) -> int:
        return self._wait(lambda: (True, self._acks.pop(seq)) if seq in self._acks else None, timeout)[1]

    def _request(self, data: bytes, reply_type: int, timeout: float | None) -> bytes:
        with self._cond:
            self._replies.pop(reply_type, None)
        self._send(data)
        return self._wait(lambda: self._replies.get(reply_type, []) and self._replies[reply_type].pop(0), timeout)

    def ping(self, timeout: float | None = None) -> p.Pong:
        token = self.next_seq()
        return p.decode_pong(self._request(p.encode_ping(token), p.Type.PING, timeout))

    def get_user(self, timeout: float | None = None) -> p.User | None:
        if not self.hello.flags & p.FLAG_USER_NAME:
            return None
        return p.decode_user(self._request(p.encode(p.Type.GET_USER), p.Type.GET_USER, timeout))

    def get_state(self, timeout: float | None = None) -> PadState:
        return p.decode_state(self._request(p.encode(p.Type.GET_STATE), p.Type.STATE, timeout))[1]

    def command(self, op: p.Command, arg: str = "", timeout: float = 10.0) -> int:
        seq = self.next_seq()
        self._send(p.encode_command(seq, op, arg))
        return self.wait_ack(seq, timeout)

    def shutdown(self, timeout: float | None = None) -> None:
        with self._cond:
            self._acks.pop(0, None)
        self._send(p.encode(p.Type.SHUTDOWN))
        self.wait_ack(0, timeout)

    def close(self) -> None:
        self.closed = True
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()


class HumanHasControl(PadError):
    pass


class ConsoleInUse(PadError):
    """Another agent has claimed the console (the app's `leased` code)."""


@dataclass
class LinkStatus:
    connected: bool
    host: str
    port: int
    hello: p.Hello | None
    error: str | None
    reconnects: int
    states_sent: int
    human_active: bool


class PadController:
    """Keeps one PadLink alive and streams the merged state.

    - Agent and keyboard each own a PadState. While any key is held the keyboard wins
      and agent writes raise HumanHasControl.
    - Changes are sent immediately; the current state is repeated every `keepalive`
      seconds so padd's 1 s watchdog never fires during a deliberate hold.
    - After every (re)connect the state is reset to neutral before anything else is sent.
    """

    def __init__(self, host: str, port: int = p.PORT, keepalive: float = 0.1, connect=PadLink):
        self.host, self.port, self.keepalive = host, port, keepalive
        self._connect = connect
        self._lock = threading.Condition()
        self._agent = PadState()
        self._keys: dict[str, PadState] = {}
        self._link: PadLink | None = None
        self._dirty = True
        self._stop = False
        self.error: str | None = None
        self.reconnects = 0
        self.states_sent = 0
        self.on_change = None  # callable(LinkStatus), e.g. to retitle the viewer
        self.recorder = None   # recording.Recorder while recording
        self.on_connected = None  # callable(), run in its own thread after every (re)connect
        self._thread = threading.Thread(target=self._run, daemon=True, name="pad-controller")
        self._thread.start()

    # -- inputs ---------------------------------------------------------------
    def set_agent(self, state: PadState) -> None:
        with self._lock:
            if self._keys and not state.is_neutral():
                raise HumanHasControl("a human is holding keys in the viewer window; try again when released")
            self._agent = state
            self._dirty = True
            self._note()
            self._lock.notify_all()

    def key(self, name: str, state: PadState | None) -> None:
        """Keyboard layer: `state` while the key is down, None on release."""
        with self._lock:
            if state is None:
                self._keys.pop(name, None)
            else:
                self._keys[name] = state
                self._agent = PadState()  # a human taking over cancels any agent hold
            self._dirty = True
            self._note()
            self._lock.notify_all()

    def release_keys(self) -> None:
        with self._lock:
            self._keys.clear()
            self._dirty = True
            self._note()
            self._lock.notify_all()

    def release_all(self) -> None:
        with self._lock:
            self._keys.clear()
            self._agent = PadState()
            self._dirty = True
            self._note()
            self._lock.notify_all()

    def _note(self) -> None:
        """Called with the lock held after any input change."""
        if self.recorder is not None:
            self.recorder.note(self._merged())

    def start_recording(self):
        from .recording import Recorder
        with self._lock:
            self.recorder = Recorder()
            self.recorder.note(self._merged())
            return self.recorder

    def stop_recording(self) -> list[dict]:
        with self._lock:
            recorder, self.recorder = self.recorder, None
        return recorder.steps() if recorder else []

    def current(self) -> PadState:
        with self._lock:
            return self._merged()

    def _merged(self) -> PadState:
        if self._keys:
            state = PadState()
            for key_state in self._keys.values():
                state = state.merged(key_state)
            return state
        return self._agent

    # -- link -----------------------------------------------------------------
    def link(self, wait: float = 0.0) -> PadLink:
        deadline = time.monotonic() + wait
        while True:
            with self._lock:
                link = self._link
            if link and not link.closed:
                return link
            if time.monotonic() >= deadline:
                raise PadError(f"padd not connected at {self.host}:{self.port}: {self.error or 'connecting'}")
            time.sleep(0.05)

    def status(self) -> LinkStatus:
        with self._lock:
            link = self._link
            return LinkStatus(bool(link and not link.closed), self.host, self.port, link.hello if link else None,
                              self.error, self.reconnects, self.states_sent, bool(self._keys))

    def _notify(self) -> None:
        if self.on_change:
            try:
                self.on_change(self.status())
            except Exception:  # noqa: BLE001, S110 - a UI hook must never stop input
                pass

    def _run(self) -> None:
        backoff = 0.25
        while not self._stop:
            try:
                link = self._connect(self.host, self.port)
            except PadError as exc:
                self.error = str(exc)
                self._notify()
                time.sleep(backoff)
                backoff = min(backoff * 2, 5.0)
                continue
            except OSError as exc:
                self.error = str(exc)
                self._notify()
                time.sleep(backoff)
                backoff = min(backoff * 2, 5.0)
                continue
            backoff = 0.25
            with self._lock:
                self._agent = PadState()
                self._keys.clear()
                self._link = link
                self._dirty = True
                self.error = None
            self._notify()
            if self.on_connected:
                threading.Thread(target=self.on_connected, daemon=True, name="pad-on-connected").start()
            try:
                self._stream(link)
            except PadError as exc:
                self.error = str(exc)
            finally:
                link.close()
                with self._lock:
                    self._link = None
                self.reconnects += 1
                self._notify()

    def _stream(self, link: PadLink) -> None:
        last_sent = 0.0
        while not self._stop:
            with self._lock:
                if not self._dirty:
                    self._lock.wait(max(0.0, self.keepalive - (time.monotonic() - last_sent)))
                state = self._merged()
                self._dirty = False
            if link.closed:
                raise PadError(link.error or "connection closed")
            link.send_state(state)
            self.states_sent += 1
            last_sent = time.monotonic()

    def close(self, neutral: bool = True) -> None:
        if neutral:
            self.release_all()
            time.sleep(min(0.05, self.keepalive))
        self._stop = True
        with self._lock:
            self._lock.notify_all()
            link = self._link
        if link:
            if neutral:
                try:
                    link.send_state(PadState(), wait=True, timeout=1.0)
                except PadError:
                    pass
            link.close()
