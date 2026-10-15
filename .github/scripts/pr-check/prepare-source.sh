#!/usr/bin/env bash
set -euo pipefail
: "${GITHUB_OUTPUT:?}"

cpus=$(nproc)
link_threads=$((cpus / 4))
printf 'test_threads=%s\nlink_threads=%s\n' \
    "${TEST_THREADS:-$cpus}" "${LINK_THREADS:-$((link_threads > 0 ? link_threads : 1))}" >> "$GITHUB_OUTPUT"
