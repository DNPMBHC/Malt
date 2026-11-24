#!/usr/bin/env python3
"""Run locked dependency, package-test, and unsigned application build gates."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from zoneinfo import ZoneInfo
from urllib.parse import quote
from xml.etree import ElementTree


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def discover(workspace: pathlib.Path):
    projects = sorted(workspace.glob('*/*.xcodeproj')) + sorted(workspace.glob('*.xcodeproj'))
    if len(projects) != 1:
        raise ValueError('exactly one application project is required')
    project = projects[0]
    packages = sorted(project.parent.glob('*/Package.swift'))
    if len(packages) != 1:
        raise ValueError('exactly one local package is required')
    scheme = project / 'xcshareddata/xcschemes' / (project.stem + '.xcscheme')
    if not scheme.is_file():
        raise ValueError('shared application scheme is missing')
    return project.parent, project, packages[0].parent, scheme.stem


class Redactor:
    def __init__(self, workspace, repo, package, temporary):
        paths = [
            (str(package), '<workspace>/my-project/module-x'),
            (str(repo), '<workspace>/my-project'),
            (str(workspace), '<workspace>'),
            (str(pathlib.Path.home()), '<home>'),
            (str(temporary), '<build-cache>'),
        ]
        self.paths = sorted({variant: target for source, target in paths for variant in
                             (source, quote(source, safe='/'), source.replace(' ', '\\ '))}.items(),
                            key=lambda item: len(item[0]), reverse=True)
        self.names = sorted({package.name: 'ModuleX', repo.name: 'my-project', workspace.name: 'my-project'}.items(), key=lambda item: len(item[0]), reverse=True)
        self.identities = {pathlib.Path.home().name, *(os.environ.get(key, '') for key in
                           ('USER', 'LOGNAME', 'USERNAME', 'SUDO_USER'))} - {'', 'DNPMBHC'}

    @staticmethod
    def redact_assignments(text):
        identity_keys = ('USER|LOGNAME|USERNAME|SUDO_USER|HOSTNAME|COMPUTERNAME|'
                         'FULL_NAME|REAL_NAME|GIT_AUTHOR_NAME|GIT_COMMITTER_NAME|DEVELOPMENT_TEAM')
        secret_keys = r'[A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|PRIVATE_KEY|ACCESS_KEY|CREDENTIAL)[A-Z0-9_]*'
        assignment = re.compile(
            r'''(?P<prefix>(?<![\w])["']?(?P<key>''' + identity_keys + '|' + secret_keys + r''')["']?\s*[:=]\s*)'''
            r'''(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\r\n,;}\]]+)''', re.IGNORECASE)
        text = assignment.sub(lambda match: match['prefix'] +
                              ('<identity>' if re.fullmatch(identity_keys, match['key'], re.IGNORECASE)
                               else '<secret>'), text)
        return re.sub(r'(?im)(\bauthorization\s*:\s*)(?:Bearer|Basic)\s+[^\r\n]+',
                      r'\1<secret>', text)

    def __call__(self, value):
        text = re.sub(r'(?m)^\s*export\s+[^\r\n]*', '<environment redacted>', str(value))
        text = self.redact_assignments(text)
        for source, target in self.paths:
            text = text.replace(source, target)
        for source, target in self.names:
            text = re.sub(re.escape(source), target, text, flags=re.IGNORECASE)
        for identity in sorted(self.identities, key=len, reverse=True):
            text = re.sub(r'(?<![\w@])' + re.escape(identity) + r'(?![\w])', '<identity>', text)
        text = re.sub(r'/Users/[^/\s"\']+', '<home>', text)
        text = re.sub(r'/var/folders/[^\s"\']+', '<temporary>', text)
        text = re.sub(r'(?<![\w<>])/(?:Applications|Library|System|usr|bin|sbin|opt|private|var|tmp)/[^\s"\'<>]*', '<system-path>', text)
        text = re.sub(r'https?://[^\s"\'<>]+|git@[^\s"\'<>]+', '<dependency-remote>', text)
        text = re.sub(r'[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}', '<email>', text)
        text = re.sub(r'(DEVELOPMENT_TEAM\s*=\s*)[^;\s]+', r'\1<team>', text)
        return text


def process_environment(http_version=None):
    env = os.environ.copy()
    count = int(env.get('GIT_CONFIG_COUNT', '0'))
    env['GIT_CONFIG_COUNT'] = str(count + 2)
    env[f'GIT_CONFIG_KEY_{count}'] = 'url.https://github.com/.insteadOf'
    env[f'GIT_CONFIG_VALUE_{count}'] = 'git@github.com:'
    env[f'GIT_CONFIG_KEY_{count + 1}'] = 'url.https://github.com/.insteadOf'
    env[f'GIT_CONFIG_VALUE_{count + 1}'] = 'ssh://git@github.com/'
    env['GIT_TERMINAL_PROMPT'] = '0'
    env['GIT_HTTP_LOW_SPEED_LIMIT'] = '1'
    env['GIT_HTTP_LOW_SPEED_TIME'] = '20'
    if http_version is not None:
        if http_version not in {'HTTP/1.1', 'HTTP/2'}:
            raise ValueError('unsupported HTTP version')
        index = int(env['GIT_CONFIG_COUNT'])
        env['GIT_CONFIG_COUNT'] = str(index + 1)
        env[f'GIT_CONFIG_KEY_{index}'] = 'http.version'
        env[f'GIT_CONFIG_VALUE_{index}'] = http_version
    return env


def global_git_fingerprint():
    result = subprocess.run(['git', 'config', '--global', '--show-origin', '--list'], capture_output=True)
    return {'exitCode': result.returncode, 'sha256': digest(result.stdout + result.stderr)}


def source_snapshot(repo, redactor):
    # Include resources, build settings and ignored local inputs as well as source files.
    # Only tool state and build outputs are excluded; an extension allowlist misses assets.
    excluded = {'.git', '.build', 'DerivedData', 'xcuserdata', '__pycache__', '.DS_Store'}
    if shutil.which('rg') is not None:
        result = subprocess.run(['rg', '--files', '--hidden', '--no-ignore', '--null',
                                 '-g', '!.git', '-g', '!.build', '-g', '!DerivedData',
                                 '-g', '!xcuserdata', '-g', '!__pycache__', '-g', '!.DS_Store'],
                                cwd=repo, capture_output=True)
        if result.returncode not in [0, 1]:
            raise ValueError('source inventory failed')
        names = sorted(os.fsdecode(name) for name in result.stdout.split(b'\0') if name)
    else:
        discovered = []
        for current_root, dirnames, filenames in os.walk(repo):
            dirnames[:] = [name for name in dirnames if name not in excluded]
            base = pathlib.Path(current_root)
            for filename in filenames:
                if filename in excluded:
                    continue
                discovered.append(str((base / filename).relative_to(repo)))
        names = sorted(discovered)
    grouped = {}
    for name in names:
        if (repo / name).is_file():
            grouped.setdefault(redactor(name), []).append((name, digest((repo / name).read_bytes())))
    # Anonymized asset names may collide; retain every build input without exposing its name.
    return {key if len(entries) == 1 else key + '#input-' + digest(os.fsencode(name))[:16]: value
            for key, entries in grouped.items() for name, value in entries}


def summarize_test_xml(data, redactor):
    root = ElementTree.fromstring(data)
    local_name = lambda tag: tag.rsplit('}', 1)[-1]
    cases = [element for element in root.iter() if local_name(element.tag) == 'testcase']
    counts = {'total': len(cases)}
    for key, tag in [('failures', 'failure'), ('errors', 'error'), ('skipped', 'skipped')]:
        counts[key] = sum(any(local_name(child.tag) == tag for child in case) for case in cases)
    for element in root.iter():
        element.attrib.update({key: redactor(value) for key, value in element.attrib.items()})
        if element.text is not None:
            element.text = redactor(element.text)
        if element.tail is not None:
            element.tail = redactor(element.tail)
    return counts, ElementTree.tostring(root, encoding='unicode') + '\n'


def summarize_test_log(text, redactor):
    case_pattern = re.compile(
        r"^Test Case '(?P<name>.+)' (?P<state>started|passed|failed|skipped)"
        r"(?: \((?P<duration>[0-9.]+) seconds\))?\.$")
    summary_pattern = re.compile(
        r'^\s*Executed (?P<total>\d+) tests?, with '
        r'(?:(?P<skipped>\d+) tests? skipped and )?'
        r'(?P<failures>\d+) failures? \((?P<unexpected>\d+) unexpected\)')
    started, cases, summaries = [], [], []
    for line in text.splitlines():
        match = case_pattern.match(line)
        if match:
            if match['state'] == 'started':
                started.append(match['name'])
            else:
                cases.append(match.groupdict())
        match = summary_pattern.match(line)
        if match:
            summaries.append({key: int(value or 0) for key, value in match.groupdict().items()})
    counts = {'total': len(cases), 'failures': sum(case['state'] == 'failed' for case in cases),
              'errors': 0, 'skipped': sum(case['state'] == 'skipped' for case in cases)}
    counts['executed'] = counts['total'] - counts['skipped']
    counts['passed'] = counts['executed'] - counts['failures']
    complete = bool(cases) and sorted(started) == sorted(case['name'] for case in cases)
    unique = len({case['name'] for case in cases}) == len(cases)
    summary = summaries[-1] if summaries else None
    matches = summary is not None and all(summary[key] == counts[key] for key in ('total', 'failures', 'skipped'))
    suite = ElementTree.Element('testsuite', name='XCTest sequential log',
                              **{key: str(counts[key]) for key in ('total', 'failures', 'errors', 'skipped')})
    suite.set('tests', suite.attrib.pop('total'))
    properties = ElementTree.SubElement(suite, 'properties')
    ElementTree.SubElement(properties, 'property', name='provenance', value='sequential-xctest-log')
    for case in cases:
        element = ElementTree.SubElement(suite, 'testcase', name=redactor(case['name']),
                                         time=case['duration'] or '0')
        if case['state'] == 'skipped':
            ElementTree.SubElement(element, 'skipped', message='XCTest log reported skipped')
        elif case['state'] == 'failed':
            ElementTree.SubElement(element, 'failure', message='XCTest log reported failure')
    details = {'caseCounts': counts, 'finalSummary': summary, 'completeCases': complete,
               'uniqueCases': unique, 'summaryMatchesCases': matches,
               'consistent': complete and unique and matches,
               'errorClassification': 'XCTest unexpected failures are included in failures'}
    return (counts if cases else None,
            ElementTree.tostring(suite, encoding='unicode') + '\n' if cases else None, details)


def reconcile_test_results(log_text, xml_data, redactor):
    tests, generated_xml, log_details = summarize_test_log(log_text, redactor)
    native_counts, native_xml, native_error = None, None, None
    if xml_data is not None:
        try:
            native_counts, native_xml = summarize_test_xml(xml_data, redactor)
        except ElementTree.ParseError:
            native_error = 'invalid_xml'
    mismatch = native_counts is not None and (tests is None or any(
        native_counts[key] != tests[key] for key in ('total', 'failures', 'errors', 'skipped')))
    evidence = {'authoritativeSource': 'sequential-xctest-log',
                'junitProvenance': 'generated-from-sequential-xctest-log',
                'nativeXMLAvailable': xml_data is not None, 'nativeXMLCounts': native_counts,
                'nativeXMLParseError': native_error, 'nativeXMLMismatch': mismatch,
                'log': log_details,
                'countsVerified': log_details['consistent'] and not mismatch and native_error is None}
    return tests, generated_xml, native_xml, evidence


def test_results_pass(tests, evidence=None):
    return (tests is not None and tests['total'] > tests['skipped']
            and tests['failures'] == 0 and tests['errors'] == 0
            and (evidence is None or evidence['countsVerified']))


NETWORK_ERROR_PATTERNS = (
    re.compile(r'curl\s+error\s+28', re.IGNORECASE),
    re.compile(r'operation\s+timed\s+out', re.IGNORECASE),
    re.compile(r'could\s+not\s+resolve\s+host', re.IGNORECASE),
    re.compile(r'failed\s+to\s+connect', re.IGNORECASE),
    re.compile(r'unable\s+to\s+access', re.IGNORECASE),
    re.compile(r'failed\s+to\s+clone', re.IGNORECASE),
    re.compile(r'internet\s+connection\s+appears\s+to\s+be\s+offline', re.IGNORECASE),
    re.compile(r'network\s+is\s+unreachable', re.IGNORECASE),
    re.compile(r'ssl|tls|gnutls|securetransport', re.IGNORECASE),
    re.compile(r'time\s+limit\s+exceeded', re.IGNORECASE),
)


def classify_stage_failure(stage_name, exit_code, log_text):
    """Distinguish network/dependency-fetch failures from code or build failures."""
    if exit_code in (None, 0):
        return None
    fetch_stage = stage_name in {'tool-bootstrap', 'swift-resolve', 'xcode-resolve'}
    network_hint = any(pattern.search(log_text or '') for pattern in NETWORK_ERROR_PATTERNS)
    if fetch_stage and (exit_code in (74, 124) or network_hint):
        return 'network_or_dependency_fetch'
    if fetch_stage:
        return 'dependency_or_configuration_error'
    if exit_code == 124:
        return 'execution_timeout'
    return 'code_or_build_failure'


def summarize_failure_classification(stages):
    failed = {
        name: stage.get('failureCategory')
        for name, stage in stages.items()
        if stage.get('exitCode') not in (None, 0) and stage.get('failureCategory')
    }
    categories = sorted(set(failed.values()))
    if not categories:
        overall = 'none'
    elif len(categories) == 1:
        overall = categories[0]
    else:
        overall = 'mixed'
    return {
        'overall': overall,
        'failedStages': failed,
        'networkOrFetchBlocked': 'network_or_dependency_fetch' in categories,
        'codeOrBuildBlocked': 'code_or_build_failure' in categories,
    }


def run_stage(name, command, cwd, env, output, redactor, timeout):
    output.mkdir(parents=True, exist_ok=True)
    print(json.dumps({'stage': name, 'state': 'running'}), flush=True)
    started = time.monotonic()
    try:
        process = subprocess.Popen(command, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        raw, _ = process.communicate(timeout=timeout)
        code = process.returncode
    except FileNotFoundError as error:
        raw = f'executable not found: {error.filename or command[0]}\n'.encode('utf-8')
        code = 127
    except subprocess.TimeoutExpired as error:
        os.killpg(process.pid, signal.SIGKILL)
        raw, _ = process.communicate()
        code = 124
        raw += b'\ntime limit exceeded\n'
    except KeyboardInterrupt:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise
    text = redactor(raw.decode('utf-8', errors='replace'))
    (output / (name + '.log')).write_text(text, encoding='utf-8')
    diagnostics = [line.strip() for line in text.splitlines() if any(token in line for token in ['error:', 'warning:', 'BUILD FAILED', 'BUILD SUCCEEDED', 'Executed ', 'tests passed', 'tests failed', 'Test Suite'])]
    category = classify_stage_failure(name, code, text)
    result = {'exitCode': code, 'state': 'passed' if code == 0 else 'failed', 'durationSeconds': round(time.monotonic() - started, 3), 'diagnostics': list(dict.fromkeys(diagnostics))[-40:]}
    if category is not None:
        result['failureCategory'] = category
    print(json.dumps({'stage': name, **result}), flush=True)
    return result


def tool_value(command):
    result = subprocess.run(command, capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else 'unavailable'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent / 'evidence')
    parser.add_argument('--timeout', type=int, default=300)
    parser.add_argument('--cache-mode', choices=['existing', 'fresh'], default='existing')
    parser.add_argument('--git-http-version', choices=['HTTP/1.1', 'HTTP/2'])
    args = parser.parse_args()
    workspace = pathlib.Path(__file__).resolve().parents[2]
    repo, project, package, scheme = discover(workspace)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    initial_git = global_git_fingerprint()
    lock_paths = [package / 'Package.resolved', project / 'project.xcworkspace/xcshareddata/swiftpm/Package.resolved']
    locks_before = [digest(path.read_bytes()) if path.is_file() else None for path in lock_paths]
    with tempfile.TemporaryDirectory(prefix='task-07-') as temporary:
        cache = pathlib.Path(temporary)
        redactor = Redactor(workspace, repo, package, cache)
        env = process_environment(args.git_http_version)
        sources_before = source_snapshot(repo, redactor)
        common_swift = ['--package-path', str(package)]
        common_xcode = ['-project', str(project), '-scheme', scheme, '-scmProvider', 'system', '-disableAutomaticPackageResolution', '-onlyUsePackageVersionsFromResolvedFile']
        if args.cache_mode == 'fresh':
            common_swift += ['--scratch-path', str(cache / 'swift-build'), '--cache-path', str(cache / 'swift-cache'), '--config-path', str(cache / 'swift-config'), '--security-path', str(cache / 'swift-security')]
            common_xcode += ['-clonedSourcePackagesDirPath', str(cache / 'xcode-packages'), '-packageCachePath', str(cache / 'xcode-cache'), '-derivedDataPath', str(cache / 'derived')]
        else:
            common_swift += ['--skip-update']
            common_xcode += ['-skipPackageUpdates']
        stages = {}
        stages['tool-bootstrap'] = run_stage('tool-bootstrap', [sys.executable, str(pathlib.Path(__file__).with_name('bootstrap_tools.py'))], workspace, env, output, redactor, args.timeout)
        env['PATH'] = str(pathlib.Path(__file__).resolve().parent / '.tools') + os.pathsep + env.get('PATH', '')
        stages['swift-resolve'] = run_stage('swift-resolve', ['swift', 'package', *common_swift, 'resolve', '--force-resolved-versions'], repo, env, output, redactor, args.timeout)
        test_xml = cache / 'swift-tests.xml'
        stages['swift-test'] = run_stage('swift-test', ['swift', 'test', *common_swift, '--force-resolved-versions', '--xunit-output', str(test_xml)], repo, env, output, redactor, args.timeout) if stages['swift-resolve']['exitCode'] == 0 else {'state': 'skipped', 'exitCode': None, 'reason': 'dependency resolution failed'}
        stages['xcode-resolve'] = run_stage('xcode-resolve', ['xcodebuild', *common_xcode, '-resolvePackageDependencies'], repo, env, output, redactor, args.timeout)
        stages['xcode-build'] = run_stage('xcode-build', ['xcodebuild', *common_xcode, '-configuration', 'Debug', '-destination', 'platform=macOS,arch=arm64', 'CODE_SIGNING_ALLOWED=NO', 'build'], repo, env, output, redactor, args.timeout) if stages['xcode-resolve']['exitCode'] == 0 else {'state': 'skipped', 'exitCode': None, 'reason': 'dependency resolution failed'}
        locks_after = [digest(path.read_bytes()) if path.is_file() else None for path in lock_paths]
        sources_after = source_snapshot(repo, redactor)
        log_path = output / 'swift-test.log'
        log_text = log_path.read_text() if stages['swift-test']['exitCode'] is not None and log_path.is_file() else ''
        tests, safe_xml, native_xml, test_evidence = reconcile_test_results(
            log_text, test_xml.read_bytes() if test_xml.is_file() else None, redactor)
        if safe_xml is not None:
            (output / 'swift-tests.xml').write_text(safe_xml, encoding='utf-8')
        if native_xml is not None:
            (output / 'swift-tests.native.xml').write_text(native_xml, encoding='utf-8')
        report = {
            'schema': 'task-07-build-v1',
            'capturedAt': datetime.now(ZoneInfo('Asia/Shanghai')).isoformat(timespec='seconds'),
            'host': {key: redactor(tool_value(command)) for key, command in {
                'architecture': ['uname', '-m'], 'chip': ['sysctl', '-n', 'machdep.cpu.brand_string'],
                'memoryBytes': ['sysctl', '-n', 'hw.memsize'], 'macOS': ['sw_vers', '-productVersion'],
                'macOSBuild': ['sw_vers', '-buildVersion'], 'xcode': ['xcodebuild', '-version'],
                'swift': ['swift', '--version'], 'sdk': ['xcrun', '--sdk', 'macosx', '--show-sdk-version']}.items()},
            'gateProfile': 'locked-cache-fast-gate' if args.cache_mode == 'existing' else 'process-scoped-cold-cache-probe',
            'dependencyMode': args.cache_mode + ' caches, pinned resolved versions, process-scoped HTTPS rewrite',
            'gitHTTPVersionOverride': next((env.get('GIT_CONFIG_VALUE_' + str(index), 'inherited')
                                          for index in range(int(env.get('GIT_CONFIG_COUNT', '0')))
                                          if env.get('GIT_CONFIG_KEY_' + str(index)) == 'http.version'
                                          and env.get('GIT_CONFIG_VALUE_' + str(index)) in {'HTTP/1.1', 'HTTP/2'}),
                                         'inherited'),
            'signing': 'disabled for local compilation only',
            'stages': stages,
            'failureClassification': summarize_failure_classification(stages),
            'swiftTests': tests,
            'swiftTestEvidence': test_evidence,
            'sourceSHA256': sources_after,
            'sourcesStableDuringRun': sources_before == sources_after,
            'globalGitUnchanged': initial_git == global_git_fingerprint(),
            'lockfilesUnchanged': locks_before == locks_after,
            'lockfileSHA256': dict(zip(['swift', 'xcode'], locks_after)),
        }
        report['passed'] = all(stage['exitCode'] == 0 for stage in stages.values()) and report['globalGitUnchanged'] and report['lockfilesUnchanged'] and report['sourcesStableDuringRun'] and test_results_pass(tests, test_evidence)
        (output / 'build.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        print(json.dumps({'passed': report['passed'], 'globalGitUnchanged': report['globalGitUnchanged'], 'lockfilesUnchanged': report['lockfilesUnchanged']}), flush=True)
        return 0 if report['passed'] else 1


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, OSError, ElementTree.ParseError):
        print(json.dumps({'error': 'verification setup failed'}))
        raise SystemExit(2)
    except KeyboardInterrupt:
        print(json.dumps({'error': 'verification interrupted'}))
        raise SystemExit(130)
