"""Host-only transaction tests for the separate privileged setup helper."""
import ctypes
import hashlib
import json
import shutil
import subprocess
from pathlib import Path
from urllib.parse import urlencode

import pytest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "payload/remoteplay-setup"


@pytest.fixture(scope="module")
def helper(tmp_path_factory):
    build = tmp_path_factory.mktemp("setup-helper")
    executable = build / "setup-host"
    subprocess.run(["cc", "-std=c11", "-D_DARWIN_C_SOURCE", "-D_DEFAULT_SOURCE",
                    "-Wall", "-Wextra", "-Werror", "-fsanitize=undefined", "-g",
                    *[str(SOURCE / name) for name in ("setup.c", "api.c", "files.c", "host_test.c")],
                    "-o", str(executable)], check=True)
    return executable


def scenario(helper, name):
    lines = subprocess.check_output([helper, name], text=True, timeout=10).splitlines()
    try:
        return [json.loads(line) for line in lines[:-1]]
    finally:
        shutil.rmtree(lines[-1])


def test_fresh_account_only_changes_selected_slot(helper):
    result, counts = scenario(helper, "fresh")
    assert result["ok"] and result["account"]["preparationVerified"]
    assert result["account"]["activated"] and result["account"]["signedIn"]
    assert not result["partialWrites"]
    assert result["backupPath"]
    assert counts["otherSlotWrites"] == 0
    assert counts["idWrites"] == 1
    assert counts["id"] != "0x0000000000000000"


def test_existing_id_is_preserved_without_an_id_setter(helper):
    first, retry, counts = scenario(helper, "existing")
    assert first["ok"] and retry["ok"] and retry["noOp"]
    assert counts["id"] == "0x8877665544332211"
    assert counts["idWrites"] == counts["retryWrites"] == counts["otherSlotWrites"] == 0
    assert first["account"]["accountIdB64"] == "ESIzRFVmd4g="


def test_prepared_retry_never_repeats_mutation(helper):
    first, retry, counts = scenario(helper, "retry")
    assert first["ok"] and retry["ok"] and retry["noOp"]
    assert counts["retryWrites"] == 0


@pytest.mark.parametrize("name,code", [("ambiguous", "target-changed"),
                                      ("changed", "target-changed"),
                                      ("backup-error", "backup-write")])
def test_uncertain_target_or_failed_backup_never_writes_accounts(helper, name, code):
    result, counts = scenario(helper, name)
    assert not result["ok"] and result["code"] == code
    assert not result["partialWrites"]
    assert counts["writes"] == 0


@pytest.mark.parametrize("name,code", [("file-error", "file-write"),
                                      ("registry-error", "registry-write")])
def test_partial_failure_restores_original_state_and_reports_failure(helper, name, code):
    result, counts = scenario(helper, name)
    assert not result["ok"] and result["partialWrites"] and result["restored"]
    assert result["code"] == code
    assert counts["id"] == "0x0000000000000000"
    assert counts["otherSlotWrites"] == 0


def test_failed_recovery_blocks_retry_instead_of_claiming_success(helper):
    result, retry, counts = scenario(helper, "recovery-error")
    assert not result["ok"] and result["partialWrites"] and not result["restored"]
    assert result["code"] == retry["code"] == "recovery-required"
    assert not retry["ok"] and counts["retryWrites"] == 0


@pytest.fixture(scope="module")
def api(tmp_path_factory):
    library = tmp_path_factory.mktemp("setup-api") / "api.dylib"
    subprocess.run(["cc", "-dynamiclib", str(SOURCE / "api.c"), str(SOURCE / "setup.c"),
                    "-o", str(library)], check=True)
    lib = ctypes.CDLL(str(library))
    lib.rp_parse_form.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_uint32),
                                  ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_uint64)]
    return lib


def parse(api, form):
    uid, slot, account_id = ctypes.c_uint32(), ctypes.c_int(), ctypes.c_uint64()
    rc = api.rp_parse_form(form.encode(), ctypes.byref(uid), ctypes.byref(slot), ctypes.byref(account_id))
    return rc, uid.value, slot.value, account_id.value


def test_prepare_form_requires_explicit_exact_id_and_target(api):
    form = urlencode({"userId": 100, "slot": 3, "expectedAccountIdB64": "ESIzRFVmd4g="})
    assert parse(api, form) == (0, 100, 3, 0x8877665544332211)
    assert parse(api, "slot=1&expectedAccountIdB64=AAAAAAAAAAA%3D&userId=1")[0] == 0


@pytest.mark.parametrize("form", ["", "userId=1&slot=1", "userId=0&slot=1&expectedAccountIdB64=AAAAAAAAAAA%3D",
    "userId=4294967296&slot=1&expectedAccountIdB64=AAAAAAAAAAA%3D",
    "userId=1&slot=17&expectedAccountIdB64=AAAAAAAAAAA%3D",
    "userId=1&slot=1&expectedAccountIdB64=AAAAAAAAAAA%3D&slot=2",
    "userId=1&slot=1&expectedAccountIdB64=AAAAAAAAAAB%3D",
    "userId=1&slot=1&expectedAccountIdB64=AAAAAAAAAAA%3D&",
    "userId=1&slot=1&expectedAccountIdB64=AAAAAAAAAAA%00%3D"])
def test_prepare_form_rejects_missing_duplicate_overflow_and_noncanonical_values(api, form):
    assert parse(api, form)[0] != 0


def test_vendored_source_and_template_assets_match_pinned_manifest():
    base = ROOT / "third-party/account-tools"
    manifest = json.loads((base / "SOURCE.json").read_text())
    assert manifest["commit"] == "8d648caef776d3b35af3faad36bc534b9127fe3c"
    for name, expected in manifest["sha256"].items():
        assert hashlib.sha256((base / name).read_bytes()).hexdigest() == expected


@pytest.fixture(scope="module")
def http_helper(tmp_path_factory):
    executable = tmp_path_factory.mktemp("setup-http") / "http-host"
    subprocess.run(["cc", "-std=c11", "-D_DARWIN_C_SOURCE", "-D_DEFAULT_SOURCE",
                    "-Wall", "-Wextra", "-Werror", "-fsanitize=undefined",
                    *[str(SOURCE / name) for name in ("setup.c", "api.c", "files.c", "admission.c", "http_test.c")],
                    "-o", str(executable)], check=True)
    return executable


def http_request(http_helper, method, path, body="", headers=(), firmware="13.60",
                 authorization="Bearer " + "a" * 64, state=None):
    if authorization is not None:
        headers = (*headers, ("Authorization", authorization))
    request = (f"{method} {path} HTTP/1.1\r\nHost: localhost\r\n" +
               "".join(f"{key}: {value}\r\n" for key, value in headers) + "\r\n" + body)
    command = [http_helper, request, firmware] + ([state] if state else [])
    response = subprocess.run(command, text=True, timeout=5, capture_output=True, check=True)
    head, data = response.stdout.split("\n\n", 1)
    status = int(head.split()[1])
    if status == 401:
        assert response.stderr.strip() == "writes=0,fileWrites=0,users=0"
    if path in ("/api/admission", "/api/status"):
        assert response.stderr.strip() == "writes=0,fileWrites=0,users=0"
    return status, json.loads(data)


def test_http_inspection_has_version_and_capabilities(http_helper):
    status, data = http_request(http_helper, "GET", "/api/accounts")
    assert status == 200 and data["ok"]
    assert data["helper"] == "ps5mcp-remoteplay-setup" and data["version"] == 1
    assert data["firmware"] == "13.60" and not data["hardwareValidated"]
    assert set(data["capabilities"]) == {"compare-before-write", "preserve-existing-id",
        "target-slot-only", "durable-backup", "checked-readback", "session-auth"}


@pytest.mark.parametrize("method,path,headers,expected", [
    ("GET", "/api/prepare", (), 404),
    ("GET", "/api/accounts/activate?user=1", (), 404),
    ("GET", "/api/exit", (), 404),
    ("GET", "/api/accounts", (("Origin", "http://untrusted.test"),), 400),
    ("POST", "/api/prepare", (("Content-Length", "0"),), 404),
    ("GET", "/api/accounts", (("Content-Length", "0"), ("Content-Length", "0")), 400),
    ("GET", "/api/accounts", (("Transfer-Encoding", "chunked"),), 400),
])
def test_http_rejects_unsafe_methods_browser_origin_and_ambiguous_framing(
        http_helper, method, path, headers, expected):
    status, data = http_request(http_helper, method, path, headers=headers)
    assert status == expected and not data["ok"]


def test_http_preparation_firmware_gate(http_helper):
    body = "userId=268435457&slot=3&expectedAccountIdB64=AAAAAAAAAAA%3D"
    status, data = http_request(http_helper, "POST", "/api/prepare", body,
        headers=(("Content-Length", str(len(body))), ("X-RemotePlay-Setup", "1"),
                 ("Content-Type", "application/x-www-form-urlencoded")), firmware="12.60")
    assert status == 409 and data["code"] == "unsupported-firmware" and not data["partialWrites"]


@pytest.mark.parametrize("write_number", range(1, 17))
def test_every_registry_write_failure_restores_old_id_and_target_only(helper, write_number):
    result, counts = scenario(helper, f"registry-error-{write_number}")
    assert not result["ok"] and result["partialWrites"] and result["restored"]
    assert result["code"] == "registry-write"
    assert counts["id"] == "0x0000000000000000" and counts["otherSlotWrites"] == 0


def test_registry_failure_never_rewrites_existing_account_id_during_restore(helper):
    result, counts = scenario(helper, "existing-error")
    assert not result["ok"] and result["restored"]
    assert counts["id"] == "0x8877665544332211" and counts["idWrites"] == 0


@pytest.mark.parametrize("authorization,state", [
    (None, None), ("Bearer " + "b" * 64, None),
    ("Bearer PS5MCP_REMOTEPLAY_SETUP_TOKEN_UNCONFIGURED_CHANGE_BEFORE_UPLOAD_", "unconfigured"),
    ("Bearer " + "a" * 64, "expired"),
])
@pytest.mark.parametrize("method,path", [("GET", "/api/accounts"), ("POST", "/api/prepare")])
def test_http_requires_private_unexpired_session_before_any_account_access(
        http_helper, authorization, state, method, path):
    body = "userId=268435457&slot=3&expectedAccountIdB64=AAAAAAAAAAA%3D" if method == "POST" else ""
    status, data = http_request(http_helper, method, path, body,
        headers=(("Content-Length", str(len(body))), ("X-RemotePlay-Setup", "1"),
                 ("Content-Type", "application/x-www-form-urlencoded")),
        authorization=authorization, state=state)
    assert status == 401 and data == {"ok": False, "code": "unauthorized", "partialWrites": False}


def test_auth_marker_occurs_exactly_once_in_built_elf():
    elf = ROOT / "build/remoteplay-setup.elf"
    if not elf.exists():
        pytest.skip("PS5 payload SDK build not run")
    marker = b"PS5MCP_REMOTEPLAY_SETUP_TOKEN_UNCONFIGURED_CHANGE_BEFORE_UPLOAD_"
    assert len(marker) == 64 and elf.read_bytes().count(marker) == 1



def test_unconfigured_helper_refuses_startup_before_platform_access(http_helper):
    result = subprocess.run([http_helper, "", "13.60", "startup-unconfigured"],
                            check=True, capture_output=True, text=True)
    assert result.stdout.strip() == "unconfigured startup rejected"


def test_session_allows_only_one_preparation_attempt(http_helper):
    body = "userId=268435457&slot=3&expectedAccountIdB64=AAAAAAAAAAA%3D"
    status, data = http_request(http_helper, "POST", "/api/prepare", body,
        headers=(("Content-Length", str(len(body))), ("X-RemotePlay-Setup", "1"),
                 ("Content-Type", "application/x-www-form-urlencoded")), state="used")
    assert status == 409 and data["code"] == "session-used" and not data["partialWrites"]


def test_registry_backup_failure_reports_exact_metadata_without_writing(helper):
    result, counts = scenario(helper, "read-error")
    assert not result["ok"] and result["code"] == "backup-read" and not result["partialWrites"]
    assert counts["writes"] == counts["fileWrites"] == 0
    error = result["registryError"]
    expected = {"present": True, "key": 125830656 + 2 * 65536, "kind": 1, "size": 65,
                "returnStatus": -2141913085, "returnStatusHex": "0x80550003"}
    assert all(error[key] == value for key, value in expected.items())
    assert error["phase"] == "backup-read" and not error["setterCalled"]
    assert "key=125961728" in result["message"] and "size=65" in result["message"]
    assert "0x80550003" in result["message"]


def test_diagnostic_probes_every_target_field_and_buffer_size_without_writes(helper):
    report, counts = scenario(helper, "diagnostic")
    assert report["ok"] and report["diagnosticOnly"] and report["targetStable"]
    assert report["slot"] == 3 and len(report["fields"]) == 23
    assert counts["writes"] == counts["fileWrites"] == 0 and counts["probes"] > 23
    for field in report["fields"]:
        assert 125829632 + 2 * 65536 <= field["key"] < 125829632 + 3 * 65536
        assert set(field) == {"key", "kind", "size", "returnStatus", "returnStatusHex", "stringBufferProbes", "alternateTypeProbes"}
    email = report["fields"][0]
    assert email["returnStatusHex"] == "0x80550003"
    assert all(probe["returnStatusHex"] == "0x80550003" for probe in email["stringBufferProbes"])
    country = report["fields"][3]
    assert country["size"] == 3 and country["returnStatusHex"] == "0x80550004"
    assert [probe["size"] for probe in country["stringBufferProbes"]] == [65, 128, 256]
    assert all(probe["returnStatus"] == 0 for probe in country["stringBufferProbes"])
    # Neither a read value nor identity name/account-ID is ever serialized.
    assert "Offline" not in json.dumps(report) and "accountId" not in json.dumps(report)


def test_diagnostic_refuses_ambiguous_target_without_probes_or_writes(helper):
    report, counts = scenario(helper, "diagnostic-ambiguous")
    assert not report["ok"] and report["code"] == "target-unverified" and report["fields"] == []
    assert counts == {"writes": 0, "fileWrites": 0, "probes": 0}


def test_build_verifies_vendored_templates_before_compilation(tmp_path):
    import importlib.util
    spec = importlib.util.spec_from_file_location("setup_builder", ROOT / "scripts/build-remoteplay-setup.py")
    builder = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(builder)
    vendor = tmp_path / "account-tools"
    shutil.copytree(ROOT / "third-party/account-tools", vendor)
    verified = builder.verified_vendor_sources(vendor)
    assert len(verified["src/np_templates/auth_dat.h"]) == 64
    (vendor / "src/np_templates/auth_dat.h").write_text("changed")
    with pytest.raises(SystemExit, match="source hash mismatch"):
        builder.verified_vendor_sources(vendor)


def test_exact_absent_legacy_field_is_explicitly_skipped_and_prepared_retry_is_noop(helper):
    result, retry, counts = scenario(helper, "legacy-missing")
    assert result["ok"] and result["account"]["preparationVerified"]
    assert retry["ok"] and retry["noOp"] and counts["retryWrites"] == 0
    assert counts["writes"] == 15 and counts["legacyWrites"] == 0


@pytest.mark.parametrize("name,status", [("legacy-wrong-error", "0x800d0207"),
                                          ("legacy-wrong-profile", "0x800d0203")])
def test_legacy_exception_never_accepts_other_errors_or_unknown_firmware_profile(helper, name, status):
    result, counts = scenario(helper, name)
    assert not result["ok"] and result["code"] == "backup-read"
    assert result["registryError"]["key"] == 125830144 + 2 * 65536
    assert result["registryError"]["returnStatusHex"] == status
    assert counts["writes"] == counts["fileWrites"] == 0


def test_absent_legacy_field_has_no_setter_during_rollback(helper):
    result, counts = scenario(helper, "legacy-rollback")
    assert not result["ok"] and result["restored"]
    assert counts["legacyWrites"] == 0 and counts["otherSlotWrites"] == 0


def test_readable_legacy_field_keeps_checked_write_behavior(helper):
    result, counts = scenario(helper, "fresh")
    assert result["ok"] and counts["writes"] == 16 and counts["legacyWrites"] == 1


def test_invalid_registry_id_error_on_other_key_still_aborts_backup(helper):
    result, counts = scenario(helper, "other-key-invalid")
    assert not result["ok"] and result["code"] == "backup-read"
    assert result["registryError"]["returnStatusHex"] == "0x800d0203"
    assert result["registryError"]["key"] == 125830656 + 2 * 65536
    assert counts["writes"] == counts["fileWrites"] == 0


def test_newly_readable_legacy_field_aborts_instead_of_silently_skipping(helper):
    result, counts = scenario(helper, "legacy-appears")
    assert not result["ok"] and result["code"] == "target-changed"
    assert not result["partialWrites"] and counts["writes"] == 0


def test_snapshot_records_unsupported_status_explicitly_in_version_two(helper):
    import struct
    class RegistryValue(ctypes.Structure):
        _fields_ = [("key", ctypes.c_uint32), ("kind", ctypes.c_uint32),
                    ("size", ctypes.c_uint32), ("data", ctypes.c_ubyte * 65)]
    lines = subprocess.check_output([helper, "legacy-missing"], text=True, timeout=10).splitlines()
    try:
        result = json.loads(lines[0])
        snapshot = Path(result["backupPath"]).read_bytes()
        assert struct.unpack_from("<II", snapshot) == (0x52505331, 2)
        marker_offset = 40 + 23 * ctypes.sizeof(RegistryValue)
        markers = struct.unpack_from("<23I", snapshot, marker_offset)
        assert markers[6] == 0x800d0203
        assert all(value == 0 for index, value in enumerate(markers) if index != 6)
    finally:
        shutil.rmtree(lines[-1])


def test_originally_absent_legacy_field_becoming_readable_at_final_check_cannot_succeed(helper):
    result, counts = scenario(helper, "legacy-appears-final")
    assert not result["ok"] and result["code"] == "verify" and result["restored"]
    assert result["partialWrites"] and counts["legacyWrites"] == 0


def test_originally_readable_legacy_field_becoming_absent_after_write_cannot_succeed(helper):
    result, counts = scenario(helper, "legacy-disappears-final")
    assert not result["ok"] and result["partialWrites"]
    assert result["code"] == "recovery-required" and not result["restored"]
    assert counts["legacyWrites"] >= 1


def test_inspection_exposes_nonsecret_build_fingerprint(http_helper):
    status, data = http_request(http_helper, "GET", "/api/accounts")
    assert status == 200 and data["buildId"] == "unversioned-host-fixture"


def test_diagnostic_report_preserves_raw_firmware_and_profile_state(tmp_path):
    stub = tmp_path / "diagnostic-stub.c"
    stub.write_text(r'''
#include "setup.h"
#include "firmware.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static uint32_t raw;
static int enabled(void) { return rp_supported_firmware(raw); }
const struct rp_ops rp_platform={.legacy_profile_enabled=enabled};
int rp_platform_init(char firmware[16]) {
    raw=(uint32_t)strtoul(getenv("RP_TEST_RAW_FW"),NULL,0);
    snprintf(firmware,16,"%x.%02x",raw>>24,(raw>>16)&255); return 0;
}
uint32_t rp_platform_firmware_raw(void) { return raw; }
int rp_platform_registry_probe(uint32_t key,unsigned kind,unsigned size) {
    (void)key; (void)kind; (void)size; return 0;
}
int rp_registry_diagnostics(const struct rp_ops *ops,rp_registry_probe probe,char *out,size_t cap) {
    (void)ops; (void)probe; return snprintf(out,cap,"{\"ok\":true,\"diagnosticOnly\":true}");
}
int rp_test_write_report(const char *path,const unsigned char *data,size_t size) {
    if(strcmp(path,"/data/remoteplay-setup.diagnostics.json")) return -1;
    fwrite(data,1,size,stdout); putchar('\n'); return 0;
}
''')
    executable = tmp_path / "diagnostic-metadata"
    subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-I", str(SOURCE),
                    "-Drp_file_write=rp_test_write_report", str(SOURCE / "diagnostic_main.c"),
                    str(stub), "-o", str(executable)], check=True)
    import os
    for raw, enabled in [("0x13600000", True), ("0x13600007", True),
                         ("0x13500007", False), ("0x13610007", False), ("0x14600007", False)]:
        output = subprocess.check_output([executable], text=True,
                                         env={**os.environ, "RP_TEST_RAW_FW": raw})
        report = json.loads(output.splitlines()[0])
        assert report["firmware"] == raw[2:4] + "." + raw[4:6] and report["firmwareRaw"] == raw
        assert report["legacyProfileEnabled"] is enabled
        assert report["buildId"] == "unversioned-host-fixture"


def test_registry_setter_failure_has_exact_error_and_no_fabricated_readback(helper):
    result, _ = scenario(helper, "registry-error-1")
    error = result["registryError"]
    assert error["phase"] == "setter" and error["setterStatus"] == -1
    assert error["setterCalled"] and not error["readbackCalled"]
    assert error["firstDifference"] == -1 and error["actualStringLength"] == -1
    assert error["key"] == 125830656 + 2 * 65536 and error["kind"] == 1 and error["size"] == 65


def test_registry_readback_getter_failure_keeps_both_statuses(helper):
    result, _ = scenario(helper, "registry-readback-error")
    error = result["registryError"]
    assert result["restored"] and error["phase"] == "readback-read"
    assert error["setterCalled"] and error["setterStatus"] == 0 and error["readbackCalled"]
    assert error["readbackStatusHex"] == "0x800d0208" and error["firstDifference"] == -1
    assert error["actualStringLength"] == -1


@pytest.mark.parametrize("name,padding", [("registry-value-difference", False),
                                         ("registry-padding-difference", True)])
def test_registry_byte_mismatch_reports_index_and_lengths_without_weakening_comparison(helper, name, padding):
    result, _ = scenario(helper, name)
    error = result["registryError"]
    assert not result["ok"] and result["restored"] and error["phase"] == "readback-compare"
    assert error["setterStatus"] == error["readbackStatus"] == 0
    if padding:
        assert error["wantedStringLength"] == error["actualStringLength"]
        assert error["firstDifference"] > error["wantedStringLength"]
    else:
        assert error["firstDifference"] == 0 and error["actualStringLength"] == 0
    assert "@" not in result["message"] and "Offline" not in result["message"]


def test_transaction_trace_is_private_unique_metadata_and_matches_verified_rollback(helper):
    lines = subprocess.check_output([helper, "registry-padding-difference"], text=True, timeout=10).splitlines()
    try:
        result = json.loads(lines[0])
        assert result["traceSaved"] and result["tracePath"].endswith(".trace.json")
        trace_path = Path(result["tracePath"])
        assert trace_path.stat().st_mode & 0o777 == 0o600
        trace = json.loads(trace_path.read_text())
        assert trace["restored"] and not trace["ok"]
        assert trace["registryError"] == result["registryError"]
        assert trace["steps"][-1]["firstDifference"] == result["registryError"]["firstDifference"]
        text = trace_path.read_text()
        assert "Offline" not in text and "accountId" not in text and "AAAAAAAAAAA=" not in text
        assert "data" not in trace["steps"][-1]
    finally:
        shutil.rmtree(lines[-1])


def test_trace_write_failure_is_reported_without_changing_verified_rollback_result(helper):
    result, _ = scenario(helper, "trace-error")
    assert not result["ok"] and result["restored"] and not result["traceSaved"]
    assert result["tracePath"] and result["code"] == "registry-write"


@pytest.mark.parametrize("name", ["restore-check", "restore-check-existing-files", "restore-check-legacy"])
def test_independent_restore_audit_matches_exact_original_values_and_file_presence(helper, name):
    preparation, audit, counts = scenario(helper, name)
    assert not preparation["ok"] and preparation["restored"]
    assert audit["ok"] and audit["schemaValidated"] and audit["snapshotVersion"] == 2
    assert audit["restorationVerified"] and audit["accountIdMatches"]
    assert audit["markerAbsent"] and audit["targetStable"]
    assert len(audit["registry"]) == 23 and all(item["matches"] for item in audit["registry"])
    assert all(item["matches"] for item in audit["files"])
    assert counts == {"auditWrites": 0, "auditFileWrites": 0}
    assert "accountIdB64" not in json.dumps(audit) and "Offline" not in json.dumps(audit)


@pytest.mark.parametrize("name", ["restore-check-registry", "restore-check-id", "restore-check-file",
    "restore-check-existing-files-content", "restore-check-existing-files-missing", "restore-check-marker",
    "restore-check-legacy-changed", "restore-check-target-changed"])
def test_independent_restore_audit_refuses_any_difference_marker_or_unstable_target(helper, name):
    _, audit, counts = scenario(helper, name)
    assert audit["ok"] and not audit["restorationVerified"]
    assert counts == {"auditWrites": 0, "auditFileWrites": 0}


@pytest.mark.parametrize("name", ["restore-check-snapshot-version", "restore-check-snapshot-uid",
    "restore-check-snapshot-slot", "restore-check-snapshot-schema", "restore-check-snapshot-short"])
def test_independent_restore_audit_rejects_wrong_snapshot_layout_or_target(helper, name):
    _, audit, counts = scenario(helper, name)
    assert not audit["ok"] and audit["code"] == "snapshot-invalid"
    assert "restorationVerified" not in audit
    assert counts == {"auditWrites": 0, "auditFileWrites": 0}


def test_a4_preserves_all_four_original_bytes_in_config_and_issues_no_setter(helper):
    result, reopened, counts = scenario(helper, "a4-full-preserve")
    assert result["ok"] and result["account"]["preparationVerified"]
    assert reopened == {"cfgA4": 0xa1b2c3d4, "registryA4": 0xa1b2c3d4, "verifiedAfterReopen": True}
    assert counts["a4Writes"] == 0 and counts["otherSlotWrites"] == 0


def test_a4_drift_before_first_account_write_aborts_untouched(helper):
    result, counts = scenario(helper, "a4-drift-before")
    assert not result["ok"] and result["code"] == "target-changed"
    assert not result["partialWrites"] and counts["writes"] == counts["a4Writes"] == 0


@pytest.mark.parametrize("name", ["a4-drift-during", "a4-drift-final", "a4-drift-late-failure", "a4-profile-flip"])
def test_a4_drift_during_transaction_never_sets_it_or_claims_restoration(helper, name):
    result, counts = scenario(helper, name)
    assert not result["ok"] and result["partialWrites"] and not result["restored"]
    assert result["code"] == "recovery-required"
    assert counts["a4Writes"] == 0 and counts["otherSlotWrites"] == 0


def test_reopened_inspection_compares_full_a4_value_to_persisted_config(helper):
    result, reopened, counts = scenario(helper, "a4-reopen-drift")
    assert result["ok"]
    assert reopened["cfgA4"] != reopened["registryA4"] and not reopened["verifiedAfterReopen"]
    assert counts["a4Writes"] == 0


@pytest.mark.parametrize("index", range(6), ids=["A4", "B4", "D0", "D4-irregular", "DC-irregular", "F4"])
def test_all_six_np_integers_preserve_every_snapshot_byte_without_any_setter(helper, index):
    result, metadata, _ = scenario(helper, f"np-case-{index}-preserve")
    assert result["ok"] and metadata["allConfigBytesPreserved"] and metadata["reopenVerified"]
    assert metadata["npSetters"] == metadata["targetSetters"] == 0


@pytest.mark.parametrize("index", range(6), ids=["A4", "B4", "D0", "D4-irregular", "DC-irregular", "F4"])
def test_each_np_integer_drift_before_writes_aborts_untouched(helper, index):
    result, metadata, counts = scenario(helper, f"np-case-{index}-before")
    assert not result["ok"] and result["code"] == "target-changed" and not result["partialWrites"]
    assert counts["writes"] == metadata["npSetters"] == 0


@pytest.mark.parametrize("index", range(6), ids=["A4", "B4", "D0", "D4-irregular", "DC-irregular", "F4"])
@pytest.mark.parametrize("phase", ["during", "final", "late-failure"])
def test_each_np_integer_drift_during_failure_never_sets_it_or_claims_restoration(helper, index, phase):
    result, metadata, _ = scenario(helper, f"np-case-{index}-{phase}")
    assert not result["ok"] and result["partialWrites"] and not result["restored"]
    assert result["code"] == "recovery-required"
    assert metadata["npSetters"] == metadata["targetSetters"] == 0


@pytest.mark.parametrize("index", range(6), ids=["A4", "B4", "D0", "D4-irregular", "DC-irregular", "F4"])
def test_reopen_checks_every_preserved_np_integer_without_masking(helper, index):
    result, metadata, _ = scenario(helper, f"np-case-{index}-reopen")
    assert result["ok"] and metadata["allConfigBytesPreserved"] and not metadata["reopenVerified"]
    assert metadata["npSetters"] == 0


def test_ext114c_preserves_all65_bytes_including_terminator_and_padding_only(helper):
    result, metadata, _ = scenario(helper, "ext-case-preserve")
    assert result["ok"] and metadata["all65BytesPreserved"] and metadata["reopenVerified"]
    assert metadata["extSetters"] == 0 and metadata["otherExtensionsWritten"] == 2


@pytest.mark.parametrize("padding", ["", "-padding"])
def test_ext114c_drift_before_first_write_is_refused_exactly(helper, padding):
    result, metadata, counts = scenario(helper, f"ext-case-before{padding}")
    assert not result["ok"] and not result["partialWrites"] and result["code"] == "target-changed"
    assert metadata["extSetters"] == counts["writes"] == 0


@pytest.mark.parametrize("padding", ["", "-padding"])
@pytest.mark.parametrize("phase", ["during", "final", "late-failure"])
def test_ext114c_content_or_padding_drift_never_issues_setter_or_claims_restoration(helper, phase, padding):
    result, metadata, _ = scenario(helper, f"ext-case-{phase}{padding}")
    assert not result["ok"] and result["partialWrites"] and not result["restored"]
    assert result["code"] == "recovery-required" and metadata["extSetters"] == 0


@pytest.mark.parametrize("padding", ["", "-padding"])
def test_ext114c_reopen_compares_full65_bytes_without_string_normalization(helper, padding):
    result, metadata, _ = scenario(helper, f"ext-case-reopen{padding}")
    assert result["ok"] and metadata["all65BytesPreserved"] and not metadata["reopenVerified"]
    assert metadata["extSetters"] == 0 and metadata["otherExtensionsWritten"] == 2


@pytest.mark.parametrize('mode', ['check', 'apply', 'restore'])
def test_authenticated_admission_returns_correlated_result_without_account_writes(http_helper, mode):
    body = f'mode={mode}&requestId=' + 'b' * 32
    status, data = http_request(http_helper, 'POST', '/api/admission', body,
        headers=(('Content-Length', str(len(body))), ('Content-Type', 'application/x-www-form-urlencoded'),
                 ('X-RemotePlay-Setup', '1')))
    assert status == 200 and data['ok'] == 1
    assert data['mode'] == mode and data['requestId'] == 'b' * 32
    assert data['buildId'] == 'unversioned-host-fixture'


@pytest.mark.parametrize('body,mutation_header,firmware,expected', [
    ('mode=apply&requestId=' + 'b' * 32, False, '13.60', 400),
    ('mode=apply&requestId=' + 'b' * 32, True, '12.00', 409),
    ('mode=delete&requestId=' + 'b' * 32, True, '13.60', 400),
    ('mode=check&requestId=' + 'B' * 32, True, '13.60', 400),
    ('mode=check&requestId=' + 'b' * 31, True, '13.60', 400),
    ('mode=check&requestId=' + 'b' * 32 + '&mode=apply', True, '13.60', 400),
])
def test_admission_rejects_invalid_or_unsupported_operation(http_helper, body, mutation_header, firmware, expected):
    headers = [('Content-Length', str(len(body))), ('Content-Type', 'application/x-www-form-urlencoded')]
    if mutation_header:
        headers.append(('X-RemotePlay-Setup', '1'))
    status, data = http_request(http_helper, 'POST', '/api/admission', body, headers=headers, firmware=firmware)
    assert status == expected and not data['ok']
    if expected == 409:
        assert data['requestId'] == 'b' * 32 and data['mode'] == 'apply'
        assert data['buildId'] == 'unversioned-host-fixture'


def test_admission_health_does_not_inspect_accounts(http_helper):
    status, data = http_request(http_helper, "GET", "/api/status")
    assert status == 200 and data["ok"]
    assert data["buildId"] == "unversioned-host-fixture"
    assert data["accounts"] == []
