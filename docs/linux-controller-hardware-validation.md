# Linux controller hardware validation — 2026-11-13

This public summary omits console addresses, account names/IDs, controller handles
and captured screen contents. Raw event logs, screenshots and detailed local
reports remain under gitignored `build/` and are not published.

## Tested results

The test used the Linux hub, physical HDMI capture and an already-running padd
1.10 payload (wire protocol 1). Unix sockets, loopback TCP and the configured padd
endpoint were reachable. A previous execution-environment socket restriction did
not recur; no application workaround was made.

| Check | Result |
|---|---|
| Handshake and controller assignment | Passed; existing logged-in profile assigned, no extra account used. |
| Short Cross and PS | 80 ms presses and neutral releases acknowledged. Short PS opened Control Center. |
| System home | One 1500 ms PS hold reached Games home; fresh captures verified home before D-pad input. |
| Short D-pad Left / Right | 80 ms each; visually confirmed adjacent-tile movement and return. |
| Timed cancellation | A 400 ms Left hold was interrupted early by release_all. Wire active-to-neutral interval was 85.604 ms; hold returned the expected interrupted result. |
| Neutral state | GET_STATE confirmed buttons/triggers zero, sticks centered at 128 and both touches inactive after release and before shutdown. |
| Cleanup | Final neutral acknowledged, TCP closed, hub/controller workers and FFmpeg stopped, socket removed and capture device released. |

All active reports and their first neutral releases received ACK status 0. The
long PS hold repeated active keepalives as one continuous hold. No command message
was sent during the resumed navigation/cancellation run. Host timings describe
socket observations, not physical display/input latency. Controller 1 remains
registered in the running payload after disconnect; this is its expected lifecycle.

The console was left at system home with neutral input. No unexpected behavior,
game launch, settings/file change or payload deployment occurred. The existing console application was observed without launch or modification.

## Limits and regression evidence

Live coverage is deliberately bounded. Analogue/touch input, multiple controllers,
active-hold TCP failure, watchdog recovery, launch/close/home command mappings and
Application-specific workflows are not established by these hardware results. Mock tests cover
input contention, ACK timeouts, session cancellation, reconnect neutrality,
sequence invalidation and command mapping. Automatic profile assignment is unsupported.

The resumed run passed 135 Linux regression cases with 15 existing anonymous-FTP
fixture warnings in 63.90 seconds, with no failures or skips. Ruff and whitespace
checks passed. Reproduce the offline checks with `make check-linux`; they use
synthetic video and local fixtures without accessing a PS5.

A capture-status defect found during validation was fixed: healthy capture now
preserves the controller assignment notice, while capture errors take priority.
Both outcomes have parametrized regression coverage.
