# Linux padd controller integration (Phase 3)

For Phase 3.5 assignment, Cross/PS, system-home navigation, D-pad and hold-cancellation
results, see [live hardware validation](linux-controller-hardware-validation.md).

Phase 3 is validated against localhost protocol fixtures and the compiled padd-host
recording stub only. No real PS5 connection or input was used. Capture hardware was
not accessed during this phase. The macOS Swift implementation is unchanged.

## Explicit configuration and offline default

The default is offline. Setting `PS5_HOST` alone does not create a padd connection.
Both an explicit host and `PS5MCP_ALLOW_CONSOLE=1` are required. The TCP port defaults
to 9305 and can be changed with `PS5MCP_PAD_PORT`.

For a separately authorised validation, configure the hub and each MCP client with:

```text
PS5MCP_BACKEND=linux
PS5MCP_ALLOW_CONSOLE=1
PS5_HOST=<explicit console IP>
PS5MCP_PAD_PORT=9305
PS5MCP_STATE=<shared state directory>
```

These are configuration instructions, not permission to connect. No real endpoint
has been configured or tested as part of Phase 3. `capture start --host ...
--padd-port ...` can supply the endpoint, but still requires the environment opt-in.
A missing host or invalid port fails before starting a connection. There is no
network discovery, account preparation, payload loading or pairing.

All sessions share the hub's one padd link. A hub already running offline must be
explicitly stopped and restarted to enable padd. An enabled client's requested
host/port must match an enabled running hub; it cannot silently attach to another
console. The controller starts only after the hub acquires its process lock.
Official Linux MCP/CLI clients also require opt-in before sending input to an
already enabled hub. The owner-only local socket is a same-user API, not an
authentication boundary against deliberately crafted requests.

## Supported MCP behavior

| Capability | Tools / implementation |
|---|---|
| Buttons and timed holds | `press`, `hold`, `ps_button` |
| Analogue input | `stick`, `trigger` |
| Touchpad click | `touchpad`; coordinates travel in the protocol but remain unmapped by padd |
| Timed automation | `sequence`, recordings and playback through the existing Python code |
| Input cleanup | `release_all`, session close, cancellation, inactivity and transport failure |
| Sharing | `claim_console`, `release_console`, FIFO waiting and idle expiry |
| Virtual controllers | `connect_controller`, `disconnect_controller`, `use_controller` when padd advertises support |
| Basic console commands | `home`, `close_app`, `launch` mapped to existing padd commands; mock-tested only |
| Diagnostics | Cached controller/user/connection data in `status`; read-only ping |
| Visual tools | Existing shared capture, snapshots, templates and viewer |

Virtual-controller connect selects the newly added controller. Linux deliberately
does not answer the console's user-assignment dialog automatically. A status notice
explains that a person must choose the user. Automatic assignment, profile OCR and
restoration of additional controllers after padd restarts remain unsupported.

Payload lifecycle, uninstall and arbitrary console commands are not accepted by
the Linux hub. Remote Play keyboard/GUI features remain unsupported. Existing
file-transfer/installer code is outside Phase 3 and was not exercised against a
console; this phase does not grant permission to use it.

## Connection and input safety

The Linux manager reuses `PadLink`, `PadController`, `PadState` and the existing
wire protocol. ACK checking is an optional extension to the shared Python
controller class, enabled by Linux without changing the Swift backend.

- A neutral state must be acknowledged before a new link is exposed as connected.
- Input states are repeated at approximately 100 ms intervals and ACK-checked.
  The default connection/input ACK timeout is 750 ms. A silent link is closed and
  retried, rather than indefinitely maintaining an unconfirmed hold.
- New input waits for any pending neutral state to be acknowledged, including
  same-button handoffs between agents; it cannot coalesce away that release.
- Linux input calls wait for acknowledgement. Timed holds start their duration
  after that acknowledgement and acknowledge their final neutral state.
- TCP failure and timeouts clear all local session states, interrupt holds and
  close the link. Reconnect starts neutral and never restores held input.
- A Linux local API timeout closes that session's Unix socket, so the hub sees EOF
  and cancels its work. MCP cancellation of a press also closes its session;
  cancelled sequences release their own input in `finally`.
- Sequence steps carry a session input epoch. A disconnect, release, claim change
  or expiry invalidates that epoch, so an old sequence cannot resume later steps
  after a fast reconnect. Queued requests are invalidated in the same way.
- Persistent low-level `set` input has an 11-second deadline, independent of claim
  refresh or read-only status traffic. MCP steps are capped at 10 seconds and
  update the state for each step. This bounds a hold from an alive but abandoned
  low-level client.
- Shutdown clears input and closes controller connections before slower capture
  teardown. Handshake failures close their sockets; reconnect backoff is
  interruptible during shutdown.

On an unreachable network, Linux cannot guarantee delivery of a release packet.
Safety then also depends on padd neutralising after disconnect or its configured
input watchdog (1000 ms by default in the current payload). This behavior still
needs real-console validation; no stronger physical guarantee is claimed.

## Claims and contention

Explicit claims remain FIFO, expire after inactivity and release on session EOF.
Acquiring an unowned claim clears earlier agent input. Losing a claim interrupts
that session's hold/sequence. Status, snapshots and ping remain available while
another session owns the claim.

Without an explicit claim, the first active input session owns input until it
releases or expires. A competing session gets an `in use`/`leased` response rather
than having its buttons or opposing axes merged into the first session. This is a
safety change from the Phase 1 Linux behavior. Claim the console for an entire
multi-step task, including pauses, to prevent another agent acting between steps.

Each session has one bounded work queue. EOF and emergency release are handled
independently of a long hold or command, and network waits do not hold the hub lock.
Read-only status remains responsive during command timeouts. A command already
sent cannot be undone by cancellation; timeout means its outcome may be unknown.
Compound controller commands check cancellation before follow-up mutations such
as selecting a newly connected controller. Commands are never automatically
replayed. The default console-command ACK timeout
is 10 seconds; telemetry refreshes have shorter bounded waits.

## Status

`status().payload` reports `enabled`, `connected`, host, port, HELLO/padd version,
connection error, reconnect count and sent-state count. The hub polls read-only
ping/`GET_USERS`/`GET_PADS` capabilities into cached connection/controller/user
metadata, which is cleared on disconnect. MCP status uses this cache instead of
waiting behind console commands. It does
not generate button presses, deploy payloads or answer assignment dialogs when
status is requested. `state` reads the current session state without resending it.
Older padd versions lacking those query capabilities report limited metadata.

## Offline validation

```sh
make test-linux
make check-linux
```

`tests/test_linux_controller.py` supplies a loopback-only wire-level padd server
with dropped ACKs, dropped command replies, forced disconnects and malformed HELLO
responses. Coverage includes explicit opt-in, custom ports, FIFO contention,
interrupted holds, emergency release, session EOF/local timeout, idle input expiry,
neutral reconnect, no sequence replay, cached status under contention, virtual
controllers, existing MCP tools and release-before-shutdown. The full Linux target
also includes the production payload logic compiled against its recording host
stub, synthetic capture and local HTTP/FTP fixtures.

No packages, personal configuration, console files or GitHub state are changed by
this validation. Real PS5 validation remains a separate, explicitly authorised step.

Phase 3 final result: **179 Linux regression cases passed**, including 24 new
controller cases. The 15 warnings came from existing anonymous-FTP fixtures.
Ruff, Python compilation and whitespace checks passed. No type checker is
configured or installed in this checkout. The local JUnit report is saved at
`build/validation-phase3/regressions.xml` (gitignored).
