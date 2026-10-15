#!/usr/bin/env python3
"""Upstream graph_compare algorithm with argv-safe execution and checkout restoration."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def run(command, tool=False):
    print(f'++ {command!r}', flush=True)
    env = os.environ.copy()
    if tool:
        # Tool registry belongs to the pinned CI toolchain, not the PR branch.
        env['YA_SOURCE_ROOT'] = str(Path(__file__).resolve().parents[1] / 'config' / 'tools')
    subprocess.run(command, check=True, env=env)


def node_count(filename):
    graph = json.loads(Path(filename).read_text())
    return len(graph['graph'])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--command-file', required=True)
    parser.add_argument('--result-graph-path', required=True)
    parser.add_argument('--result-context-path', required=True)
    parser.add_argument('--summary-file', required=True)
    parser.add_argument('--work-dir', required=True)
    parser.add_argument('base_commit')
    parser.add_argument('head_commit')
    parser.add_argument('targets', nargs='+')
    args = parser.parse_args()
    command = json.loads(Path(args.command_file).read_text())
    original = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    Path(args.work_dir).mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=args.work_dir) as workdir:
        try:
            for name, sha in (('base', args.base_commit), ('head', args.head_commit)):
                run(['git', 'checkout', '--detach', sha])
                run(command + args.targets + ['--cache-tests', '--save-graph-to', f'{workdir}/graph_{name}.json',
                                              '--save-context-to', f'{workdir}/context_{name}.json'])
            run([command[0], 'tool', 'ygdiff', '--old', f'{workdir}/graph_base.json',
                 '--new', f'{workdir}/graph_head.json', '--cut', args.result_graph_path,
                 '--dump-uids', f'{workdir}/uids.json'], tool=True)
            run([command[0], 'tool', 'contexts_difference', f'{workdir}/context_base.json',
                 f'{workdir}/context_head.json', args.result_context_path, f'{workdir}/uids.json'], tool=True)
            Path(args.summary_file).write_text(
                '### Build graph comparison\n\n| Base nodes | Merge nodes | Affected nodes |\n'
                '| ---: | ---: | ---: |\n'
                f'| {node_count(f"{workdir}/graph_base.json")} | {node_count(f"{workdir}/graph_head.json")} | '
                f'{node_count(args.result_graph_path)} |\n\n'
            )
        finally:
            run(['git', 'checkout', '--detach', original])


if __name__ == '__main__':
    main()
