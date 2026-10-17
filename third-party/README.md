# Remote Play native dependencies

`chiaki-ng` is an unmodified Git submodule pinned to
`c8bea2642d0e95402f373af55584a3b98cd89417`. Its nanopb, Jerasure,
GF-Complete, and curl submodules are pinned by that upstream commit.
Only those four nested dependencies are needed for the core build.

Run from the repository root on macOS with Xcode command line tools,
CMake, Ninja, pkg-config, Perl, and make installed:

```sh
python3 scripts/bootstrap.py
python3 scripts/build-remoteplay.py --arch arm64
# Intel build, including when cross-compiling on Apple Silicon:
python3 scripts/build-remoteplay.py --arch x86_64
```

Bootstrap verifies cached archives against `toolchain.lock.json` and initializes
the required submodules. `--remoteplay-only` skips the payload SDK. Source
archives are extracted into `.deps/remoteplay/sources/`; build outputs are
isolated by architecture under `.deps/remoteplay/<arch>/`. Build and archive
cache integrity errors require moving aside the identified directory/file
before retrying. No command above contacts a console.

`python3 scripts/build-remoteplay.py --arch arm64 --config` prints JSON paths
for the consuming target without building. The install prefix contains public
headers under `include/` and these static archives under `lib/`, in link order:

```text
libchiaki.a libprotobuf-nanopb.a libjerasure.a libgf_complete.a
libopus.a libjson-c.a libminiupnpc.a libevent.a libcurl.a
libssl.a libcrypto.a
```

Link the `CoreServices` and `SystemConfiguration` frameworks. The app deployment
target is macOS 14.0. Upstream Chiaki forces its own core deployment target
to 13.0 when building on an arm64 host (12.0 on an Intel host); this lower
library target remains compatible with the app's macOS 14.0 minimum.
Both architecture builds and their link probes were verified locally on
2026-10-15. The arm64 probe ran natively; the x86_64 probe also ran through
Rosetta. This verifies build feasibility, not console compatibility or
Remote Play/controller coexistence.

The core disables GUI, CLI, tests, FFmpeg/Pi decoding, Speex, Steam features,
Setsu, and the RUDP option. At this pinned revision, `CHIAKI_ENABLE_RUDP=OFF`
does **not** remove internet transport code or its dependencies: upstream
unconditionally builds curl, miniupnpc, and libevent support into the core.
The adapter must select LAN registration/session APIs and leave the
holepunch/RUDP parameters unset. No PSN setup is supplied by this build.

OpenSSL, Opus, json-c, miniupnpc, and libevent are built from checksum-pinned
archives. curl, nanopb, Jerasure, and GF-Complete build from the Git submodules.
The pinned universal macOS protoc executable and pure-Python protobuf wheel
are build tools only; they are not linked or bundled into the app. curl uses
the local static OpenSSL and disables optional IDN, PSL, SSH, Brotli, Zstd,
and zlib dependencies. The script restricts pkg-config to the local prefix,
ignores Homebrew CMake prefixes, and discards ambient header/linker flags.

Every build links a probe that references the session, registration, and
Opus APIs. It checks archive architectures and rejects any `otool -L`
dependency outside `/System/Library/` and `/usr/lib/`; the audit is saved to
`.deps/remoteplay/<arch>/build/otool.txt`. The probe only initializes the library
when run and makes no network requests. Native probes run automatically;
cross-built probes require a compatible machine or Rosetta to execute.
The final app executable also needs its own `otool -L` check.

Retain upstream notices. Chiaki core files identify
`LicenseRef-AGPL-3.0-only-OpenSSL`; see `chiaki-ng/COPYING` and upstream source
headers. Third-party license texts remain in their corresponding source trees:

| Dependency | License text |
| --- | --- |
| curl | `chiaki-ng/third-party/curl/COPYING` |
| nanopb | `chiaki-ng/third-party/nanopb/LICENSE.txt` |
| Jerasure | `chiaki-ng/third-party/jerasure/COPYING` |
| GF-Complete | `chiaki-ng/third-party/gf-complete/COPYING` |
| OpenSSL | `.deps/remoteplay/sources/openssl/LICENSE.txt` |
| Opus | `.deps/remoteplay/sources/opus/COPYING` |
| json-c | `.deps/remoteplay/sources/json-c/COPYING` |
| miniupnpc | `.deps/remoteplay/sources/miniupnpc/LICENSE` |
| libevent | `.deps/remoteplay/sources/libevent/LICENSE` |
| protoc/protobuf | `.deps/remoteplay/sources/protobuf-python/protobuf-5.29.3.dist-info/LICENSE` |

The separately built account setup helper derives from pinned PS5 Account Tools
(`8d648caef776d3b35af3faad36bc534b9127fe3c`). See
[payload scope and notices](../payload/remoteplay-setup/NOTICE.md). Its upstream
NP-state templates have unresolved underlying asset provenance: source origin and
hashes are known, but redistribution rights have not been independently established.
Do not treat this implementation branch as a cleared binary distribution.

PS5 MCP's former MIT notice is retained in `PS5-MCP-MIT-NOTICE.txt` for original
code incorporated into the AGPL project. `scripts/bundle-notices.py` stages exact
license texts and source pin information in the app's `Licenses` resource folder.
