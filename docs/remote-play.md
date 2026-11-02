# Remote Play

Remote Play supplies LAN video and audio to the native macOS app. Controller
input still uses `padd`, except the on-screen keyboard (below); the
capture card, file, and synthetic sources remain available. The initial profile is SDR H.264 at 1080p60. Decoded frames are always
1920×1080 BGRA for snapshots, visual waits, and assignment detection.

## Validation status

The app streams real 1920×1080 video and audio on firmware 13.60 with the existing
prepared User1 account. Automatic verified admission recovery, ten immediate
reconnects (11.1–11.6 s each), live Settings/setup UI, app restart with Keychain
credentials, snapshots, `watch_change`, a 71-second MP4 (H.264 and non-silent AAC),
and the PS button and keyboard have been exercised. The setup window resizes down to
560×360 (checked at 560×480, light and dark appearance). These results do not establish
full capture-card replacement acceptance.

Still unverified, and required before replacing the capture card:

- game and physical-controller coexistence (Antichamber did not respond to tested
  padd input with Remote Play active or after disconnecting it; establish a
  known-working game/input baseline first), including whether a Remote Play PS
  press changes which controller a game follows
- reboot recovery with saved pairing (the user must be present for console reboots)
- 30-minute recording with measured A/V drift, and input-to-frame latency against HDMI
- network loss and recovery, and operation with HDMI physically disconnected
- fresh-account preparation and pairing; NP-template provenance before distribution

Evidence is local and ignored under `results/remoteplay-feasibility/`; it includes
private keys and account backups and must stay out of Git. Background is in
[findings](findings.md).

## Setup

1. Set the PS5 address in Settings. Start the jailbreak and Payload Manager
   on the console. TV/controller interaction is expected for initial setup.
2. Select Remote Play under Video source in Settings and open Set Up. Use
   Check Console to start the bundled helper and inspect accounts. Inspection
   does not prepare an account.
3. For a fresh offline account, select the intended foreground user and review
   Prepare Account's persistent-change confirmation. The helper preserves an
   existing nonzero account ID; a zero ID gets a newly generated ID. Original
   registry values and account files are backed up on the console before changes.
   Preparation failure reports the backup and whether writes may remain. Do not
   repeat preparation merely because pairing or streaming failed.
4. On the TV, enable Remote Play and obtain a fresh Pair Device PIN. Enter
   its eight digits and the account's eight-byte Base64 ID in the app. Inspection
   can fill the account ID; prepared accounts can use manual ID entry without
   starting the helper. A real PSN login is not part of this workflow.
5. Pair and wait for verification of both live video and audio. Keep `padd` running for controls. If account
   changes are not reflected in console settings, a reboot and jailbreak reload
   may be needed. The app does not reboot the console or restore the jailbreak.
   Reopen setup and inspect or pair again without repeating preparation.

On the target console, the menu is Settings → System → Remote Play → Pair Device.
Before preparation it returns NP-102937-2 (Sign in to use online features);
Enable Remote Play is unavailable. The existing test account became pairable after a prior user-performed reboot;
a fresh-account reproduction remains unverified. The helper currently limits preparation to 13.60 and
rejects ambiguous user-to-registry mappings. It does not claim universal
compatibility with existing account states.

## Source selection and recovery

Settings saves the source after Apply & Restart Capture. `--video remoteplay`
overrides the saved source for one launch; Python launchers also accept
`PS5MCP_VIDEO=remoteplay`. Remote Play audio is implied by this source. Playback
mute affects speakers, while recording continues receiving audio. Remote Play
requires the native backend; the ffmpeg backend rejects it.

Headless startup uses saved credentials or exposes a setup-needed error through
the existing API. It never launches account preparation. Registration secrets
are stored in macOS Keychain, indexed by console MAC and account ID; ordinary
preferences contain only a lookup reference. Forget removes the stored secret.
A session checks the responding console MAC before sending credentials.

On stream loss, snapshots and preview are cleared, held controls are released,
and new presses are rejected until video returns. Connection failures may retry;
an identity mismatch requires explicit repair. Active video recording is finalized
to a file in the app state directory and reported in the app notice.

On supported firmware, the first admission rejection can trigger a temporary,
verified compatibility operation through the authenticated helper. Payload Manager
must be available. The app checks the correlated response and waits for native
session shutdown and recording finalization before retrying; upload success alone
is insufficient. Admission does not prepare accounts or write account registry values.
Stop/source changes cancel local work and invalidate callbacks. Unsupported contexts
require explicit attention. If the console's Remote Play service dies, the PS5 restarts
it without the patch and refuses sessions with `0x80108b15` ("crashed"; also seen with
Remote Play turned off in Settings). The app then stops retrying and names both causes. Restore or a console reboot removes the temporary patch;
repeated apply is a no-op, and Forget only removes pairing credentials.

## Builds and licenses

`make bootstrap` fetches pinned sources; `make app` builds the static Chiaki-ng
core, setup helper, and native app. Use `APP_ARCH=x86_64` for an Intel build.
Builds do not contact the console. See [dependency details](../third-party/README.md)
for pins, required build tools, library audits, and source locations.

PS5 MCP is now AGPL-3.0-only. Preserve the upstream Chiaki OpenSSL permission,
individual dependency licenses, and the separately built GPL account helper's
notices. The app includes texts under `Contents/Resources/Licenses`; distributing
binaries also requires providing their matching source, pinned submodules,
dependency sources, and build instructions under the applicable licenses.

## PS button and on-screen keyboard

Remote Play's own controller can fill the PS5's on-screen keyboard, so while Remote
Play is the video source the MCP has `type_text` and `close_keyboard`, and the window
has **Type…**. They follow the same rules as padd input and need live video. The PS
button goes through padd now, and the app's `rp_button` remains for older MCP servers;
a press held there is released when the hold is cancelled. All other input stays on padd. See [PS button](ps-button.md)
and the [API](app-api.md#remote-play-controller-ps-button-and-on-screen-keyboard).

## Console state and rollback

- The admission patch lives in memory until the restore variant runs or the console
  reboots. Pairing credentials are in the Mac's Keychain; Forget removes them only.
- Account preparation backs up the original state on the console
  (`/data/ps5mcp-signstate-backup.bin` for the tested User1); keep it until the fake
  sign-in state no longer needs undoing. Never write slot-1/base registry keys: that
  account is reserved.

Full Remote Play controller input, PSN OAuth, internet traversal, HDR, microphone
forwarding, and automatic wake are deferred.
