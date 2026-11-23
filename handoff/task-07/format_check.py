#!/usr/bin/env python3
"""Run strict, non-mutating format checks for the declared guest/storage inputs."""

import argparse
import json
import pathlib
import tempfile

from verify import Redactor, digest, discover, process_environment, run_stage


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    task = pathlib.Path(__file__).resolve().parent
    parser.add_argument('--output', type=pathlib.Path, default=task / 'evidence/format-final')
    args = parser.parse_args()
    root = task.parents[1]
    repo, _, package, _ = discover(root)
    names = ('UTMWindowsGuestProvider.swift', 'WindowsGuestTransport.swift',
             'UTMWindowsGuestProviderTests.swift', 'UTMGuestSession.swift',
             'UTMGuestStoragePreflight.swift', 'UTMGuestStoragePreflightTests.swift')
    sources = []
    for name in names:
        matches = [path for path in package.rglob(name)
                   if not any(part in {'.git', '.build'} for part in path.parts)]
        if len(matches) != 1:
            raise ValueError('format_input_not_unique')
        sources.extend(matches)
    output = args.output.resolve()
    if any(path.resolve().is_relative_to(output) for path in sources):
        raise ValueError('output_overlaps_inputs')
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='task-07-format-final-') as directory:
        redactor = Redactor(root, repo, package, pathlib.Path(directory))
        before = {redactor(str(path.relative_to(repo))): digest(path.read_bytes()) for path in sources}
        stage = run_stage('strict-swift-format', ['xcrun', 'swift-format', 'lint', '--strict',
                                                 *map(str, sources)],
                          repo, process_environment(), output, redactor, 90)
        after = {redactor(str(path.relative_to(repo))): digest(path.read_bytes()) for path in sources}
        report = {'schema': 'task-07-format-v1', 'stage': stage, 'inputSHA256': before,
                  'inputCount': len(before), 'inputsStableDuringRun': before == after,
                  'toolSourceSHA256': digest(pathlib.Path(__file__).read_bytes()),
                  'passed': stage['exitCode'] == 0 and before == after,
                  'scope': 'six explicit guest/session/storage source and test files; no repository-wide format claim'}
        (output / 'format.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps({'formatPassed': report['passed'], 'inputCount': len(before)}))
        return 0 if report['passed'] else 1


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError):
        print(json.dumps({'passed': False, 'error': 'format_check_setup_failed'}))
        raise SystemExit(1)
