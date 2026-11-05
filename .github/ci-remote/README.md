# CI remote executor (Nebius)

Thin host: checkout `ydb-platform/ydb@code_ref`, run platform `.github/actions/build_and_test_ya` from that tree. Do not sync platform workflows into this repo.

## Pre-merge smoke

Until `ci_remote_executor.yml` is on the default branch, `trigger-pr-check.yml` is temporarily the same executor (registered `workflow_dispatch` filename).

Restore before merge:

```bash
cp .github/ci-remote/trigger-pr-check.orig.yml .github/workflows/trigger-pr-check.yml
```

Smoke (from this branch):

```bash
gh workflow run trigger-pr-check.yml --ref dev/ci-remote-executor \
  -f code_ref=main \
  -f 'job_inputs={"build_target":"ydb/library/yql/utils","run_tests":"false","custom_branch_name":"nebius-smoke_manual"}' \
  -f 'runs_on=["self-hosted","linux","amd64-large"]'
```
