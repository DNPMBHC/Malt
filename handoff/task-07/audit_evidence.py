#!/usr/bin/env python3
"""Re-sanitize task-owned evidence and verify its shareable text artifacts."""

import argparse
import json
import os
import pathlib
import re
import tempfile
from urllib.parse import quote

from verify import Redactor, discover, summarize_test_xml


def redact_object(value, redactor):
    if isinstance(value, str):
        return redactor(value)
    if isinstance(value, list):
        return [redact_object(item, redactor) for item in value]
    if isinstance(value, dict):
        return {redactor(key): redact_object(item, redactor) for key, item in value.items()}
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rewrite', action='store_true')
    args = parser.parse_args()
    task = pathlib.Path(__file__).resolve().parent
    workspace = task.parents[1]
    repo, _, package, _ = discover(workspace)
    with tempfile.TemporaryDirectory(prefix='task-07-audit-') as directory:
        redactor = Redactor(workspace, repo, package, pathlib.Path(directory))
        forbidden = {str(workspace), str(repo), str(package), str(pathlib.Path.home()),
                     repo.name, package.name, workspace.name, *redactor.identities}
        forbidden |= {quote(value, safe='/') for value in forbidden}
        secrets = {value for key, value in os.environ.items()
                   if re.search('TOKEN|SECRET|PASSWORD|API_KEY|PRIVATE_KEY|CREDENTIAL', key)
                   and len(value) >= 6}
        findings = []
        rewritten = 0
        files = 0
        for path in sorted(task.rglob('*')):
            if not path.is_file() or any(part in {'.tools', '__pycache__', '.dev-logs'} for part in path.parts):
                continue
            if path.suffix not in {'.py', '.sh', '.json', '.jsonl', '.xml', '.md', '.log', '.csv'}:
                continue
            text = path.read_text()
            if args.rewrite and 'evidence' in path.relative_to(task).parts:
                if path.suffix == '.json':
                    safe = json.dumps(redact_object(json.loads(text), redactor), ensure_ascii=False, indent=2) + '\n'
                elif path.suffix == '.xml':
                    _, safe = summarize_test_xml(text.encode(), redactor)
                elif path.suffix == '.jsonl':
                    safe = '\n'.join(json.dumps(redact_object(json.loads(line), redactor), ensure_ascii=False)
                                       for line in text.splitlines() if line.strip()) + '\n'
                else:
                    safe = redactor(text)
                if text != safe:
                    path.write_text(safe)
                    text = safe
                    rewritten += 1
            kinds = []
            if any(value.lower() in text.lower() for value in forbidden if value):
                kinds.append('local-identifier')
            if any(value in text for value in secrets):
                kinds.append('environment-secret')
            if path.suffix in {'.log', '.xml', '.json', '.jsonl'} and re.search(r'(?m)^\s*export\s+', text):
                kinds.append('exported-environment')
            if path.suffix == '.json':
                json.loads(text)
            if kinds:
                findings.append({'file': redactor(str(path.relative_to(task))), 'types': kinds})
            files += 1
        result = {'schema': 'task-07-privacy-v1', 'checkedFiles': files,
                  'rewrittenFiles': rewritten, 'findings': findings, 'passed': not findings,
                  'scope': 'known local identifiers, exported environment, and current secret values; no raw matches retained'}
        (task / 'evidence/privacy.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result))
        return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
