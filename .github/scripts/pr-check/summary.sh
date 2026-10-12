#!/usr/bin/env bash
# Bash/jq adaptation of generate-summary.py's render_line/render/get_comment_text.
# Generates reusable comment Markdown, but only publishes it to the job summary.
set -euo pipefail

: "${RESULTS_DIR:?}" "${PR_ID:?}" "${BUILD_PRESET:?}" "${BUILD_ARCH:?}"
: "${PR_OWNER:?}" "${PR_REPO:?}"
: "${BUILD_OUTCOME:?}" "${GITHUB_STEP_SUMMARY:?}"
mkdir -p "$RESULTS_DIR"

cell() {
    jq -nr --arg value "$1" '$value | @html | gsub("\\|"; "&#124;") | gsub("`"; "&#96;") | gsub("[\r\n]"; " ")'
}

sha=''
duration='—'
if [[ -f "$RESULTS_DIR/build-meta.json" ]]; then
    sha=$(jq -r '.head_sha' "$RESULTS_DIR/build-meta.json")
    duration="$(jq -r '.duration_seconds' "$RESULTS_DIR/build-meta.json")s"
fi

case "$BUILD_OUTCOME" in
    success) status='✅ Passed' ;;
    failure) status='❌ Failed' ;;
    cancelled) status='⏹ Cancelled' ;;
    *) status='⏭ Not run' ;;
esac
if [[ "${MERGE_OUTCOME:-}" == failure ]]; then
    status='❌ Merge preparation failed'
fi

report_available=false
if [[ -f "$RESULTS_DIR/report.json" ]] && \
    jq -e '.results | type == "array"' "$RESULTS_DIR/report.json" >/dev/null 2>&1; then
    report_available=true
fi
counts() {
    if [[ "$report_available" == false ]]; then
        printf '— | — | — | — | — | —'
        return
    fi
    # Raw ya reports use OK; suite-level test aggregates must not be double-counted.
    jq -r --arg kind "$1" '
        [.results[] | select(.type == $kind and ($kind != "test" or .suite != true))] as $entries |
        [($entries | length),
         ([$entries[] | select(.status == "OK" or .status == "PASSED")] | length),
         ([$entries[] | select(.status == "ERROR")] | length),
         ([$entries[] | select(.status == "FAILED")] | length),
         ([$entries[] | select(.status == "SKIPPED" or .status == "NOT_LAUNCHED")] | length),
         ([$entries[] | select(.status != "OK" and .status != "PASSED" and
             .status != "ERROR" and .status != "FAILED" and
             .status != "SKIPPED" and .status != "NOT_LAUNCHED")] | length)] |
        map(tostring) | join(" | ")
    ' "$RESULTS_DIR/report.json"
}

source_repo="$PR_OWNER/$PR_REPO"
source_url="${GITHUB_SERVER_URL:-https://github.com}/$source_repo"
pr_url="$source_url/pull/$PR_ID"
run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
comment="$RESULTS_DIR/comment.md"
{
    printf '### PR build and test check\n\n'
    printf '[%s#%s](%s) · [Workflow run](%s)\n\n' "$(cell "$source_repo")" "$PR_ID" "$pr_url" "$run_url"
    for field in BASE_SHA PR_HEAD_SHA; do
        source_sha=${!field:-}
        if [[ -n "$source_sha" ]]; then
            # shellcheck disable=SC2016 # Backticks are literal Markdown.
            printf '%s: [`%s`](%s/commit/%s)\n\n' "$field" "$source_sha" "$source_url" "$source_sha"
        fi
    done
    if [[ -n "$sha" ]]; then
        # shellcheck disable=SC2016 # Backticks are literal Markdown.
        printf 'Tested merge commit: [`%s`](%s/commit/%s)\n\n' "$sha" "$source_url" "$sha"
    fi
    printf '**%s** · %s · %s · %s\n\n' "$status" "$(cell "$BUILD_ARCH")" "$(cell "$BUILD_PRESET")" "$duration"
    printf '| Kind | TOTAL | PASSED | ERRORS | FAILED | SKIPPED | OTHER |\n'
    printf '| :--- | ---: | ---: | ---: | ---: | ---: | ---: |\n'
    printf '| Build | %s |\n' "$(counts build)"
    printf '| Tests | %s |\n\n' "$(counts test)"
    if [[ "$report_available" == false ]]; then
        printf 'Build/test results report is unavailable; status is based on step outcomes.\n\n'
    else
        failures=$(jq -r '
            [.results[] | select((.status == "FAILED" or .status == "ERROR") and .suite != true)] |
            .[:20][] | ((.path // "(unknown target)") +
                (if .subtest_name then "/" + .subtest_name else "" end)) |
            @html | gsub("\\|"; "&#124;") | gsub("`"; "&#96;") | gsub("[\r\n]"; " ") | "- " + .
        ' "$RESULTS_DIR/report.json")
        if [[ -n "$failures" ]]; then
            printf '<details>\n<summary>Failed targets/tests (up to 20)</summary>\n\n%s\n\n</details>\n\n' "$failures"
        fi
    fi
    if [[ -n "${ARTIFACT_URL:-}" ]]; then
        printf '[Logs and report](%s)\n\n' "$ARTIFACT_URL"
    elif [[ -n "${ARTIFACT_NAME:-}" ]]; then
        # shellcheck disable=SC2016
        printf 'Logs, JSON report and this Markdown are saved in the `%s` run artifact.\n\n' "$(cell "$ARTIFACT_NAME")"
    fi
    printf 'This report has not been posted to the PR.\n'
} > "$comment"
tee -a "$GITHUB_STEP_SUMMARY" < "$comment"
