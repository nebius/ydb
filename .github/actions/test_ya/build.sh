#!/usr/bin/env bash
# Build/graph/mute/retry pipeline adapted from upstream test_ya; no telemetry.
set -euo pipefail
: "${CI_STATE_DIR:?}" "${CI_PYTHON:?}" "${SOURCE_DIR:?}"
rc=0
trap 'rc=$?; trap - EXIT; printf "%s\n" "$rc" > "$CI_STATE_DIR/run-rc"; exit "$rc"' EXIT
cd "$SOURCE_DIR"
export GITHUB_HEAD_SHA="$ORIGINAL_HEAD"
export TEST_ICRDMA=1
bash "$TEST_YA_ACTION_PATH/coredumps.sh" setup
if [[ "${COLLECT_COREDUMPS:-false}" == true ]]; then ulimit -c unlimited; else ulimit -c 0; fi
STATUS_STATE=pending "$CI_PYTHON" "$TEST_YA_HELPERS_DIR/github-status.py"
printf 'Pre-commit check for %s has started.\n' "$ORIGINAL_HEAD" | "$CI_PYTHON" "$TEST_YA_HELPERS_DIR/comment-pr.py" --rewrite

params=(--stat -DCONSISTENT_DEBUG --no-dir-outputs --build-all --force-build-depends
    --test-failure-code 0 --link-threads "$LINK_THREADS")
case "$BUILD_PRESET" in
    debug|relwithdebinfo|release) params+=(--build "$BUILD_PRESET") ;;
    release-asan) params+=(--build release --sanitize=address) ;;
    release-tsan) params+=(--build release --sanitize=thread) ;;
    release-msan) params+=(--build release --sanitize=memory) ;;
    *) echo "Invalid preset: $BUILD_PRESET" >&2; exit 1 ;;
esac
if [[ -n "${TEST_TOOL_BIN:-}" ]]; then
    params+=(--test-tool-bin "$TEST_TOOL_BIN")
fi
if [[ "${RUN_TESTS:-true}" == true ]]; then
    read -r -a sizes <<< "${TEST_SIZES//,/ }"
    params+=(-t -T --retest "${sizes[@]/#/--test-size=}" --test-threads "$TEST_THREADS"
        --add-peerdirs-tests all)
    if [[ -n "${TEST_TYPES:-}" ]]; then
        read -r -a types <<< "${TEST_TYPES//,/ }"
        params+=("${types[@]/#/--test-type=}")
    fi
fi
if [[ "${ADD_VCS_INFO:-false}" == true ]]; then
    params+=("-DGIT_BRANCH=$BASE_BRANCH" "-DGIT_COMMIT_SHA=$ORIGINAL_HEAD")
fi
if [[ -n "${ADDITIONAL_YA_MAKE_ARGS:-}" ]]; then
    "$CI_PYTHON" -c 'import os,shlex,sys; sys.stdout.buffer.write(b"\0".join(x.encode() for x in shlex.split(os.environ["ADDITIONAL_YA_MAKE_ARGS"])) + b"\0")' > "$CI_STATE_DIR/extra-args"
    while IFS= read -r -d '' arg; do params+=("$arg"); done < "$CI_STATE_DIR/extra-args"
fi
read -r -a targets <<< "$BUILD_TARGET"
[[ ${#targets[@]} -gt 0 ]]
for target in "${targets[@]}"; do
    [[ "$target" != -* && -e "$target" ]] || { echo "Invalid build target: $target" >&2; exit 1; }
done
"$YA_EXECUTABLE" --version 2>&1 | tee "$PUBLIC_DIR/ya-version.txt"
graph_opts=()
if [[ "${INCREMENT:-false}" == true ]]; then
    base=${SOURCE_BASE_SHA:-$ORIGINAL_HEAD~1}
    if ! git cat-file -e "$base^{commit}" 2>/dev/null; then git fetch --no-tags --depth=1 origin "$base"; fi
    "$CI_PYTHON" -c 'import json,sys; json.dump(sys.argv[1:],sys.stdout)' "$YA_EXECUTABLE" make "${params[@]}" > "$CI_STATE_DIR/graph-command.json"
    printf '10 [Graph comparison](%s/graph_compare_log.txt)\n' "$PUBLIC_DIR_URL" >> "$SUMMARY_LINKS"
    "$CI_PYTHON" "$TEST_YA_HELPERS_DIR/graph_compare.py" \
        --command-file "$CI_STATE_DIR/graph-command.json" --result-graph-path "$CI_STATE_DIR/graph.json" \
        --result-context-path "$CI_STATE_DIR/context.json" --work-dir "$CI_STATE_DIR/graphs" \
        --summary-file "$PUBLIC_DIR/graph_summary.md" "$base" "$ORIGINAL_HEAD" "${targets[@]}" \
        2>&1 | tee "$PUBLIC_DIR/graph_compare_log.txt"
    graph_opts=(--build-custom-json "$CI_STATE_DIR/graph.json" --custom-context "$CI_STATE_DIR/context.json")
fi
if [[ -n "${REMOTE_CACHE_URI:-}" ]]; then
    params+=(--bazel-remote-store --bazel-remote-base-uri "$REMOTE_CACHE_URI")
    if [[ -n "${REMOTE_CACHE_USERNAME:-}" ]]; then
        params+=(--bazel-remote-username "$REMOTE_CACHE_USERNAME")
    fi
    if [[ -n "${BAZEL_REMOTE_PASSWORD_FILE:-}" ]]; then
        params+=(--bazel-remote-password-file "$BAZEL_REMOTE_PASSWORD_FILE")
    fi
    if [[ "${PUT_BUILD_RESULTS_TO_CACHE:-false}" == true ]]; then
        params+=(--bazel-remote-put --dist-cache-max-file-size=209715200 --dist-cache-evict-test-runs)
    fi
fi
previous=''
for (( retry=1; retry<=TEST_RETRY_COUNT; retry++ )); do
    export CI_YA_ATTEMPT=$retry
    export CURRENT_PUBLIC_DIR="$PUBLIC_DIR/try_$retry"
    export CURRENT_PUBLIC_DIR_URL="$PUBLIC_DIR_URL/try_$retry"
    export TEST_META_INFO="$CURRENT_PUBLIC_DIR/tests_meta"
    mkdir -p "$TEST_META_INFO"
    report="$CURRENT_PUBLIC_DIR/report.json"
    retry_opts=()
    if (( retry > 1 )); then
        # Use the previous ya run's failed-test cache and preserve unmuted chunk failures.
        "$CI_PYTHON" "$TEST_YA_HELPERS_DIR/mute/mute_utils.py" convert_muted_txt_to_yaml \
            "$MUTED_YA_FILE" "$previous" > "$CURRENT_PUBLIC_DIR/muted-tests.yaml"
        retry_opts=(-X --build-only-test-deps --test-blacklist-path "$CURRENT_PUBLIC_DIR/muted-tests.yaml")
        graph_opts=()
    fi
    command=("$YA_EXECUTABLE" make "${params[@]}" "${targets[@]}" "${graph_opts[@]}" "${retry_opts[@]}"
        --log-file "$PUBLIC_DIR/ya_log.txt" --evlog-file "$CURRENT_PUBLIC_DIR/ya_evlog.jsonl"
        --build-results-report "$report" --output "$YA_MAKE_OUT_DIR")
    redacted=()
    redact_next=false
    for arg in "${command[@]}"; do
        if [[ "$redact_next" == true ]]; then
            redacted+=('[redacted]')
            redact_next=false
        else
            redacted+=("$arg")
            case "$arg" in --bazel-remote-username|--bazel-remote-password-file) redact_next=true ;; esac
        fi
    done
    printf '%q ' "${redacted[@]}" > "$CURRENT_PUBLIC_DIR/command.txt"
    printf '\n' >> "$CURRENT_PUBLIC_DIR/command.txt"
    run_command=("${command[@]}")
    if [[ "${USE_SYSTEMD:-true}" == true ]]; then
        memory=$(awk '/MemTotal/ {printf "%.0fK", $2 * 0.95}' /proc/meminfo)
        if [[ "${COLLECT_COREDUMPS:-false}" == true ]]; then
            inner=(prlimit --core=unlimited:unlimited setpriv --reuid="$(id -u)" --regid="$(id -g)" --init-groups --)
        else
            inner=(sudo -n -E -u "$(id -un)" --)
        fi
        run_command=(sudo -n -E systemd-run --scope --unit="ya-${GITHUB_RUN_ID:-local}-$retry-$$.scope"
            -p "MemoryMax=$memory" -p MemorySwapMax=0 -- "${inner[@]}" "${command[@]}")
    fi
    build_rc=0
    "${run_command[@]}" 2>&1 | tee -a "$PUBLIC_DIR/ya_make_output.txt" || build_rc=$?
    printf '%s\n' "$build_rc" > "$CI_STATE_DIR/build-rc"
    [[ -f "$report" ]] || { echo 'ya did not produce a results report' >&2; exit 1; }
    gzip -c "$report" > "$CURRENT_PUBLIC_DIR/orig_report.json.gz"
    "$CI_PYTHON" "$TEST_YA_HELPERS_DIR/transform_build_results.py" --build-results-report "$report" \
        --test_dir "$TEST_META_INFO" -m "$MUTED_YA_FILE" --ya_out "$YA_MAKE_OUT_DIR" \
        --public_dir "$PUBLIC_DIR" --public_dir_url "$PUBLIC_DIR_URL" \
        --log_out_dir "try_$retry/artifacts/logs/" --test_stuff_out "try_$retry/test_artifacts/"
    cp "$report" "$LAST_BUILD_RESULTS_REPORT"
    check_rc=0
    "$CI_PYTHON" "$TEST_YA_HELPERS_DIR/fail-checker.py" "$report" \
        --output_path "$CURRENT_PUBLIC_DIR/failed_count.txt" || check_rc=$?
    printf '%s\n' "$check_rc" > "$CI_STATE_DIR/test-rc"
    last_retry=0
    if (( build_rc != 0 || check_rc == 0 || retry == TEST_RETRY_COUNT )); then last_retry=1; fi
    summary_args=()
    if [[ -n "${PR_NUMBER:-}" ]]; then summary_args+=(--pr_number "$PR_NUMBER"); fi
    if [[ -n "${GITHUB_RUN_ID:-}" ]]; then summary_args+=(--workflow_run_id "$GITHUB_RUN_ID"); fi
    if (( build_rc != 0 )); then summary_args+=(--build_failed); fi
    GITHUB_STEP_SUMMARY='' "$CI_PYTHON" "$TEST_YA_HELPERS_DIR/generate-summary.py" \
        --summary_links "$SUMMARY_LINKS" --public_dir "$PUBLIC_DIR" --public_dir_url "$PUBLIC_DIR_URL" \
        --build_preset "$BUILD_PRESET" --branch "$BASE_BRANCH" \
        --status_report_file "$CURRENT_PUBLIC_DIR/status.txt" --is_retry "$((retry > 1))" \
        --is_last_retry "$last_retry" --is_test_result_ignored "$IS_TEST_RESULT_IGNORED" \
        --comment_color_file "$CURRENT_PUBLIC_DIR/summary_color.txt" \
        --comment_text_file "$CURRENT_PUBLIC_DIR/summary_text.txt" "${summary_args[@]}" \
        Tests "$CURRENT_PUBLIC_DIR/ya-test.html" "$report"
    cp "$CURRENT_PUBLIC_DIR/summary_text.txt" "$PUBLIC_DIR/summary_text.txt"
    cp "$CURRENT_PUBLIC_DIR/summary_color.txt" "$PUBLIC_DIR/summary_color.txt"
    previous=$report
    if (( last_retry )); then break; fi
    if [[ "${COLLECT_COREDUMPS:-false}" == true ]]; then sudo find /coredumps -mindepth 1 -delete; fi
done
if (( build_rc != 0 || (check_rc != 0 && IS_TEST_RESULT_IGNORED == 0) )); then exit 1; fi
