# Implementation findings

These findings were validated on PS5 firmware 13.60. The interface details are in
[Virtual-pad ABI](vpad-abi.md), [Wire protocol](protocol.md), and [App API](app-api.md).

## Virtual controller assignment

Creating the virtual pad shows “Who's using this controller?”. Until the virtual pad
answers with Cross, the console ignores its input. Matching the dialog title before
pressing Cross avoids sending input to unrelated screens; no SceShellCore patch is needed.

Assigning the virtual pad turns the physical DualSense off. Press its PS button and
select the same user again to use both controllers together. Dismissing the assignment
dialog leaves the virtual pad unusable.

## Input and cleanup

- The `/dev/hid` AddDevice, InsertData, and DeleteDevice ioctls work on 13.60.
  The user ID belongs in the device descriptor; no separate binding call is needed.
- An accepted report does not prove its layout is correct: the ioctl validates the
  request header. A zeroed report is also not neutral; centered sticks use `0x80`.
- Touch coordinates are accepted by the protocol but are not mapped to the console.
  The touchpad click button works.
- Killing the payload through Payload Manager can bypass device removal and leave
  a phantom controller until reboot. Stop it through the app or `ps5mcp padd stop`.
- Disconnects and the input watchdog release held input. Reconnecting starts neutral.

## Home and app control

The virtual-pad report cannot send the PS button or open the quick menu. Suspending
the running game, closing it, and launching a title work through system services.
The other Home methods returned success without visibly navigating home.
See [PS button and app control](ps-button.md) for calls, return values, and limitations.

Only the side that launched a game can control it. When the MCP launches a title (`launch`), the game takes input
from the virtual pad only and ignores the physical DualSense. When the physical controller starts it, the game ignores
the virtual pad. To drive a game through the MCP, launch it through the MCP.

## Payload Manager and Web File Manager

Two services on the console do the file work. **Payload Manager** (port 8084) keeps a library of ELF payloads:
`/manage:upload` adds one, `/list_payloads` lists them and `/loadpayload:<path>` runs one. `padd start` and
`ps5mcp install` (for `.elf`) use it. **PS5 Web File Manager** (port 8888, itself a payload) lists and transfers
files and installs packages. The app's game/app list and `ps5mcp install` (for `.pkg`) use it.

- Web File Manager runs one task at a time. `/api/download/prepare` and `/api/upload/prepare` create a task, and the
  task blocks every other call, `/api/list` included, with HTTP 409 "another task is running" until it is downloaded
  or finished with `/api/upload/finish`. Fetch files one at a time and always finish a prepared task.
- A missing file answers HTTP 404 with `ok: false`.
- `/api/install-pkg` (`paths`) installs a `.pkg` that is already on the console and runs as a `pkg_install` task.
- Neither service uninstalls apps. padd 1.3 does, with `sceAppInstUtilAppUnInstall` (COMMAND op 4). It returns
  once the request is accepted and the files go away afterwards; the console refuses while a game is running.
- ShadowMountPlus (API on 127.0.0.1:10101 only) marks its titles with `/user/app/<id>/mount.lnk` and installs them
  again from their source on its next scan, so a plain uninstall does not last. padd deletes the source first with
  ShadowMountPlus's `/api/v1/games/delete` job (it unmounts the title, refuses an image shared by several titles and
  holds the scanner), waits for the job, then uninstalls.
- ShadowMountPlus registers only `PPSA`, `CUSA` and `FAKE` title ids; a folder in `/data/homebrew` with any other id is
  ignored. A new `FAKE` folder there is registered within about 10 s.
- Verified on 13.60: a `.pkg` installs through `ps5mcp install` (Web File Manager upload, then `/api/install-pkg`),
  and both a regular title and a ShadowMountPlus title uninstall through padd and stay uninstalled.
- Game names are in `/user/appmeta/<id>/param.json` (`localizedParameters`); the icon is `icon0.png`. System apps
  and homebrew may have no `appmeta`.

## macOS capture

Only one process can own the capture card, so the native app owns both capture and
the payload connection. Agents and keyboard input share that app through its local API.
Video uses `AVCaptureVideoPreviewLayer`; audio uses `AVCaptureAudioPreviewOutput`.

HDCP must be disabled. Launching the signed bundle through `open` gives the app its
own camera and microphone permissions. The ffmpeg fallback needs terminal permissions;
a daemonized terminal session may never show the permission prompt.

## Remote Play preflight (2026-10-15)

The configured console is reachable after boot, with padd1.4 and Payload Manager0.5.2.
A read-only helper matched the foreground local user to registry slot1: account ID
and sign-in flag are both zero. No account state has been modified.

The TV path is **Settings → System → Remote Play → Pair Device**. On this fresh
offline account, Enable Remote Play is unavailable and Pair Device displays
**NP-102937-2**, "Sign in to use online features." The dialog was dismissed; no
PSN login was attempted. This establishes the current setup blocker, not whether
the proposed account preparation fixes it or whether a reboot is needed.

Local static Chiaki-ng builds pass on arm64 and x86_64 (the Intel probe ran under
Rosetta). The native app executable links only system libraries/frameworks.
Pairing, live media, padd coexistence, latency, and visual-template thresholds
still need hardware acceptance.

The first approved account preparation attempt stopped at `backup-read` while
reading registry values, before account writes. The user then reserved their
original account for manual UX testing. A separate local **User1** was created
through the TV flow for agent tests; read-only inspection identifies it as
foreground registry slot2 with a zero account ID and sign-in flag. Subsequent
preparation experiments must target that new account only.

On User1/slot2, a status-only diagnostic isolated the backup failure to legacy
registry key `125830144 + 65536` (config offset0x48). It returns `0x800d0203`
for the integer getter and twelve string/binary type-size probes; all other22
manifest keys read successfully. The helper now recognizes only this exact
legacy key/error on the13.60 profile as unsupported, records an explicit status
marker in snapshotv2, and never writes that key. Other errors still abort.
Status must remain consistent through final verification. This is a measured
compatibility adjustment, not a general permission to ignore registry errors.

The hardware's raw SDK firmware value is `0x13600007`, while its major/minor
profile is13.60. An initial exact comparison with `0x13600000` incorrectly
disabled the compatibility adjustment. The status-only diagnostic now reports
both the raw value and a reproducible source build ID; the reported diagnostic
ID matched the locally built ELF. The blocked attempts performed no account
writes. Firmware checks must compare the intended major/minor profile rather
than discarding or assuming the lower revision bits.

After correcting the firmware-family check, User1 preparation passed backup
creation but failed a registry write/readback. The response retained the
`registry-write` code rather than `recovery-required`, indicating the helper
reported successful rollback. The pending-state marker is absent and the durable
34,744-byte snapshot remains available. Independent verification against that
snapshot is required before another preparation attempt. A separate read-only
probe confirmed all 23 checked original-account registry fingerprints and both
account-file fingerprints are identical to their pre-experiment baseline.

The capture-card input-to-frame baseline measured six menu inputs: median
151.2 ms, minimum140.6 ms, maximum154.6 ms. Remote Play comparison is pending.
The latest `make check` passed 284 tests and both payload hash verifications;
this does not establish live stream acceptance.

The independent restoration checker subsequently passed on User1: exact snapshot
schema and original account ID, all 23 registry values/statuses, both file
contents/presence, absent pending marker, and stable foreground identity. One
explicit diagnostic retry then isolated the failure to integer registry key
125896448 (base125830912, config offset0xA4): setter and getter both return0, but
readback differs at byte1. The preceding11 field writes/readbacks pass. The
metadata-only transaction trace reports `restored:true`; a second independent
restoration check again passed. Field semantics remain under investigation; no
comparison has been relaxed and pairing has not been attempted.

A read-only A4 probe initialized six getter outputs with different sentinel
values. Every successful read returned `0xfffffbff`; the getter is deterministic
and does not leave the tested sentinel bytes unchanged. A separate, reviewed
User1-only experiment then wrote the pinned template's `0xfffff9ff`, read back
`0xfffffbff` despite successful setter/getter statuses, restored the original
value, and verified the complete backup comparison before clearing its durable
marker. The difference is bit0x200. This proves that the requested value does
not persist in this tested state; it does not establish that bit's meaning or
a safe normalization mask. Preserving this existing field is being evaluated
before another complete preparation attempt.

The six-integer preservation experiment advanced to extension string0x114C
(registry base125874195, size65). Its setter/getter both returned success, but
the wanted64-character string read back empty. Earlier extension strings0x1100
and0x1141 verified successfully. The transaction reported rollback and the
independent comparison of all readable registry values and both files passed.
The next bounded experiment preserves all65 existing bytes of0x114C and never
sets it. Its semantics are unknown: readback cannot exclude hidden effects from
the earlier setter. If User1 eventually works, an untouched fresh-account test
is needed before claiming the final recipe works from a clean state.

Preparation finally succeeded on User1 with helper build
`92b2b9d3bab456b6e7a8d1b8305b4cb05e2433928418b1147c331c9856dead39`.
A subsequent independent API inspection reported activated=true, signedIn=true,
and preparationVerified=true. The helper preserves the six opaque NP integers
and extension0x114C instead of copying their template defaults, with strict
full-size comparisons and no setters for those fields. The original account's
23 checked registry fingerprints and two file fingerprints still match baseline.

Without reboot, revisiting **Settings → System → Remote Play → Pair Device**
still displayed NP-102937-2. User1 was logged out to test a lighter service
refresh; the console then requested a physical controller's PS button, which
padd cannot send. Login refresh, reboot necessity, pairing, and streaming remain
unverified. No repeated preparation is warranted merely because pairing fails.

A temporary padd variant targeting User1 resolved the login-screen limitation.
The normal padd instance was stopped through SHUTDOWN; port9305 was closed and
Payload Manager listed no remaining padd process before loading the variant.
The variant initializes UserService, verifies User1's name for uid480174124, and
places that UID in the virtual controller descriptor. HELLO reported User1 with
a successful pad handle and no report failures. The console opened the user
picker with User1 selected; confirming Cross logged it in without a physical
controller. Production padd sources/bundle were not changed. Scratch ELF SHA256:
`643dc0b5f21f2038d4d03fc91dd8aa70b3835b366b7954d65a5c793e275fc566`.

After relogin, Pair Device still reports NP-102937-2. Read-only helper inspection
reports activated=true and signedIn=true, but preparationVerified=false. The
auth.dat file still exactly matches the1200-byte template. config.dat is now
16384 bytes, compared with the helper template's8192 bytes. Its contents differ
from the original pre-preparation config by only32 bytes, including the account
ID; the generated email is absent. Eight manifest fields match their current
registry values,14 readable fields do not, and the known unsupported field
returns its original error. This supports a cached-config overwrite during
logout/login; it does not yet establish a correct refresh/reboot workflow.
No preparation was repeated after discovering this mismatch.


### Online follow-up: Remote Play on 13.60 (2026-10-15)

Research-only follow-up; no console mutations or reboot performed.

- [Account Tools v1.2](https://github.com/MangoScango/ps5-account-tools/releases/tag/v1.2)
  is the already vendored commit 8d648ca. Its September 19 release note describes
  an SDK rebuild for 13.60 preparation, not a new native config format fix.
- The [current upstream instructions](https://github.com/MangoScango/ps5-account-tools#regarding-remote-play)
  specify activation, fake sign-in, then a full reboot. They warn that reaching
  PSN can invalidate fake sign-in and recommend blocking PSN before rebooting.
  Logout/login is not the documented substitute. Our current divergent state
  means a reboot would be a persistence diagnostic, not a verified setup test.
- [Account Tools source](https://github.com/MangoScango/ps5-account-tools/blob/8d648caef776d3b35af3faad36bc534b9127fe3c/src/npsignin.c)
  calls write_registry_state(cfg, 0) even for a later user slot, then writes the
  target slot. Our helper intentionally excludes those slot-1 writes. Therefore
  stock-tool success is not evidence that the isolated-slot recipe works.
  This observation does not establish whether base-slot writes are necessary,
  mistaken, or dependent on registry semantics. Do not deploy stock preparation
  against User1 while preserving leolobato-jb requires slot 1 remain unchanged.
- [idlesauce's PIN tool](https://github.com/idlesauce/ps5-remoteplay-get-pin)
  describes ShellUI gating that can be bypassed by direct Remoteplay PIN API
  calls. [ActRemoteLink's PIN source](https://github.com/francoataffarel/ActRemoteLink/blob/main/actremotelink_pin_notify.c)
  initializes Remoteplay, enables global/per-user registry settings, and invokes
  sceRemoteplayGeneratePinCode, then monitors registration. This is an avenue
  to test independently of the Settings UI; its success on our 13.60 console is
  unverified, and the enable/PIN operations are state changes, not read-only.
  Pairing alone also does not establish that session streaming succeeds.
- [Account Tools issue 1](https://github.com/MangoScango/ps5-account-tools/issues/1)
  includes reports of pairing succeeding but streaming failing on newly created
  offline users, with restored preactivated users working. Maintainer responses
  distinguish pairing/sign-in from session failure and mention an older Base64
  rendering bug. The thread does not establish a universal firmware cutoff or
  a proven fix for our failure.
- The original np-fake-signin GitHub repo moved to
  [the author's Forgejo repository](https://git.etawen.dev/earthonion/np-fake-signin).
  Its API reports v1.4 released October 2, rebuilt with SDK v0.43, with a note
  about dev-source runtime config generation. Public main remains c20b39ab;
  its PS5 source uses template config and base-plus-target registry writes,
  while ShellCore memory patching is guarded for PS4. The claimed dev branch
  was unavailable through the repository API. Do not infer that release v1.4
  fixes 13.60 persistence or safely targets only one user from its release note.

Next diagnostic order: verify PSN blocking while retaining LAN access; review
an isolated direct-PIN probe to separate ShellUI gating from registration and
streaming; use a normal reboot as a separately interpreted persistence check;
resolve native config/cache behavior before repeating account preparation.
Do not modify slot 1, relax file/registry validation, or claim an 8KiB/16KiB
format fix from these sources. The original native snapshot already disagreed
with five readable registry fields, so copying template offsets into a 16KiB
file is not yet a validated solution either.


### Direct PIN test on User1, without registry writes

User confirmed nanoDNS is running with console DNS configured to localhost.
UDP9302 discovery returned HTTP200, PS5, firmware13600007, request port997.
The reviewed scratch probe user1-direct-pin (ELF SHA256
1748769ef8245e58c588f04ded99da5fc5b19f70d8ba4ef4389fb27694d3ffa6)
validated User1 UID480174124/slot2, then called RemoteplayInitialize and
GeneratePinCode directly; both returned0. The standalone initialization hang
reported by older idlesauce code did not occur here. No registry setters or
account-file writers were present in this probe. Its hard90s deadline and
successful/failed pairing cleanup were checked with7 host fixtures.

Global rp_enable1098973184 read disabled; User1 key125925377 read enabled.
A fresh private PIN was consumed only with matching probeId/PID by the native
Chiaki registration harness. Registration failed with bridge code16 (invalid
response); native ConfirmDeviceRegist returned terminal state3 and error
0x80fc1041. The code's meaning is not established. Own-PIN cancellation returned
0x80fc0101; do not claim cancellation was verified. The private PIN file was
removed and the probe exited. Original account23fields+2files still match the
initial baseline afterward; nanoDNS remains running.

Next bounded hypothesis: temporarily enable only the global setting, preserving
and restoring its exact baseline with a durable marker and independent recovery
payload. No reason to rewrite the already-enabled per-user setting or account
identity. Registration success and streaming success remain separate gates.


### Global-enable isolation and explicit registration refusal

A separately reviewed guard (28 host enable/recovery fixtures) backed up only
key1098973184, durably recorded intent, enabled it and verified readback. User1's
already-enabled per-user setting and all account data were untouched. A fresh
PIN probe confirmed both settings enabled. Registration still failed with native
state3/error0x80fc1041, the same outcome as with global enable off.

A final fresh-PIN attempt during the same bounded enabled window used an isolated
copy of the client bridge whose logger emits only numeric HTTP status/application
reason. It observed HTTP403 and RP-Application-Reason0x80108b03. The pinned Chiaki
reason table does not label this value. Production bridge code16 is a generic
registration-failure mapping, not proof of a response-parser defect. No production
logging or source behavior was changed. Client Account-ID bytes match the current
User1 config account-ID bytes; config remains16384 bytes. No stream was started,
no registration keys were produced, and stock Chiaki comparison remains pending.

Guard PID125 completed its120-second window: restore setter/readback both0,
restoreVerified=true and markerCleared=true. All PIN/guard processes123/125/126/127
are absent afterward. Original account23registry/twofile fingerprints still match
baseline. nanoDNS was not stopped or reconfigured. User1-targeted padd remains
running. Final evidence: user1-global-restoration-result.json,
user1-direct-pin-global-enabled-result.json, user1-direct-pin-http-result.json,
original-integrity-after-global-pin.json under ignored results/remoteplay-feasibility.
HTTP numeric observations are recorded here; PIN/credential bodies were not logged.

This excludes disabled global enable as the sole cause in the current state.
The next refresh experiment is a normal reboot with nanoDNS restored before any
PSN contact; current native config/registry divergence still prevents describing
it as a clean prepared-account validation. No reboot, further account-template
writes, slot1 writes, or ShellUI injection was attempted during unattended tests.


### Stock Chiaki comparison and bounded console logging (2026-10-15)

The official unmodified Chiaki-ng v1.10.0 arm64 GUI was tested in a separate
`ps5mcp-user1-stock-registration` profile, using the same User1 account ID and
a fresh native PIN. Both global and per-user Remote Play enable were verified
true during registration. Stock Chiaki also received HTTP403 and application
reason0x80108b03 (displayed as unknown); native confirmation returned state3 /
0x80fc1041. This excludes our Swift/C wrapper as the sole cause, but does not
establish the meaning of the rejection. No credentials or stream were produced.

A reviewed read-only, nonblocking `/dev/klog` probe captured105490bytes over
90.092seconds, including existing backlog. It closed both handles normally,
without changing debug flags, account files, registry identity or nanoDNS.
Raw logs remain private in ignored results; absence of a message cannot establish
absence of a native service failure. The capture contains Remote Play UI/error-dialog
transitions and status events, plus generic authentication errors, but neither
registration error code and no explicit cause tying the rejection to an account
ID or cached service state.

The requested native-service account-ID comparison remains unverified. SDK
exports exist, but research and independent review found no verified real-PS5
prototype/context for the getter; PS4 callers and emulator declarations are
insufficient evidence. No guessed native getter was called. The established
client-ID versus on-disk-ID match does not prove Remote Play cached identity.

The global-enable guard restored the original value with successful readback and
cleared its marker. All three temporary processes129/130/131 exited. nanoDNS86
remained running. Original-account23registry/twofile fingerprints still exactly
match baseline. Stock Chiaki was closed; User1 padd remains available. No reboot
or further account preparation was performed. Evidence: stock-registration-result.json,
stock-klog-result.json, stock-global-result.json, original-integrity-after-stock.json,
and native-identity-research.txt under ignored results/remoteplay-feasibility.


### Post-reboot pairing succeeds; streaming remains blocked (2026-10-15)

User performed Restart PS5, signed into User1, and reloaded jailbreak/manager.
nanoDNS PID87 was running and padd identified User1. Read-only helper inspection
reported activated=true, signedIn=true, preparationVerified=false. Config remains
16384bytes, with94bytes differing from the pre-reboot capture; auth.dat remains
the exact1200byte pre-reboot file. Client account ID still matches config offset
0x100 (an initial scratch comparison mistakenly used0x1008; corrected before
registration). No account preparation was repeated.

A fresh native PIN probe (b594b209-c842-4798-baa8-f6d80aa84ee3, PID93) successfully
registered through our bridge: native state2, pairError0, registration credentials
saved privately and in Keychain. Global Remote Play was false and per-user true.
This is the first successful registration; reboot cleared the observed pairing
blocker without another template write, but does not identify its internal cause.

A25second native stream probe then disconnected with Chiaki reason2
(SESSION_REQUEST_UNKNOWN), zero video packets/decoded frames/audio samples.
The same test with the reviewed temporary global-enable guard also failed.
An isolated numeric-only logger identified stream application reason0x80108b12.
The reused logger prints a REGISTRATION_APPLICATION_REASON prefix even for
session logs; this observation belongs to streaming, not registration.
No stream success, padd coexistence under streaming, or full app acceptance is
claimed. A false preparationVerified value did not prevent registration, so the
current strict template check is not a complete test of pairing capability.

Original-account23 registry fingerprints and auth file still match the initial
baseline; its config file fingerprint changed across reboot. No original-account
write was performed by these probes; do not claim its entire disk state is
byte-identical after the console reboot. Evidence: post-reboot-files.json,
post-reboot-pin-result.json, post-reboot-stream-result.txt,
post-reboot-enabled-stream-result.txt, post-reboot-stream-diagnostic.txt,
original-integrity-after-reboot.json in ignored results/remoteplay-feasibility.

Post-reboot global guardPID95 restored its original value with verified readback
and cleared marker; temporary PIN/guard processes exited. nanoDNS remains running.

### Resumed session (2026-10-15, ~20:45): stock streaming and session klog

Console state on resume: production padd v1.4 connected as `leolobato-jb`; read-only
inspect lists only `leolobato-jb` logged in (foreground, not activated). User1 is
logged out. The user-reserved account was not touched.

- Our bridge (`stream-probe-diagnostic`) still gets application reason `0x80108b12`
  with User1 logged out — identical to the earlier User1-foreground result.
- **Stock Chiaki-ng v1.10.0 streaming with the same post-reboot credentials**
  (isolated profile `ps5mcp-user1-test`, PS5 target, imported by
  `external-profile`) is rejected with the same `Reported Application Reason:
  0x80108b12` on every retry. The rejection is console-side admission, not a defect
  in `rp_session_create` or our session parameters.
- A read-only 50 s `/dev/klog` capture (`session-klog.c`, no foreground guard,
  run 9731ab4d-…) spanning one session request contains no SceRemotePlay line about
  the request: only `AvControl RemotePlay Status (0 -> 0)` noise and the periodic
  PFAuthClient `0x8041013d` errors seen before. Klog does not explain the rejection.
- ActRemoteLink (README: `0x80108b12` = target user lacks NP files/registry sign-in
  state) writes the same per-slot registry fields as our helper, but differs in
  three ways: it mirrors the sign-in registry state into the **slot-1 base keys**
  (as upstream AccountTools does), it writes the six opaque NP integers from the
  template instead of preserving them, and it reboots directly after fake sign-in
  (we logged out/in first, which rewrote config into the native 16 KiB format).
  Its documented flow also requires the target user in the foreground for connect.

Evidence (ignored, private where named): `stock-stream-private.log`,
`session-klog-private.raw`, `session-klog.c`, `run-session-klog.py`.


## 2026-10-17 — verified app admission recovery and remaining acceptance

The product payload now passes stock/apply/media/idempotence/restore testing on
firmware13.60. Applying decoded1425 frames and1146720 audio samples at1920×1080;
restoring produced zero media and expected0x80108b12. Partial writes are rolled back
and reported, including protection-restore failure. The authenticated helper shares
the standalone runner, correlates mode/request/build, and exposes health without
account inspection. No account mutation or reboot was performed.

Worktree build30 automatically applied/verified admission from stock and streamed
real video/audio. Ten immediate reconnect cycles all recovered within11.61seconds.
Settings/setup and Retry Verification were exercised. A71-second recording contains
H.2641080p and non-silent stereo48kHz AAC; no long-duration drift claim. Full check:
386tests passed; both architecture builds passed. Five independent review findings
were corrected with regression tests.

padd controlled PS5 home while streaming. Antichamber rendered but did not visibly
respond to stick/Options; stick input also did nothing after disconnecting Remote
Play. The game/input baseline is unresolved, so game coexistence and30-minute game
acceptance are not passed. Remaining gates are listed in [Remote Play](remote-play.md#validation-status).
Admission is left applied, pairing and account backups retained.

### Why admission fails, and the per-boot patch (13.60)

SceRemotePlay resolves the RP registration key to the user ID (correct: the paired user), then calls a
libSceUserService property-7 validator. Property 7 is a daemon-computed per-user flag. It measured 0 for both tested
offline accounts, including after fake sign-in and a reboot, and has no public setter. Admission then rejects with
application reason `0x80108b12`. Its daemon-side source (SceShellCore) was not identified.

The approved fix NOPs the two failure jumps after the validator, at main-text offsets `+0x43B4B` (`78 18`) and
`+0x43B51` (`74 12`), so admission proceeds with the real user ID. The text base moves every boot. The payload
verifies a 32-byte context first and refuses anything else (`context-mismatch`), so other firmware is refused
safely. Writes use `kernel_set_vmem_protection(pid, page, 0x1000, 7)` → `kernel_proc_copyin` → protection 4;
`mdbg_copyin` fails on daemon text. Pointing the registry device entry at uid -1 instead passed admission but
delivered no media. Rollback: the restore variant, or a console reboot. Repeated apply is a no-op, not a rollback.

## 2026-10-17 — PS button and on-screen keyboard through Remote Play

The Remote Play session's own controller sends the PS button, and Chiaki's keyboard messages fill text fields.
On 13.60 (User1 session, release build 33 and worktree builds): the keyboard handshake did not affect connection or
streaming. A 100 ms PS tap opened and closed the control center. A 1 s hold went home, also from Search, where padd's
`home` does nothing. `type_text` replaced the Search text and was echoed back exactly, with and without submit.
Reject kept the text and showed the PS5's own keyboard. padd input worked before and after.

While the handshake is on, an opened text field shows "Use the keyboard on your Remote Play device" in place of the
PS5 keyboard, so padd and the DualSense cannot type until the app hands it back. The window's **Type…** and the
MCP `close_keyboard` do that. Whether a PS press on the Remote Play controller changes which controller a running
game follows was not measured.
