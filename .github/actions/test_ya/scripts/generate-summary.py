#!/usr/bin/env python3
"""Reporting-only adaptation of upstream generate-summary.py; no analytics or history."""
import argparse
import dataclasses
import json
import math
import os
from enum import Enum
from pathlib import Path
from urllib.parse import urlsplit

from jinja2 import Environment, FileSystemLoader, StrictUndefined


class TestStatus(Enum):
    PASS = 0
    FAIL = 1
    ERROR = 2
    SKIP = 3
    MUTE = 4


@dataclasses.dataclass
class TestResult:
    classname: str
    name: str
    status: TestStatus
    log_urls: dict
    elapsed: float
    status_description: str
    error_type: str

    @property
    def full_name(self):
        return f"{self.classname}/{self.name}" if self.name else self.classname

    @property
    def elapsed_display(self):
        minutes, seconds = divmod(math.ceil(self.elapsed * 10) / 10, 60)
        return (f"{int(minutes)}m " if minutes else "") + f"{seconds:.1f}s"

    @classmethod
    def from_build_results_report(cls, result):
        name = result.get("name") or ""
        if result.get("subtest_name"):
            name = f"{name}.{result['subtest_name']}" if name else result['subtest_name']
        status = {
            'OK': TestStatus.PASS, 'PASSED': TestStatus.PASS, 'FAILED': TestStatus.FAIL,
            'ERROR': TestStatus.ERROR, 'SKIPPED': TestStatus.SKIP,
            'NOT_LAUNCHED': TestStatus.SKIP, 'MUTE': TestStatus.MUTE,
        }.get(result.get('status'), TestStatus.ERROR)
        links = {key: value[0] for key, value in (result.get('links') or {}).items()
                 if isinstance(value, list) and value and isinstance(value[0], str)}
        try:
            elapsed = float(result.get('duration') or 0)
            if not math.isfinite(elapsed) or elapsed < 0:
                elapsed = 0
        except (TypeError, ValueError):
            elapsed = 0
        return cls(result.get('path') or '', name, status, links, elapsed,
                   result.get('rich-snippet') or '', result.get('error_type') or '')


class TestSummary:
    def __init__(self, tests, report_url, is_retry=False):
        self.tests = tests
        self.report_url = report_url
        self.is_retry = is_retry
        self.is_failed = any(test.status in (TestStatus.FAIL, TestStatus.ERROR) for test in tests)

    @staticmethod
    def render_line(items):
        return f"| {' | '.join(items)} |"

    def render(self):
        statuses = [TestStatus.PASS, TestStatus.ERROR, TestStatus.FAIL, TestStatus.SKIP, TestStatus.MUTE]
        counts = [(len(self.tests), '')] + [
            (sum(test.status == status for test in self.tests), '#' + status.name) for status in statuses
        ]
        values = [f'[{count}]({self.report_url}{anchor})' if count else '0' for count, anchor in counts]
        if self.is_retry:
            values[0] += ' (retried tests)'
        return [self.render_line(['TESTS', 'PASSED', 'ERRORS', 'FAILED', 'SKIPPED', 'MUTED']),
                self.render_line(['---:'] * 6), self.render_line(values)]


def safe_link(url):
    return url if urlsplit(url).scheme in ('', 'http', 'https', 'file') else ''


def render_testlist_html(tests, filename, build_preset, branch, pr_number=None, workflow_run_id=None):
    env = Environment(loader=FileSystemLoader(Path(__file__).parent / 'templates'),
                      undefined=StrictUndefined, autoescape=True)
    env.filters['safe_link'] = safe_link
    order = [TestStatus.ERROR, TestStatus.FAIL, TestStatus.SKIP, TestStatus.MUTE, TestStatus.PASS]
    groups = {status: sorted((test for test in tests if test.status == status), key=lambda test: test.full_name)
              for status in order}
    server = os.environ.get('GITHUB_SERVER_URL', 'https://github.com')
    source_repo = os.environ.get('SOURCE_REPOSITORY', 'ydb-platform/ydb')
    run_repo = os.environ.get('GITHUB_REPOSITORY', source_repo)
    content = env.get_template('summary.html').render(
        status_order=order, tests=groups, build_preset=build_preset, branch=branch,
        pr_url=f'{server}/{source_repo}/pull/{pr_number}' if pr_number else None,
        workflow_url=f'{server}/{run_repo}/actions/runs/{workflow_run_id}' if workflow_run_id else None,
        commit_sha=os.environ.get('GITHUB_HEAD_SHA', ''),
    )
    Path(filename).write_text(content, encoding='utf-8')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--public_dir', required=True)
    parser.add_argument('--public_dir_url', required=True)
    parser.add_argument('--summary_links', required=True)
    parser.add_argument('--build_preset', default='relwithdebinfo')
    parser.add_argument('--branch', default='main')
    parser.add_argument('--status_report_file')
    parser.add_argument('--is_retry', type=int, default=0)
    parser.add_argument('--is_last_retry', type=int, default=1)
    parser.add_argument('--is_test_result_ignored', type=int, default=0)
    parser.add_argument('--comment_color_file', required=True)
    parser.add_argument('--comment_text_file', required=True)
    parser.add_argument('--pr_number', type=int)
    parser.add_argument('--workflow_run_id')
    parser.add_argument('--build_failed', action='store_true')
    parser.add_argument('args', nargs='+', metavar='TITLE html_out report_path')
    args = parser.parse_args()
    if len(args.args) % 3:
        parser.error('Expected TITLE html_out report_path triples')
    body = []
    total_tests = 0
    failed = args.build_failed
    for index in range(0, len(args.args), 3):
        title, html_file, report_file = args.args[index:index + 3]
        report = json.loads(Path(report_file).read_text(encoding='utf-8'))
        if not isinstance(report.get('results'), list):
            raise ValueError(f'Expected results array in {report_file}')
        tests = [TestResult.from_build_results_report(result) for result in report['results']
                 if result.get('status') and result.get('type') != 'build' and not result.get('suite')]
        total_tests += len(tests)
        html_path = Path(html_file)
        if not html_path.is_absolute():
            html_path = Path(args.public_dir) / html_path
        html_path.parent.mkdir(parents=True, exist_ok=True)
        report_url = args.public_dir_url.rstrip('/') + '/' + html_path.relative_to(args.public_dir).as_posix()
        render_testlist_html(tests, html_path, args.build_preset, args.branch, args.pr_number, args.workflow_run_id)
        summary = TestSummary(tests, report_url, bool(args.is_retry))
        failed |= summary.is_failed and not args.is_test_result_ignored
        body += [f'#### {title}', ''] + summary.render() + ['']
    links = []
    for line in sorted(Path(args.summary_links).read_text(encoding='utf-8').splitlines()):
        if line.strip():
            links.append(line.split(' ', 1)[1])
    outcome = 'failure' if failed else 'success'
    color = 'red' if failed and args.is_last_retry else 'yellow' if failed else 'green'
    text = 'Build/tests failed.' if failed else 'Tests successful.' if total_tests else 'No tests were reported.'
    if failed and not args.is_last_retry:
        text += ' Going to retry failed tests.'
    if args.is_test_result_ignored:
        text += ' Sanitizer test failures are non-blocking.'
    mute_url = args.public_dir_url.rstrip('/') + '/muted-tests.txt'
    content = '\n'.join([text, '', ' | '.join(links), ''] + body + [f'[Mute rules used in this run]({mute_url}).', ''])
    Path(args.comment_text_file).write_text(content, encoding='utf-8')
    Path(args.comment_color_file).write_text(color, encoding='utf-8')
    if args.status_report_file:
        Path(args.status_report_file).write_text(outcome, encoding='utf-8')
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a', encoding='utf-8') as stream:
            stream.write(content)
    else:
        print(content)


if __name__ == '__main__':
    main()
