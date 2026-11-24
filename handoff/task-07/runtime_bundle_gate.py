#!/usr/bin/env python3
"""Locked Vulkan bundle prerequisite gate. Maintainer: @DNPMBHC."""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import platform
import re
import shutil
import subprocess
import tempfile


def sha256_file(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def probe_driver(loader, icd):
    """Query actual x86 Vulkan features, rather than trusting file existence."""
    headers = list((pathlib.Path.home() / 'VulkanSDK').glob('**/include/vulkan/vulkan.h'))
    if not headers:
        raise ValueError('feature_probe_sdk_unavailable')
    source = pathlib.Path(__file__).with_name('vulkan_feature_probe.c')
    with tempfile.TemporaryDirectory(prefix='my-project-vulkan-probe-') as directory:
        binary = pathlib.Path(directory) / 'feature-probe'
        build = subprocess.run(
            ['xcrun', 'clang', '-arch', 'x86_64', '-I', str(headers[0].parents[1]),
             str(source), '-o', str(binary)], capture_output=True, timeout=60
        )
        if build.returncode:
            raise ValueError('feature_probe_compile_failed')
        env = os.environ.copy()
        env.update(VK_DRIVER_FILES=str(icd), VK_ICD_FILENAMES=str(icd))
        env.pop('VK_ADD_DRIVER_FILES', None)
        env.pop('VK_LOADER_DRIVERS_SELECT', None)
        env.pop('VK_LOADER_DRIVERS_DISABLE', None)
        run = subprocess.run([str(binary), str(loader)], env=env, capture_output=True,
                             text=True, timeout=60)
        if run.returncode:
            raise ValueError('required_vulkan_features_unavailable')
        features = json.loads(run.stdout)
        if not features.get('geometryShader') or not features.get('fillModeNonSolid'):
            raise ValueError('required_vulkan_features_unavailable')
        return features


def embed_locked_vulkan(app, source, enabled=True):
    manifest = app / 'Contents/Resources/runtime-manifest.json'
    doc = json.loads(manifest.read_text())
    component = next((c for c in doc['components'] if c.get('requiredVulkanFeatures')), None)
    result = {'bundled': False, 'fallbackVulkanICD': 'moltenVK', 'fallbackReason': None}
    if component is None:
        result['fallbackReason'] = 'runtime_lock_missing'
        return result
    names = {a['name']: a for a in component['artifacts']}
    driver_name = next(n for n in names if n.startswith('libvulkan_'))
    icd_name = next(n for n in names if n.endswith('_icd.json'))
    targets = [app / 'Contents/Frameworks/libvulkan.1.dylib',
               app / 'Contents/Frameworks' / driver_name,
               app / 'Contents/Resources/vulkan/icd.d' / icd_name]
    try:
        if not enabled:
            raise ValueError('disabled_by_packager')
        if platform.machine() != 'arm64' or int(platform.mac_ver()[0].split('.')[0]) < 26:
            raise ValueError('unsupported_host')
        for target in targets[:2]:
            candidate = source / 'lib' / target.name
            if not candidate.is_file():
                raise ValueError('runtime_binary_missing')
            if sha256_file(candidate) != names[target.name]['sha256']:
                raise ValueError('runtime_checksum_mismatch')
            arches = subprocess.run(['lipo', '-archs', str(candidate)],
                                    capture_output=True, text=True, check=True).stdout.split()
            required = {'x86_64', 'arm64'} if target.name == 'libvulkan.1.dylib' else {'x86_64'}
            if not required.issubset(arches):
                raise ValueError('runtime_architecture_mismatch')
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(candidate, target)
        targets[2].parent.mkdir(parents=True, exist_ok=True)
        icd = {'ICD': {'api_version': '1.4.368', 'library_path': '../../../Frameworks/' + driver_name},
               'file_format_version': '1.0.1'}
        targets[2].write_text(json.dumps(icd, indent=4) + '\n')
        if sha256_file(targets[2]) != names[icd_name]['sha256']:
            raise ValueError('relative_icd_checksum_mismatch')
        features = probe_driver(targets[0], targets[2])
        result = {
            'bundled': True, 'x86_64SliceVerified': True, 'universalLoaderVerified': True,
            'relativeICDPathVerified': True, 'features': features,
            'vulkanLoaderSHA256': sha256_file(targets[0]),
            'driverSHA256': sha256_file(targets[1]), 'icdManifestSHA256': sha256_file(targets[2])
        }
    except (ValueError, OSError, subprocess.SubprocessError):
        import sys
        error = sys.exc_info()[1]
        reason = str(error) if isinstance(error, ValueError) else 'runtime_validation_failed'
        result['fallbackReason'] = reason
        for target in targets:
            target.unlink(missing_ok=True)
    return result


def verify_hardened(app):
    """Check code signatures and real CS_RUNTIME flags for both executables."""
    info = __import__('plistlib').loads((app / 'Contents/Info.plist').read_bytes())
    cli = app / 'Contents/Resources' / (info['CFBundleExecutable'] + 'Cmd')
    results = {}
    for label, path in [('app', app), ('cli', cli)]:
        verify = subprocess.run(['codesign', '--verify', '--strict', str(path)], capture_output=True)
        details = subprocess.run(['codesign', '-dvvv', str(path)], capture_output=True, text=True)
        flags = re.search(r'flags=0x([0-9a-f]+)', details.stderr)
        valid = verify.returncode == 0 and details.returncode == 0 and bool(flags) and bool(
            int(flags.group(1), 16) & 0x10000)
        results[label] = {'signatureVerified': verify.returncode == 0, 'runtimeFlagVerified': valid}
    results['passed'] = all(item['runtimeFlagVerified'] for item in list(results.values()))
    return results

