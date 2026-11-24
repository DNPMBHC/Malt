# Maintainer: @DNPMBHC
import hashlib
import json
import pathlib
import subprocess
import tempfile
import types
import unittest
from unittest import mock

from runtime_bundle_gate import embed_locked_vulkan


class LockedVulkanBundleTests(unittest.TestCase):
    def fixture(self, root):
        app, source = root / 'demo-app.app', root / 'runtime'
        resource = app / 'Contents/Resources'
        resource.mkdir(parents=True)
        (source / 'lib').mkdir(parents=True)
        driver = 'libvulkan_module-k.dylib'
        icd = 'module-k_icd.json'
        payload = json.dumps({'ICD': {'api_version': '1.4.368',
                                     'library_path': '../../../Frameworks/' + driver},
                              'file_format_version': '1.0.1'}, indent=4) + '\n'
        artifacts = []
        for name, data in [('libvulkan.1.dylib', b'loader'), (driver, b'driver'),
                           (icd, payload.encode())]:
            artifacts.append({'name': name, 'sha256': hashlib.sha256(data).hexdigest()})
            if name.endswith('.dylib'):
                (source / 'lib' / name).write_bytes(data)
        (resource / 'runtime-manifest.json').write_text(json.dumps({'components': [
            {'requiredVulkanFeatures': ['geometryShader', 'fillModeNonSolid'], 'artifacts': artifacts}
        ]}))
        return app, source

    @mock.patch('runtime_bundle_gate.platform.machine', return_value='arm64')
    @mock.patch('runtime_bundle_gate.platform.mac_ver', return_value=('27.0', (), ''))
    @mock.patch('runtime_bundle_gate.subprocess.run', return_value=types.SimpleNamespace(stdout='x86_64 arm64'))
    @mock.patch('runtime_bundle_gate.probe_driver', return_value={'geometryShader': True, 'fillModeNonSolid': True})
    def test_valid_locked_payload_embeds_relative_icd(self, *mocks):
        with tempfile.TemporaryDirectory() as tmp:
            app, source = self.fixture(pathlib.Path(tmp))
            result = embed_locked_vulkan(app, source)
            self.assertTrue(result['bundled'])
            self.assertTrue(result['relativeICDPathVerified'])

    @mock.patch('runtime_bundle_gate.platform.machine', return_value='arm64')
    @mock.patch('runtime_bundle_gate.platform.mac_ver', return_value=('27.0', (), ''))
    def test_checksum_failure_removes_partial_payload(self, *mocks):
        with tempfile.TemporaryDirectory() as tmp:
            app, source = self.fixture(pathlib.Path(tmp))
            (source / 'lib/libvulkan.1.dylib').write_bytes(b'tampered')
            result = embed_locked_vulkan(app, source)
            self.assertFalse(result['bundled'])
            self.assertEqual(result['fallbackReason'], 'runtime_checksum_mismatch')
            self.assertFalse((app / 'Contents/Frameworks/libvulkan.1.dylib').exists())

    @mock.patch('runtime_bundle_gate.platform.machine', return_value='arm64')
    @mock.patch('runtime_bundle_gate.platform.mac_ver', return_value=('27.0', (), ''))
    @mock.patch('runtime_bundle_gate.subprocess.run', return_value=types.SimpleNamespace(stdout='arm64'))
    def test_arm_only_loader_is_explicit_fallback(self, *mocks):
        with tempfile.TemporaryDirectory() as tmp:
            app, source = self.fixture(pathlib.Path(tmp))
            result = embed_locked_vulkan(app, source)
            self.assertEqual(result['fallbackReason'], 'runtime_architecture_mismatch')
            self.assertFalse(result['bundled'])

    @mock.patch('runtime_bundle_gate.platform.machine', return_value='arm64')
    @mock.patch('runtime_bundle_gate.platform.mac_ver', return_value=('27.0', (), ''))
    @mock.patch('runtime_bundle_gate.subprocess.run', return_value=types.SimpleNamespace(stdout='x86_64 arm64'))
    @mock.patch('runtime_bundle_gate.probe_driver', side_effect=ValueError('required_vulkan_features_unavailable'))
    def test_feature_failure_removes_all_embedded_files(self, *mocks):
        with tempfile.TemporaryDirectory() as tmp:
            app, source = self.fixture(pathlib.Path(tmp))
            result = embed_locked_vulkan(app, source)
            self.assertEqual(result['fallbackReason'], 'required_vulkan_features_unavailable')
            self.assertFalse(list(app.glob('Contents/Frameworks/*')))


if __name__ == '__main__':
    unittest.main()

