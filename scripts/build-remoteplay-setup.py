#!/usr/bin/env python3
"""Build the separate GPL Remote Play account setup helper; never contacts a console."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


PINNED_ACCOUNT_TOOLS = "8d648caef776d3b35af3faad36bc534b9127fe3c"


def verified_vendor_sources(vendor=None):
    vendor = vendor or ROOT / "third-party/account-tools"
    manifest = json.loads((vendor / "SOURCE.json").read_text())
    if manifest.get("commit") != PINNED_ACCOUNT_TOOLS:
        raise SystemExit("Account Tools provenance commit does not match the pinned source")
    expected = manifest.get("sha256", {})
    templates = ("src/np_templates/auth_dat.h", "src/np_templates/config_dat.h")
    if not all(name in expected for name in templates):
        raise SystemExit("Account Tools provenance is missing an NP template")
    actual = {}
    for name, digest in expected.items():
        path = vendor / name
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise SystemExit(f"Account Tools source hash mismatch: {name}")
        actual[name] = digest
    return actual


def variant_basename(args):
    """Pure mapping from parsed flags to the output basename (unit-tested)."""
    admission = args.admission or args.admission_check or args.admission_restore
    return ("remoteplay-setup-restore-check" if args.verify_restoration else
            "remoteplay-setup-diagnostics" if args.diagnostics else
            "remoteplay-admit-check" if args.admission_check else
            "remoteplay-admit-restore" if args.admission_restore else
            "remoteplay-admit" if admission else
            "remoteplay-setup")


def admission_mode(args):
    admission = args.admission or args.admission_check or args.admission_restore
    return ("check" if args.admission_check else
            "restore" if args.admission_restore else
            "apply" if admission else None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    variants = parser.add_mutually_exclusive_group()
    variants.add_argument("--diagnostics", action="store_true",
                        help="build a one-shot read-only registry status probe instead of the HTTP setup service")
    variants.add_argument("--verify-restoration", action="store_true",
                          help="build a read-only comparison against the foreground user's version-2 backup")
    variants.add_argument("--admission", action="store_true",
                        help="build the one-shot per-boot Remote Play admission patch payload (apply, idempotent)")
    variants.add_argument("--admission-check", action="store_true",
                        help="build a report-only admission patch status probe")
    variants.add_argument("--admission-restore", action="store_true",
                        help="build a one-shot admission patch restore payload")
    args = parser.parse_args()
    read_only = args.diagnostics or args.verify_restoration
    admission = args.admission or args.admission_check or args.admission_restore
    if admission and (read_only or not (args.admission ^ args.admission_check ^ args.admission_restore)):
        # argparse's mutually exclusive group already prevents combinations with
        # the other variants; the XOR protects against future flag additions.
        raise SystemExit("choose exactly one build variant")
    vendor_sources = verified_vendor_sources()
    source = ROOT / "payload/remoteplay-setup"
    build = ROOT / "build"
    build.mkdir(exist_ok=True)
    names = ("diagnostic_main.c", "setup.c", "files.c", "platform.c") if read_only else (
        "main.c", "setup.c", "api.c", "files.c", "platform.c", "admission.c", "admission_platform.c")
    if admission:
        names = ("admission.c", "admission_main.c", "admission_platform.c", "files.c", "platform.c")
    files = [source / name for name in names]
    source_hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in sorted(source.iterdir()) if p.is_file()}
    fingerprint_inputs = {"sources": source_hashes, "upstream_sources": vendor_sources,
                          "builder_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                          "diagnostic_only": read_only, "restoration_check": args.verify_restoration,
                          "admission": admission,
                          "admission_mode": admission_mode(args)}
    build_id = hashlib.sha256(json.dumps(fingerprint_inputs, sort_keys=True).encode()).hexdigest()
    basename = variant_basename(args)
    extra = ["-DRP_DIAGNOSTIC_ONLY", "-ffunction-sections", "-Wl,--gc-sections"] if read_only else []
    if admission:
        # The admission payload reuses the platform escalation path but must
        # not carry any registry mutation imports.
        extra += ["-DRP_DIAGNOSTIC_ONLY", "-ffunction-sections", "-Wl,--gc-sections"]
    if args.verify_restoration:
        extra += ["-DRP_VERIFY_RESTORATION"]
    if args.admission_check:
        extra += ["-DRP_ADM_MODE_CHECK"]
    if args.admission_restore:
        extra += ["-DRP_ADM_MODE_RESTORE"]
    extra += ['-DRP_BUILD_ID="' + build_id + '"']
    command = [str(ROOT / "scripts/with-env.sh"), "bash", "-c",
               'exec "$PS5_PAYLOAD_SDK/bin/prospero-clang" "$@"', "--",
               "-std=c11", "-Wall", "-Wextra", "-Werror", "-O1", "-g", *extra, *map(str, files),
               "-lSceUserService", "-lSceSystemService", "-lSceRegMgr", "-lkernel_sys",
               "-o", str(build / f"{basename}.elf")]
    subprocess.run(command, cwd=ROOT, check=True)
    elf = build / f"{basename}.elf"
    marker = b"PS5MCP_REMOTEPLAY_SETUP_TOKEN_UNCONFIGURED_CHANGE_BEFORE_UPLOAD_"
    if not read_only and not admission and elf.read_bytes().count(marker) != 1:
        raise SystemExit("Setup helper must contain exactly one unconfigured session marker")
    if admission:
        symbols = subprocess.check_output([str(ROOT / "scripts/with-env.sh"), "llvm-readelf",
                                           "--dyn-syms", str(elf)], text=True)
        if any(name in symbols for name in ("sceRegMgrSet", "sceRegMgrReset", "sceRegMgrCntlDelete")):
            raise SystemExit("Admission payload unexpectedly imports registry mutators")
    if read_only:
        symbols = subprocess.check_output([str(ROOT / "scripts/with-env.sh"), "llvm-readelf",
                                           "--dyn-syms", str(elf)], text=True)
        if any(name in symbols for name in ("sceRegMgrSet", "sceRegMgrReset", "sceRegMgrCntlDelete")):
            raise SystemExit("Read-only diagnostic unexpectedly imports registry mutators")
    report = {"helper": "ps5mcp-" + basename, "version": 1,
              "build_id": build_id, "diagnostic_only": read_only, "restoration_check": args.verify_restoration,
              "admission": admission,
              "admission_mode": admission_mode(args),
              "port": None if (read_only or admission) else 6770,
              "hardware_validated": False, "sha256": hashlib.sha256(elf.read_bytes()).hexdigest(),
              "upstream_commit": PINNED_ACCOUNT_TOOLS,
              "upstream_sources": vendor_sources,
              "template_hashes": {name: digest for name, digest in vendor_sources.items()
                                  if name.startswith("src/np_templates/")},
              "sources": source_hashes, "fingerprint_inputs": fingerprint_inputs}
    (build / f"{basename}-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Built {elf}; no deployment performed")


if __name__ == "__main__":
    main()
