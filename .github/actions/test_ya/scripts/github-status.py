#!/usr/bin/env python3
"""Publish only explicit source-repository statuses; workflow context is never impersonated."""
import json
import os
from pathlib import Path
from urllib.request import Request, urlopen


def main():
    if os.environ.get('POST_STATUSES', 'false') != 'true':
        return
    token = os.environ['SOURCE_GITHUB_TOKEN']
    repository = os.environ['SOURCE_REPOSITORY']
    sha = os.environ['SOURCE_HEAD_SHA']
    prefix = os.environ.get('STATUS_CONTEXT_PREFIX', 'nebius-ci/')
    preset = os.environ['BUILD_PRESET']
    override = os.environ.get('STATUS_STATE')
    state_dir = Path(os.environ['CI_STATE_DIR'])
    def rc(name):
        path = state_dir / name
        return int(path.read_text()) if path.is_file() else 1
    kinds = ['build', 'test'] if os.environ.get('RUN_TESTS', 'true') == 'true' else ['build']
    server = os.environ.get('GITHUB_SERVER_URL', 'https://github.com')
    target = f"{server}/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
    for kind in kinds:
        if override:
            state = override
        elif kind == 'build':
            state = 'success' if rc('build-rc') == 0 else 'failure'
        else:
            ignored = os.environ.get('IS_TEST_RESULT_IGNORED') == '1'
            state = 'success' if rc('run-rc') == 0 and (ignored or rc('test-rc') == 0) else 'failure'
        payload = {'state': state, 'context': f'{prefix}{kind}_{preset}', 'target_url': target,
                   'description': 'Check started' if state == 'pending' else f'{kind}: {state}'}
        request = Request(f'https://api.github.com/repos/{repository}/statuses/{sha}',
                          data=json.dumps(payload).encode(), method='POST',
                          headers={'Authorization': f'Bearer {token}', 'Accept': 'application/vnd.github+json',
                                   'X-GitHub-Api-Version': '2022-11-28'})
        with urlopen(request, timeout=30) as response:
            response.read()


if __name__ == '__main__':
    main()
