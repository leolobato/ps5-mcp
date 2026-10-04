"""ps5mcp command line: capture, viewer, MCP server, padd lifecycle and explicit hardware steps."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

from . import capture


def _devices(_args) -> int:
    devices = capture.list_devices()
    print("video:", *(f"  {d}" for d in devices.video), sep="\n")
    print("audio:", *(f"  {d}" for d in devices.audio), sep="\n")
    return 0


def _backend(args):
    if getattr(args, "backend", None) == "ffmpeg":
        return capture.Daemon()
    if getattr(args, "backend", None) == "native":
        return capture.NativeApp()
    return capture.backend()


def _capture(args) -> int:
    backend = _backend(args)
    name = type(backend).__name__
    if args.action == "start":
        pid = backend.start(video=args.video, audio=None if args.no_audio else args.audio)
        print(f"{name} running (pid {pid})")
    elif args.action == "stop":
        stopped = [type(b).__name__ for b in (capture.NativeApp(), capture.Daemon()) if b.stop()]
        print(f"stopped {', '.join(stopped)}" if stopped else "not running")
    else:
        pid, age = backend.pid(), backend.frame_age()
        print(f"{name} running pid {pid}, frame age {age:.2f}s" if pid else f"{name} not running")
        return 0 if pid else 1
    return 0


def _view(args) -> int:
    backend = _backend(args)
    if isinstance(backend, capture.NativeApp):
        pid = backend.start(visible=True)
        print(f"PS5 app shown (pid {pid}); keys in its window drive the console")
        return 0
    if backend.pid() is None:
        backend.start()
    command = capture.view_command(ipc=backend.root / "mpv.sock")
    if args.detach:
        log = (backend.root / "view.log").open("ab")
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                   start_new_session=True)
        (backend.root / "view.pid").write_text(f"{process.pid}\n")
        print(f"viewer running (pid {process.pid})")
        return 0
    os.execvp(command[0], command)


def _running_app():
    """A connection to the PS5 app if it runs (it then owns padd's only client slot), else None."""
    from . import hub
    if os.environ.get("PS5MCP_IN_APP") == "1":  # the app itself runs this CLI with its link paused
        return None
    try:
        return hub.AppClient(capture.NativeApp().socket, client="cli")
    except hub.AppNotRunning:
        return None


def _latency(args) -> int:
    from . import latency
    return latency.run(_host(args), samples=args.samples)


def _control(args) -> int:
    """Show the PS5 app (keyboard control lives in its window); optionally record until Ctrl-C."""
    import signal
    import threading

    from . import hub, recording, vision
    if args.record:
        vision.check_name(args.record)
    client = hub.connect(client="control", visible=True)
    recorder = recording.Recorder() if args.record else None
    if recorder is None:
        print("PS5 app shown; keys in its window drive the console.")
        client.close()
        return 0
    recorder.note(hub.state_from_json(client.call("state")["state"]))
    client.on("state", lambda event: recorder.note(hub.state_from_json(event["state"]), event["t"]))
    client.subscribe("state")
    stopped = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stopped.set())  # background jobs ignore SIGINT; TERM must save too
    print(f"recording keys from the PS5 window as {args.record!r}; Ctrl-C to stop and save.", flush=True)
    try:
        while not stopped.wait(0.5):
            pass
    except KeyboardInterrupt:
        pass
    finally:
        steps = recorder.steps()
        client.close()
        path = recording.save(capture.state_dir(), args.record, steps, source="keyboard")
        print(f"saved {len(steps)} steps to {path}")
    return 0


def _play(args) -> int:
    """Replay a recording with its original timing, through the PS5 app (launched if needed)."""
    import time

    from . import hub, recording
    from .protocol import PadState
    steps = recording.load(capture.state_dir(), args.name)
    client = hub.connect(client="play")
    try:
        deadline = time.monotonic()
        for index, step in enumerate(steps):
            client.set(recording.step_to_state(step), wait=5.0 if index == 0 else 0.0)
            deadline += step["duration_ms"] / 1000
            time.sleep(max(0.0, deadline - time.monotonic()))
        client.set(PadState())
        time.sleep(0.1)
    finally:
        client.close()
    print(f"played {args.name}: {len(steps)} steps")
    return 0


def _stream(args) -> int:
    from . import stream
    server = stream.make_server(args.bind, args.port, stream.backend_frames(), fps=args.fps)
    print(f"MJPEG stream on http://{args.bind}:{args.port}/ (Ctrl-C to stop)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


def _serve(_args) -> int:
    from . import server
    server.main()
    return 0


def _snapshot(args) -> int:
    path = capture.snapshot(Path(args.output), max_width=args.max_width)
    luma = capture.mean_luma(path)
    print(f"{path} (mean luma {luma:.1f})")
    if luma < 3:
        print("Frame is black. Turn off HDCP on the PS5: Settings > System > HDMI > Enable HDCP.",
              file=sys.stderr)
        return 2
    return 0


def _host(args) -> str:
    """--host, else PS5_HOST; exits with a hint when neither is set."""
    try:
        return capture.console_host(args.host)
    except capture.CaptureError as exc:
        raise SystemExit(f"ps5mcp: {exc}") from None


def _padd(args) -> int:
    from . import padd_runner
    if args.action in ("start", "stop", "status") and (app := _running_app()):
        return _padd_via_app(app, args)
    if args.action == "start":
        return padd_runner.start(_host(args), args.firmware)
    if args.action == "soak":
        return padd_runner.soak(_host(args), args.minutes)
    if args.action == "collect":
        evidence = padd_runner.collect()
        print(evidence["status"])
        return 0
    return getattr(padd_runner, args.action)(_host(args))


def _padd_via_app(app, args) -> int:
    """The app holds padd's link: it pauses it and runs this same CLI for start/stop."""
    import json
    try:
        if args.action == "status":
            status = app.call("status", wait=1.0)
            print(json.dumps({"pad": status["pad"], "pong": app.ping() if status["pad"]["connected"] else None},
                             indent=2))
            return 0 if status["pad"]["connected"] else 1
        result = app.call(f"padd_{args.action}", firmware=args.firmware, timeout=180)
    except Exception as exc:  # noqa: BLE001 - shown to the user as is
        print(f"padd {args.action} through the PS5 app failed: {exc}")
        return 1
    finally:
        app.close()
    print(result.get("output", ""))
    return 0 if result.get("ok") else 1


def _pad_via_app(app, args) -> int:
    from . import protocol
    try:
        if args.action == "press":
            app.press(protocol.PadState(buttons=protocol.button_mask(args.args)), args.hold_ms)
            return 0
        if args.action == "assign":
            print("the PS5 app answers the assignment dialog by itself after every connect")
            return 0
        status = app.command(args.action, args.args[0] if args.args else "")
    finally:
        app.close()
    print(protocol.uninstall_text(status) if args.action == "uninstall"
          else f"status {status & 0xFFFFFFFF:#010x}" if status < 0 else f"status {status}")
    return 0 if status == 0 else 1


def _install(args) -> int:
    from . import installer
    try:
        print(installer.install(_host(args), args.file, run=args.run, progress=lambda line: print(line, flush=True)))
    except Exception as exc:  # noqa: BLE001 - shown to the user as is; the app shows the last line
        print(f"install failed: {exc}")
        return 1
    return 0


def _transfer(args) -> int:
    from . import transfer
    run = transfer.push if args.command == "push" else transfer.pull
    try:
        print(run(_host(args), args.source, args.dest, lambda line: print(line, flush=True), force=args.force,
                  autostart=transfer.AUTOSTART and not args.no_start))
    except Exception as exc:  # noqa: BLE001 - shown to the user as is
        print(f"{args.command} failed: {exc}")
        return 1
    return 0


def _pad(args) -> int:
    import time

    from . import protocol
    from .client import PadLink
    if app := _running_app():
        return _pad_via_app(app, args)
    link = PadLink(_host(args))
    try:
        if args.action == "press":
            link.send_state(protocol.PadState(buttons=protocol.button_mask(args.args)), wait=True)
            time.sleep(args.hold_ms / 1000)
            link.send_state(protocol.PadState(), wait=True)
            return 0
        if args.action == "assign":
            from .padd_runner import auto_assign
            answered = auto_assign(link, timeout=2.0)
            print("answered the assignment dialog" if answered else "no assignment dialog on screen")
            return 0
        if args.action == "home":
            status = link.command(protocol.Command.HOME, args.args[0] if args.args else "")
        elif args.action == "close":
            status = link.command(protocol.Command.CLOSE)
        elif args.action == "uninstall":
            status = link.command(protocol.Command.UNINSTALL, args.args[0])
        else:
            status = link.command(protocol.Command.LAUNCH, args.args[0])
        print(protocol.uninstall_text(status) if args.action == "uninstall"
              else f"status {status & 0xFFFFFFFF:#010x}" if status < 0 else f"status {status}")
        return 0 if status == 0 else 1
    finally:
        link.close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="ps5mcp", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("devices", help="list AVFoundation capture devices").set_defaults(func=_devices)

    cap = sub.add_parser("capture", help="manage the daemon that owns the capture card")
    cap.add_argument("action", choices=("start", "stop", "status"))
    cap.add_argument("--video", default=capture.DEFAULT_VIDEO)
    cap.add_argument("--audio", default=capture.DEFAULT_AUDIO)
    cap.add_argument("--no-audio", action="store_true")
    cap.add_argument("--backend", choices=("native", "ffmpeg"))
    cap.set_defaults(func=_capture)

    view = sub.add_parser("view", help="open the PS5 app window (live video, audio, keyboard; starts it if needed)")
    view.add_argument("--detach", action="store_true", help="ffmpeg backend: return immediately, leave mpv open")
    view.add_argument("--backend", choices=("native", "ffmpeg"))
    view.set_defaults(func=_view)

    snap = sub.add_parser("snapshot", help="save the current frame")
    snap.add_argument("-o", "--output", default="snapshot.png")
    snap.add_argument("--max-width", type=int)
    snap.set_defaults(func=_snapshot)

    padd = sub.add_parser("padd", help="padd payload lifecycle (start DEPLOYS to the console; nothing relaunches). "
                          "start/stop/status go through the PS5 app when it runs; soak and killtest need padd to "
                          "themselves, so quit the app first")
    padd.add_argument("action", choices=("start", "status", "soak", "killtest", "stop", "collect"))
    padd.add_argument("--host", help="console IP address (default: PS5_HOST)")
    padd.add_argument("--firmware", default="13.60", help="user-reported firmware; not independently verified")
    padd.add_argument("--minutes", type=float, default=10)
    padd.set_defaults(func=_padd)

    pad = sub.add_parser("pad", help="one-off input through a running padd (through the PS5 app when it runs)")
    pad.add_argument("action", choices=("press", "home", "launch", "close", "uninstall", "assign"))
    pad.add_argument("args", nargs="*", help="buttons for press, title id for launch and uninstall, method for home")
    pad.add_argument("--hold-ms", type=int, default=80)
    pad.add_argument("--host", help="console IP address (default: PS5_HOST)")
    pad.set_defaults(func=_pad)

    inst = sub.add_parser("install", help="install a .pkg (through Web File Manager) or an .elf payload (into "
                          "Payload Manager) on the console")
    inst.add_argument("file", type=Path)
    inst.add_argument("--run", action="store_true", help="also run the .elf once it is installed")
    inst.add_argument("--host", help="console IP address (default: PS5_HOST)")
    inst.set_defaults(func=_install)

    for name, source, dest in (
            ("push", "local file or folder", "absolute console path (end with / to copy into it)"),
            ("pull", "absolute console path", "local path (an existing folder or one ending in / receives it)")):
        cmd = sub.add_parser(name, help=f"copy {'to' if name == 'push' else 'from'} the console over FTP (zftpd, "
                             "started from Payload Manager when needed; Web File Manager otherwise)")
        cmd.add_argument("source", help=source)
        cmd.add_argument("dest", help=dest)
        cmd.add_argument("--force", action="store_true", help="copy unchanged files too")
        cmd.add_argument("--no-start", action="store_true", help="never start zftpd")
        cmd.add_argument("--host", help="console IP address (default: PS5_HOST)")
        cmd.set_defaults(func=_transfer)

    lat = sub.add_parser("latency", help="time a padd button press until the captured frame changes")
    lat.add_argument("--host", help="console IP address (default: PS5_HOST)")
    lat.add_argument("--samples", type=int, default=10)
    lat.set_defaults(func=_latency)

    sub.add_parser("serve", help="run the MCP server on stdio").set_defaults(func=_serve)
    control = sub.add_parser("control", help="show the PS5 app window (keyboard control); --record saves your keys")
    control.add_argument("--record", metavar="NAME", help="record the session; saved on Ctrl-C")
    control.set_defaults(func=_control)

    play = sub.add_parser("play", help="replay a saved recording through padd")
    play.add_argument("name")
    play.set_defaults(func=_play)

    stream_cmd = sub.add_parser("stream", help="serve the capture as MJPEG for browsers")
    stream_cmd.add_argument("--port", type=int, default=8090)
    stream_cmd.add_argument("--bind", default="127.0.0.1", help="0.0.0.0 to watch from other machines")
    stream_cmd.add_argument("--fps", type=float, default=10)
    stream_cmd.set_defaults(func=_stream)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except capture.CaptureError as exc:
        print(f"capture error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
