#!/usr/bin/env bash
# Optional bounded core volume, retained from the upstream action (not analytics).
set -euo pipefail
: "${CI_STATE_DIR:?}"
case "${1:-}" in
setup)
    [[ "${COLLECT_COREDUMPS:-false}" == true ]] || exit 0
    image="/var/lib/ydb-ci-coredumps-${GITHUB_RUN_ID:-local}-$$.img"
    mount=/coredumps
    [[ ! -e "$image" ]] && ! mountpoint -q "$mount"
    available=$(df -Pk /var/lib | awk 'NR == 2 {print $4}')
    (( available >= 100 * 1024 * 1024 )) || { echo 'Not enough space for 100G core volume' >&2; exit 1; }
    printf '%s\n' "$image" > "$CI_STATE_DIR/core-image"
    cp /proc/sys/kernel/core_pattern "$CI_STATE_DIR/core-pattern"
    sudo mkdir -p "$mount"
    sudo fallocate -l 100G "$image"
    sudo mkfs.ext4 -q -F "$image"
    sudo mount -o loop,rw,nosuid,nodev "$image" "$mount"
    sudo chmod 1777 "$mount"
    printf '/coredumps/%%p.%%s\n' | sudo tee /proc/sys/kernel/core_pattern >/dev/null
    ;;
cleanup)
    [[ -f "$CI_STATE_DIR/core-image" ]] || exit 0
    if mountpoint -q /coredumps; then sudo umount /coredumps; fi
    if [[ -f "$CI_STATE_DIR/core-pattern" ]]; then
        # The saved pattern is readable by the runner; only the destination needs sudo.
        # shellcheck disable=SC2024
        sudo tee /proc/sys/kernel/core_pattern < "$CI_STATE_DIR/core-pattern" >/dev/null
    fi
    image=$(< "$CI_STATE_DIR/core-image")
    sudo rm -f -- "$image"
    ;;
*) echo 'Usage: coredumps.sh setup|cleanup' >&2; exit 2 ;;
esac
