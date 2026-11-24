#!/usr/bin/env python3
"""Fetch one checksum-pinned build tool into this task's local cache."""

import hashlib
import io
import json
import pathlib
import subprocess
import urllib.request
import zipfile

VERSION = '0.65.1'
ARCHIVE_SHA256 = 'c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0'
ARCHIVE_URL = 'https://github.com/realm/SwiftLint/releases/download/' + VERSION + '/portable_swiftlint.zip'


def prepare():
    destination = pathlib.Path(__file__).resolve().parent / '.tools'
    executable = destination / 'swiftlint'
    receipt = destination / 'receipt.json'
    if executable.is_file() and receipt.is_file():
        data = json.loads(receipt.read_text())
        if (data.get('archiveSHA256') == ARCHIVE_SHA256
                and hashlib.sha256(executable.read_bytes()).hexdigest() == data.get('binarySHA256')):
            return executable
    request = urllib.request.Request(ARCHIVE_URL, headers={'User-Agent': 'task-07-build'})
    with urllib.request.urlopen(request, timeout=30) as response:
        archive = response.read(32 * 1024 * 1024)
        if response.read(1):
            raise ValueError('tool archive exceeds size limit')
    if hashlib.sha256(archive).hexdigest() != ARCHIVE_SHA256:
        raise ValueError('tool archive checksum mismatch')
    with zipfile.ZipFile(io.BytesIO(archive)) as package:
        candidates = [member for member in package.infolist() if pathlib.PurePosixPath(member.filename).name == 'swiftlint']
        if len(candidates) != 1 or candidates[0].file_size > 128 * 1024 * 1024:
            raise ValueError('tool archive layout is invalid')
        binary = package.read(candidates[0])
    destination.mkdir(exist_ok=True)
    executable.write_bytes(binary)
    executable.chmod(0o755)
    result = subprocess.run([str(executable), 'version'], capture_output=True, text=True, timeout=20)
    if result.returncode != 0 or result.stdout.strip() != VERSION:
        executable.unlink(missing_ok=True)
        raise ValueError('tool version validation failed')
    receipt.write_text(json.dumps({'version': VERSION, 'archiveSHA256': ARCHIVE_SHA256,
                                   'binarySHA256': hashlib.sha256(binary).hexdigest()}, indent=2) + '\n')
    return executable


if __name__ == '__main__':
    try:
        prepare()
        print(json.dumps({'tool': 'SwiftLint', 'version': VERSION, 'verified': True, 'archiveSHA256': ARCHIVE_SHA256}))
    except Exception as error:
        print(json.dumps({'tool': 'SwiftLint', 'verified': False, 'errorType': type(error).__name__}))
        raise SystemExit(1)
