#!/usr/bin/env bash
set -euo pipefail
# Always runs after publication, including after build/report failures.
rc=0
bash "$TEST_YA_ACTION_PATH/coredumps.sh" cleanup || rc=$?
if [[ -n "${BAZEL_REMOTE_PASSWORD_FILE:-}" ]]; then rm -f -- "$BAZEL_REMOTE_PASSWORD_FILE"; fi
if [[ -n "${S3CMD_CONFIG:-}" ]]; then rm -f -- "$S3CMD_CONFIG"; fi
exit "$rc"
