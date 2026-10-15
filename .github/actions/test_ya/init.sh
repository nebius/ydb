#!/usr/bin/env bash
set -euo pipefail
: "${SOURCE_DIR:?}" "${BUILD_TARGET:?}" "${GITHUB_ENV:?}"
SOURCE_DIR=$(cd "$SOURCE_DIR" && pwd)
[[ "$SOURCE_DIR" != / ]]
: "${S3_URL_PREFIX:?S3 setup must precede test_ya}"
if [[ "${SOURCE_REPOSITORY:-}" != "${GITHUB_REPOSITORY:-}" &&
      ( "${POST_PR_COMMENTS:-false}" == true || "${POST_STATUSES:-false}" == true ) &&
      -z "${SOURCE_GITHUB_TOKEN:-}" ]]; then
    echo '::error::Cross-repository publication requires source_github_token'
    exit 1
fi
TEST_YA_ACTION_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEST_YA_HELPERS_DIR="$TEST_YA_ACTION_PATH/scripts"
export YA_EXECUTABLE="$TEST_YA_ACTION_PATH/ya"
export YA_SOURCE_ROOT="$SOURCE_DIR"
export YA_NO_RESPAWN=1
CI_STATE_DIR=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/test-ya.XXXXXX")
if [[ -z "${CI_PYTHON:-}" ]]; then
    python3 -m venv "$CI_STATE_DIR/venv"
    CI_PYTHON="$CI_STATE_DIR/venv/bin/python"
    "$CI_PYTHON" -m pip install --disable-pip-version-check -r "$TEST_YA_ACTION_PATH/requirements.txt"
fi
# Fail here, before build/finalization, rather than during report processing.
"$CI_PYTHON" -c 'import ydb, jinja2, github, yaml'
export TEST_TOOL_BIN=''
if [[ -n "${TEST_TOOL_URL:-}" ]]; then
    TEST_TOOL_BIN="$CI_STATE_DIR/test_tool"
    curl --fail --location --retry 5 --retry-delay 2 --connect-timeout 30 \
        --output "$TEST_TOOL_BIN.part" "$TEST_TOOL_URL"
    chmod 755 "$TEST_TOOL_BIN.part"
    mv "$TEST_TOOL_BIN.part" "$TEST_TOOL_BIN"
fi
TMP_DIR="$SOURCE_DIR/tmp"
PUBLIC_DIR="$TMP_DIR/results"
PUBLIC_DIR_URL=${S3_URL_PREFIX%/}
YA_MAKE_OUT_DIR="$TMP_DIR/out"
rm -rf "$PUBLIC_DIR"
mkdir -p "$PUBLIC_DIR" "$YA_MAKE_OUT_DIR"
SUMMARY_LINKS="$PUBLIC_DIR/summary_links.txt"
export LAST_BUILD_RESULTS_REPORT="$PUBLIC_DIR/last_report.json"
BUILD_PRESET=${BUILD_PRESET:-relwithdebinfo}
BASE_BRANCH=${BASE_BRANCH:-main}
cpus=$(nproc)
link_threads=$((cpus / 4))
TEST_THREADS=${TEST_THREADS:-$cpus}
LINK_THREADS=${LINK_THREADS:-$((link_threads > 0 ? link_threads : 1))}
TEST_SIZES=${TEST_SIZES:-small,medium}
ORIGINAL_HEAD=$(git -C "$SOURCE_DIR" rev-parse HEAD)
SOURCE_HEAD_SHA=${SOURCE_HEAD_SHA:-$ORIGINAL_HEAD}
export IS_TEST_RESULT_IGNORED=0
case "$BUILD_PRESET" in
    release-tsan|release-msan) IS_TEST_RESULT_IGNORED=1 ;;
esac
if [[ -z "${TEST_RETRY_COUNT:-}" ]]; then
    case "$BUILD_PRESET" in release-*) TEST_RETRY_COUNT=1 ;; *) TEST_RETRY_COUNT=3 ;; esac
fi
[[ "$TEST_RETRY_COUNT" =~ ^[1-9][0-9]*$ ]]
# Passwords and virtualenv are outside PUBLIC_DIR and never uploaded.
BAZEL_REMOTE_PASSWORD_FILE=''
if [[ -n "${REMOTE_CACHE_PASSWORD:-}" ]]; then
    BAZEL_REMOTE_PASSWORD_FILE="$CI_STATE_DIR/cache-password"
    (umask 077; printf '%s' "$REMOTE_CACHE_PASSWORD" > "$BAZEL_REMOTE_PASSWORD_FILE")
fi
if [[ -n "${MUTE_FILE:-}" ]]; then
    [[ "$MUTE_FILE" == /* ]] || MUTE_FILE="$SOURCE_DIR/$MUTE_FILE"
else
    MUTE_FILE=$("$CI_PYTHON" "$TEST_YA_HELPERS_DIR/mute/mute_helper.py" resolve-path --preset "$BUILD_PRESET")
fi
cp "$MUTE_FILE" "$PUBLIC_DIR/muted-tests.txt"
export MUTED_YA_FILE="$PUBLIC_DIR/muted-tests.txt"
printf '00 [Artifacts](%s/index.html)\n20 [Ya make output](%s/ya_make_output.txt)\n' \
    "$PUBLIC_DIR_URL" "$PUBLIC_DIR_URL" > "$SUMMARY_LINKS"
# Propagate only explicit, non-secret settings. Delimiters also support multiline args.
delimiter="CI_$("$CI_PYTHON" -c 'import secrets; print(secrets.token_hex(16))')"
for key in TEST_YA_ACTION_PATH TEST_YA_HELPERS_DIR YA_EXECUTABLE YA_SOURCE_ROOT YA_NO_RESPAWN TEST_TOOL_BIN CI_STATE_DIR CI_PYTHON SOURCE_DIR SOURCE_REPOSITORY \
    SOURCE_HEAD_SHA SOURCE_BASE_SHA ORIGINAL_HEAD PR_NUMBER POST_PR_COMMENTS POST_STATUSES STATUS_CONTEXT_PREFIX \
    BUILD_TARGET BUILD_PRESET TEST_SIZES TEST_TYPES TEST_THREADS LINK_THREADS ADDITIONAL_YA_MAKE_ARGS \
    INCREMENT RUN_TESTS TEST_RETRY_COUNT BASE_BRANCH ADD_VCS_INFO COLLECT_COREDUMPS USE_SYSTEMD \
    REMOTE_CACHE_URI REMOTE_CACHE_USERNAME PUT_BUILD_RESULTS_TO_CACHE BAZEL_REMOTE_PASSWORD_FILE \
    TMP_DIR PUBLIC_DIR PUBLIC_DIR_URL YA_MAKE_OUT_DIR SUMMARY_LINKS LAST_BUILD_RESULTS_REPORT \
    MUTED_YA_FILE IS_TEST_RESULT_IGNORED; do
    printf '%s<<%s\n%s\n%s\n' "$key" "$delimiter" "${!key-}" "$delimiter" >> "$GITHUB_ENV"
done
echo "Python dependencies ready; threads: tests=$TEST_THREADS links=$LINK_THREADS"
