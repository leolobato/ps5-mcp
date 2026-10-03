#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PS5_PAYLOAD_SDK="${PS5_PAYLOAD_SDK:-$repo_root/.deps/ps5-payload-sdk}"
if [[ -z "${LLVM_CONFIG:-}" ]]; then
    if command -v brew >/dev/null 2>&1; then
        export LLVM_CONFIG="$(brew --prefix llvm@18)/bin/llvm-config"
    else
        export LLVM_CONFIG=llvm-config-18
    fi
fi
if ! command -v "$LLVM_CONFIG" >/dev/null 2>&1; then
    echo 'Missing LLVM 18. Run brew bundle or set LLVM_CONFIG.' >&2
    exit 1
fi
export PATH="$("$LLVM_CONFIG" --bindir):$PATH"
exec "$@"
