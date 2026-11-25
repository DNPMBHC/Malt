"""Privacy regression for paths appearing in commercial logs. @DNPMBHC."""
import unittest
import json
from unittest.mock import patch
from types import SimpleNamespace
from pathlib import Path
import bench_real3d_support as support


class EvidencePrivacyTests(unittest.TestCase):
    def test_windows_user_directory_matching_is_case_insensitive(self):
        for value in (r'C:\users\demo-user\private\client.dll',
                      r'C:\USERS\DEMO-USER\PRIVATE\CLIENT.DLL'):
            self.assertEqual(support.redact(value), '<local-path>')

    def test_standalone_local_account_is_omitted_without_erasing_author(self):
        value = 'local account=' + Path.home().name + '; owner=@DNPMBHC'
        self.assertEqual(support.redact(value), 'local account=user-x; owner=@DNPMBHC')


class RuntimeIsolationTests(unittest.TestCase):
    def observe(self, state='unregistered', commands=None, inventory=None):
        source = Path('/example/vm-a.utm')
        clone = Path('/example/p5-a-runtime/test-vm-p5a.utm')
        if inventory is None:
            inventory = '11 1 /apps/QEMULauncher\n12 11 /apps/QEMURenderServer\n'
        if commands is None:
            commands = f'11 launcher {clone}/Data/disk.img --uuid clone-uuid\n12 renderer\n'
        responses = [SimpleNamespace(returncode=0, stdout=inventory),
                     SimpleNamespace(returncode=0, stdout=commands)]
        with patch.object(support, 'source_vm', return_value=source), \
             patch.object(support, 'clone_path', return_value=clone), \
             patch.object(support, 'runtime_dir', return_value=clone.parent), \
             patch.object(support, 'status', return_value=state), \
             patch.object(Path, 'read_text', return_value='{"phase":"p5-a"}'), \
             patch.object(support, 'vm_id', side_effect=lambda p: 'source-uuid' if p == source else 'clone-uuid'), \
             patch.object(support, 'run', side_effect=responses):
            return support.runtime_isolation()

    def test_unregistered_source_requires_live_worker_binding(self):
        value = self.observe()
        self.assertTrue(value['source_runtime_absent_verified'])
        self.assertEqual(value['source_registration_state'], 'unregistered')
        self.assertEqual(value['root_pids'], [11])

    def test_running_source_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'may be active'):
            self.observe(state='started')

    def test_source_disk_reference_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'source runtime'):
            self.observe(commands='11 launcher /example/vm-a.utm/Data/disk.img --uuid source-uuid\n')

    def test_unknown_hypervisor_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'Unowned or unbound'):
            self.observe(commands='11 launcher /example/other.utm --uuid unknown\n')

    def test_orphan_render_worker_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'Unowned render'):
            self.observe(inventory='11 1 /apps/QEMULauncher\n12 1 /apps/QEMURenderServer\n')


class SourceSelectionTests(unittest.TestCase):
    def select(self, source_digest='frozen-config', clone_digest='new-config'):
        source = Path('/example/vm-a.utm')
        successor = Path('/example/p5-c-runtime/test-vm-p5c.utm')
        baseline = {'files': [{'artifact_alias': 'vm-file-0.plist',
                               'sha256': 'frozen-config'}]}
        with patch.object(support, 'vm_packages', return_value=[source, successor]), \
             patch.object(Path, 'is_file', return_value=True), \
             patch.object(Path, 'read_text', return_value=json.dumps(baseline)), \
             patch.object(support, 'sha256', side_effect=lambda p:
                          source_digest if p.parent == source else clone_digest):
            return support.source_vm()

    def test_successor_clone_does_not_replace_frozen_source(self):
        self.assertEqual(self.select(), Path('/example/vm-a.utm'))

    def test_missing_frozen_source_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'ambiguous selection'):
            self.select(source_digest='changed-config')

    def test_duplicate_frozen_config_remains_ambiguous(self):
        with self.assertRaisesRegex(RuntimeError, 'ambiguous selection'):
            self.select(clone_digest='frozen-config')


if __name__ == '__main__':
    unittest.main()
