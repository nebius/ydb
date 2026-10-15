#!/usr/bin/env bash
set -euo pipefail
: "${CI_STATE_DIR:?}" "${PUBLIC_DIR:?}" "${PUBLIC_DIR_URL:?}" "${CI_PYTHON:?}"
# This script is only invoked after successful Init. Never publish an empty / path.
[[ "$PUBLIC_DIR" == /* && "$PUBLIC_DIR" != / && -d "$PUBLIC_DIR" ]]
run_rc=1
if [[ -f "$CI_STATE_DIR/run-rc" ]]; then run_rc=$(< "$CI_STATE_DIR/run-rc"); fi
outcome=failure
if [[ "$run_rc" == 0 ]]; then outcome=success; fi
summary="$PUBLIC_DIR/summary_text.txt"
if [[ ! -f "$summary" ]]; then
    printf 'Build/graph/report processing failed before a complete report was generated.\n\n[Logs and artifacts](%s/index.html).\n' \
        "$PUBLIC_DIR_URL" > "$summary"
    printf red > "$PUBLIC_DIR/summary_color.txt"
fi
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '### Ya check: %s · %s\n\n' "$outcome" "$BUILD_PRESET" >> "$GITHUB_STEP_SUMMARY"
    if [[ -f "$PUBLIC_DIR/graph_summary.md" ]]; then tee -a "$GITHUB_STEP_SUMMARY" < "$PUBLIC_DIR/graph_summary.md"; fi
    tee -a "$GITHUB_STEP_SUMMARY" < "$summary"
fi
final_rc=0
"$CI_PYTHON" "$TEST_YA_HELPERS_DIR/indexer.py" -r "$PUBLIC_DIR" || final_rc=1
s3cmd --config "$S3CMD_CONFIG" sync --follow-symlinks ${S3_PUBLIC_ACL_FLAG:+"$S3_PUBLIC_ACL_FLAG"} \
    --no-progress --stats --no-mime-magic --guess-mime-type --no-check-md5 \
    "$PUBLIC_DIR/" "${S3_BUCKET_PATH%/}/" || final_rc=1
color=$(< "$PUBLIC_DIR/summary_color.txt")
"$CI_PYTHON" "$TEST_YA_HELPERS_DIR/comment-pr.py" --color "$color" < "$summary" || final_rc=1
if (( final_rc != 0 )); then
    STATUS_STATE=failure "$CI_PYTHON" "$TEST_YA_HELPERS_DIR/github-status.py" || true
else
    "$CI_PYTHON" "$TEST_YA_HELPERS_DIR/github-status.py" || final_rc=1
fi
if (( final_rc != 0 )); then
    outcome=failure
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf '\n**Report publication failed.**\n' >> "$GITHUB_STEP_SUMMARY"; fi
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'status=%s\nsuccess=%s\n' "$outcome" "$([[ "$outcome" == success ]] && echo true || echo false)" >> "$GITHUB_OUTPUT"
fi
exit "$final_rc"
