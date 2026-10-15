#!/usr/bin/env python
import datetime
import os
import sys
import argparse


def update_pr_comment_text(pr, build_preset: str, run_number: int, color: str, text: str, rewrite: bool, no_timestamp: bool = False):
    run_repo = os.environ.get('GITHUB_REPOSITORY', '')
    header = f"<!-- status repo={run_repo}, pr={pr.number}, preset={build_preset}, run={run_number} -->"

    body = comment = None
    for c in pr.get_issue_comments():
        if c.body.startswith(header):
            print(f"found comment id={c.id}")
            comment = c
            if not rewrite:
                body = [c.body]
            break

    if body is None:
        body = [header]

    if no_timestamp:
        body.append(text)
    else:
        indicator = f":{color}_circle:"
        timestamp_str = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")
        body.append(f"{indicator} `{timestamp_str}` {text}")

    body = "\n".join(body)

    if comment is None:
        print(f"post new comment")
        pr.create_issue_comment(body)
    else:
        print(f"edit comment")
        comment.edit(body)


def main():
    if os.environ.get('POST_PR_COMMENTS', 'false') != 'true':
        # Drain pipelines such as `cat summary_text.txt | comment-pr.py`.
        sys.stdin.read()
        return
    from github import Github, Auth as GithubAuth

    parser = argparse.ArgumentParser()
    parser.add_argument("--rewrite", dest="rewrite", action="store_true")
    parser.add_argument("--color", dest="color", default="white")
    parser.add_argument("--no-timestamp", dest="no_timestamp", action="store_true", help="Skip adding timestamp to comment")
    parser.add_argument("text", type=argparse.FileType("r"), nargs="?", default="-")

    args = parser.parse_args()
    color = args.color

    run_number = int(os.environ.get("GITHUB_RUN_NUMBER", os.environ.get("GITHUB_RUN_ID", "0")))
    build_preset = os.environ["BUILD_PRESET"]

    pr_number = os.environ.get('PR_NUMBER')
    if not pr_number:
        print('::warning::No source PR number, skipping comment')
        return
    token = os.environ.get('SOURCE_GITHUB_TOKEN') or os.environ['GITHUB_TOKEN']
    gh = Github(auth=GithubAuth.Token(token))
    repository = os.environ.get('SOURCE_REPOSITORY') or os.environ['GITHUB_REPOSITORY']
    pr = gh.get_repo(repository).get_pull(int(pr_number))

    text = args.text.read()
    if text.endswith("\n"):
        # dirty hack because echo adds a new line 
        # and 'echo | comment-pr.py' leads to an extra newline  
        text = text[:-1]

    update_pr_comment_text(pr, build_preset, run_number, color, text, args.rewrite, args.no_timestamp)


if __name__ == "__main__":
    main()
