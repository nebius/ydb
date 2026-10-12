#!/usr/bin/env bash
# Build/test adaptation of ydb-platform/ydb's .github/actions/test_ya/action.yml.
set -euo pipefail

: "${SOURCE_DIR:?}" "${RESULTS_DIR:?}" "${YA_OUT_DIR:?}"
: "${BUILD_PRESET:?}" "${BUILD_TARGET:?}"
mkdir -p "$RESULTS_DIR" "$YA_OUT_DIR"
cd "$SOURCE_DIR"

head_sha=$(git rev-parse HEAD)
started=$(date +%s)
finish() {
    rc=$?
    trap - EXIT
    jq -n --arg sha "$head_sha" --argjson rc "$rc" \
        --argjson duration "$(($(date +%s) - started))" \
        '{head_sha: $sha, exit_code: $rc, duration_seconds: $duration}' \
        >"$RESULTS_DIR/build-meta.json"
    exit "$rc"
}
trap finish EXIT

# Use available CPUs; linking gets lower parallelism to reduce memory pressure.
# Non-empty environment values override each default independently.
cpu_count=$(nproc)
BUILD_THREADS=${BUILD_THREADS:-$cpu_count}
TEST_THREADS=${TEST_THREADS:-$cpu_count}
link_threads=$((cpu_count / 4))
LINK_THREADS=${LINK_THREADS:-$((link_threads > 0 ? link_threads : 1))}
echo "CPUs=$cpu_count BUILD_THREADS=$BUILD_THREADS TEST_THREADS=$TEST_THREADS LINK_THREADS=$LINK_THREADS"

# Preset mapping and common build flags copied from the upstream action.
params=()
case "$BUILD_PRESET" in
debug | relwithdebinfo | release)
    params+=(--build "$BUILD_PRESET")
    ;;
release-asan) params+=(--build release --sanitize=address) ;;
release-tsan) params+=(--build release --sanitize=thread) ;;
release-msan) params+=(--build release --sanitize=memory) ;;
*)
    echo "Invalid preset: $BUILD_PRESET" >&2
    exit 1
    ;;
esac
read -r -a test_sizes <<< "${TEST_SIZES:-small medium}"
params+=(
    -T --retest "${test_sizes[@]/#/--test-size=}"
    --test-threads "$TEST_THREADS" --cleanup-child-processes
    --stat -DCONSISTENT_DEBUG --no-dir-outputs --build-all
    --force-build-depends
    -j "$BUILD_THREADS" --link-threads "$LINK_THREADS"
)
if [[ -n "${CACHE_SIZE:-}" ]]; then
    params+=(--cache-size "$CACHE_SIZE")
fi
if [[ "${BUILD_ARCH:-}" == arm64 ]]; then
    params+=(-DMKQL_DISABLE_CODEGEN=1)
fi

# A whitespace-separated list of targets, as in upstream; never evaluated as shell code.
read -r -a targets <<<"$BUILD_TARGET"
for target in "${targets[@]}"; do
    if [[ "$target" == -* || ! -e "$target" ]]; then
        echo "Invalid or missing build target: $target" >&2
        exit 1
    fi
done
if [[ ${#targets[@]} -eq 0 ]]; then
    echo 'No build targets specified' >&2
    exit 1
fi

# Override the aarch64 test_tool resource with our public mirror.
mapping=build/ext_mapping.conf.json
jq '
    .resources["12765027005"] = "https://ydb-nebius-ci-public-609722444123-us-east-1.s3.us-east-1.amazonaws.com/resources/test_tool-aarch64.tar.gz" |
    .resources_descriptions["12765027005"].file_name = "test_tool"
' "$mapping" >"$mapping.tmp"
mv "$mapping.tmp" "$mapping"

./ya --version 2>&1 | tee "$RESULTS_DIR/ya-version.txt"
command=(
    ./ya make "${params[@]}" "${targets[@]}"
    --log-file "$RESULTS_DIR/ya-log.txt"
    --evlog-file "$RESULTS_DIR/ya-evlog.jsonl"
    --build-results-report "$RESULTS_DIR/report.json"
    --output "$YA_OUT_DIR"
)
printf '%q ' "${command[@]}" >"$RESULTS_DIR/command.txt"
printf '\n' >>"$RESULTS_DIR/command.txt"
# Run selected test sizes once; no test-failure-code override, so failures fail the job.
# No retries, remote cache credentials or PR publishing.
# pipefail preserves ya's failure even though its output is also saved by tee.
"${command[@]}" 2>&1 | tee "$RESULTS_DIR/ya-make-output.txt"
