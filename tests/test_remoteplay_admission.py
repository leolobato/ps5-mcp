"""Host-only decision tests for the Remote Play admission patch payload."""
import json
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "payload/remoteplay-setup"
STOCK_HEX = ("b95210fc8085c07818807daf0074128b4594898370040000834d880241b701eb")
PATCHED_HEX = ("b95210fc8085c09090807daf0090908b4594898370040000834d880241b701eb")


@pytest.fixture(scope="module")
def executable(tmp_path_factory):
    out = tmp_path_factory.mktemp("admission") / "admission-host"
    subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                    "-fsanitize=undefined", "-g",
                    str(SOURCE / "admission.c"),
                    str(SOURCE / "admission_host_test.c"),
                    "-o", str(out)], check=True)
    return out


def run(executable, scenario):
    line = subprocess.check_output([executable, scenario], text=True, timeout=10).strip()
    return json.loads(line)


def test_apply_on_stock_patches_both_branches(executable):
    r = run(executable, "apply-stock")
    assert r["ok"] and r["changed"] and not r["already"]
    assert r["before"] == STOCK_HEX and r["after"] == PATCHED_HEX
    assert r["writes"] == 2 and r["code"] == "patched"
    assert r["base"] == "0x58cc8000" and r["pid"] == 61


def test_apply_is_idempotent(executable):
    r = run(executable, "apply-patched")
    assert r["ok"] and r["already"] and not r["changed"]
    assert r["code"] == "no-op" and r["writes"] == 0
    assert r["before"] == PATCHED_HEX and r["after"] == PATCHED_HEX


def test_apply_refuses_unrecognized_context(executable):
    r = run(executable, "apply-mismatch")
    assert not r["ok"] and r["writes"] == 0
    assert r["code"] == "context-mismatch"


def test_apply_reports_missing_daemon(executable):
    r = run(executable, "apply-no-daemon")
    assert not r["ok"] and r["code"] == "no-daemon"


def test_apply_surfaces_write_failure(executable):
    r = run(executable, "apply-write-fails")
    assert not r["ok"] and r["code"] == "write-failed"


def test_apply_surfaces_verify_read_failure(executable):
    r = run(executable, "apply-verify-fails")
    assert not r["ok"] and r["code"] in ("verify-read-failed", "verify-mismatch")


@pytest.mark.parametrize("scenario,original", [
    ("apply-second-write-fails", STOCK_HEX),
    ("restore-second-write-fails", PATCHED_HEX),
    ("apply-protection-restore-fails", STOCK_HEX),
    ("apply-verify-mismatch", STOCK_HEX),
])
def test_failed_mutation_restores_original_context(executable, scenario, original):
    r = run(executable, scenario)
    assert not r["ok"]
    assert r["memory"] == original
    assert r["rollbackAttempted"] == 1 and r["rollbackVerified"] == 1
    assert r["after"] == original


def test_failed_rollback_is_not_reported_as_verified(executable):
    r = run(executable, "apply-write-fails")
    assert not r["ok"]
    assert r["rollbackAttempted"] == 1 and r["rollbackVerified"] == 0


def test_partial_context_is_not_accepted(executable):
    r = run(executable, "apply-partial")
    assert not r["ok"] and r["writes"] == 0
    assert r["code"] == "context-mismatch"


def test_region_must_contain_the_entire_context(executable):
    r = run(executable, "apply-small-region")
    assert not r["ok"] and r["reads"] == 0 and r["writes"] == 0
    assert r["code"] == "no-text"


def test_check_reports_stock_and_patched(executable):
    assert run(executable, "check-stock")["code"] == "stock"
    assert run(executable, "check-patched")["code"] == "patched"
    r = run(executable, "check-unknown")
    assert not r["ok"] and r["code"] == "unknown"


def test_restore_returns_to_stock(executable):
    r = run(executable, "restore-patched")
    assert r["ok"] and r["changed"] and r["code"] == "restored"
    assert r["before"] == PATCHED_HEX and r["after"] == STOCK_HEX


def test_restore_is_idempotent(executable):
    r = run(executable, "restore-stock")
    assert r["ok"] and r["already"] and r["writes"] == 0


def test_restore_refuses_unrecognized_context(executable):
    r = run(executable, "restore-mismatch")
    assert not r["ok"] and r["writes"] == 0 and r["code"] == "context-mismatch"


def _load_builder():
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "setup_builder", ROOT / "scripts/build-remoteplay-setup.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_builder_variant_names_map_flags_to_distinct_payloads():
    import argparse
    builder = _load_builder()

    def args(**kw):
        base = argparse.Namespace(admission=False, admission_check=False,
                                  admission_restore=False, diagnostics=False,
                                  verify_restoration=False)
        for key, value in kw.items():
            setattr(base, key, value)
        return base

    assert builder.variant_basename(args()) == "remoteplay-setup"
    assert builder.variant_basename(args(diagnostics=True)) == "remoteplay-setup-diagnostics"
    assert builder.variant_basename(args(verify_restoration=True)) == "remoteplay-setup-restore-check"
    assert builder.variant_basename(args(admission=True)) == "remoteplay-admit"
    assert builder.variant_basename(args(admission_check=True)) == "remoteplay-admit-check"
    assert builder.variant_basename(args(admission_restore=True)) == "remoteplay-admit-restore"
    assert builder.admission_mode(args()) is None
    assert builder.admission_mode(args(admission=True)) == "apply"
    assert builder.admission_mode(args(admission_check=True)) == "check"
    assert builder.admission_mode(args(admission_restore=True)) == "restore"
