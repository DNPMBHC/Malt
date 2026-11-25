#!/usr/bin/env python3
"""Local controller regressions; all Guest operations are mocked."""
import base64
import contextlib
import importlib.util
import io
import itertools
import json
from pathlib import Path
import re
import stat
import tempfile
import unittest
from unittest.mock import patch

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('b2_guest_controller',HERE/'b2-guest-control.py')
controller=importlib.util.module_from_spec(spec)
spec.loader.exec_module(controller)

MARKER='a'*64
OTHER_MARKER='b'*64

def completed_response(output='neutral', marker=MARKER):
    text=output+'\x1eB2_RESPONSE_MARKER:'+marker+'\x1f'
    return '1\n0\n0\n'+base64.b64encode(text.encode()).decode()

class ControllerChecks(unittest.TestCase):
    def test_multiple_escaped_guest_paths(self):
        for count in (1,2,4,8):
            path='X:'+chr(92)*count+'private-folder'+chr(92)*count+'report.txt'
            cleaned=controller.redact_text('diagnostic '+path)
            self.assertNotIn('private-folder',cleaned)
            self.assertIn('[guest-path]',cleaned)

    def test_nested_json_guest_paths(self):
        value={'log':'X:'+chr(92)+'private-folder'+chr(92)+'report.txt'}
        for count in range(1,5):
            value=json.dumps(value)
            self.assertNotIn('private-folder',controller.redact(value))

    def test_ipv4_requires_valid_octets(self):
        self.assertEqual(controller.redact_text('192.'+'0.2.1'),'[network-address]')
        for version in ('2.17.4.510','10.0.26100.1','300.2.3.4'):
            self.assertEqual(controller.redact_text(version),version)

    def test_public_references_survive(self):
        value='S-A06 https://example.invalid/download.html version 2.17.4.510'
        self.assertEqual(controller.redact_text(value),value)

    def test_escaped_private_unix_path(self):
        value=chr(92)+'/'+'Users'+chr(92)+'/'+'sample-user'+chr(92)+'/'+'report.txt'
        self.assertNotIn('sample-user',controller.redact_text(value))

    def test_process_keys_omitted_but_comparison_kept(self):
        value={'boundChildPID':123,'private_process_reference':'fixture','child_pid_matched':True,'guest_os_build':'10.0.26100.1'}
        cleaned=controller.sanitize(value)
        self.assertNotIn('boundChildPID',cleaned)
        self.assertNotIn('private_process_reference',cleaned)
        self.assertIs(cleaned['child_pid_matched'],True)

    def test_completed_guest_execution_removes_private_handle(self):
        with tempfile.TemporaryDirectory(prefix='b2-neutral-controller-') as temporary:
            directory=Path(temporary)
            def mocked(name,args,**kwargs):
                if name=='executeCapturingScript': return '123'
                if name=='capturedResultScript': return completed_response('{"result":"neutral"}')
                raise AssertionError('Unexpected mocked transport operation.')
            with patch.object(controller,'_recovery_directory',return_value=directory),patch.object(controller,'apple',side_effect=mocked),patch.object(controller,'VM_ID','vm-fixture'):
                result=controller.guest('fixture.exe',[],timeout=1,response_marker=MARKER)
            self.assertEqual(result['exit_code'],0)
            self.assertEqual(result['stdout'],'{"result":"neutral"}')
            self.assertTrue(result['response_marker_verified'])
            self.assertFalse(result['recovery_pending'])
            self.assertEqual(list(directory.iterdir()),[])

    def test_timeout_keeps_primary_without_terminating_running_pid(self):
        with tempfile.TemporaryDirectory(prefix='b2-neutral-controller-') as temporary:
            directory=Path(temporary)
            def mocked(name,args,**kwargs):
                if name=='executeCapturingScript': return '123'
                if name=='capturedResultScript': return '0'
                raise AssertionError('Unexpected mocked transport operation.')
            with patch.object(controller,'_recovery_directory',return_value=directory),patch.object(controller,'apple',side_effect=mocked),patch.object(controller,'VM_ID','vm-fixture'),patch.object(controller.time,'sleep'),patch.object(controller.time,'monotonic',side_effect=[0,1,2,20]):
                result=controller.guest('fixture.exe',[],timeout=0,response_marker=MARKER)
            self.assertEqual(result['exit_code'],124)
            self.assertTrue(result['recovery_pending'])
            files=list(directory.iterdir())
            self.assertEqual(len(files),1)
            for path in files:
                self.assertEqual(stat.S_IMODE(path.stat().st_mode),0o600)
                self.assertTrue(controller._read_private_execution(path)['process_reference'])
                self.assertEqual(controller._read_private_execution(path)['private_response_marker'],MARKER)

    def test_recovery_only_polls_and_removes_confirmed_exit(self):
        with tempfile.TemporaryDirectory(prefix='b2-neutral-controller-') as temporary:
            directory=Path(temporary)
            with patch.object(controller,'_recovery_directory',return_value=directory):
                handle=controller._save_private_execution('123','vm-fixture','captured',MARKER)
                def mocked(name,args,**kwargs):
                    self.assertEqual(name,'capturedResultScript')
                    return completed_response()
                with patch.object(controller,'apple',side_effect=mocked):
                    result=controller.recover_private_executions(timeout=1)
            self.assertFalse(result['recovery_pending'])
            self.assertFalse(handle.exists())

    def test_powershell_requests_have_distinct_private_markers(self):
        with tempfile.TemporaryDirectory(prefix='b2-neutral-controller-') as temporary:
            directory=Path(temporary)
            markers=[]
            def mocked(name,args,**kwargs):
                if name=='executeCapturingScript':
                    source=base64.b64decode(args[-1]).decode('utf-16le')
                    found=re.findall(r'B2_RESPONSE_MARKER:([0-9a-f]{64})',source)
                    self.assertEqual(len(found),1)
                    self.assertIn('} finally {',source)
                    self.assertIn('$b2RequestSucceeded = $?',source)
                    markers.extend(found)
                    return 'transport-slot'
                if name=='capturedResultScript':
                    saved=list(directory.glob('*.json'))
                    self.assertEqual(len(saved),1)
                    self.assertEqual(controller._read_private_execution(saved[0])['private_response_marker'],markers[-1])
                    return completed_response('neutral',markers[-1])
                raise AssertionError('Unexpected mocked transport operation.')
            with patch.object(controller,'_recovery_directory',return_value=directory),patch.object(controller,'apple',side_effect=mocked),patch.object(controller,'VM_ID','vm-fixture'),patch.object(controller,'ROOT',Path('my-project')),patch.object(controller,'SCRIPTS',{'fixture':'unused'}),patch.object(controller,'record_operation'):
                first=controller.powershell("Write-Output 'neutral'",timeout=1)
                second=controller.powershell("Write-Output 'neutral'",timeout=1)
            self.assertNotEqual(markers[0],markers[1])
            for result in (first,second):
                self.assertEqual(result['exit_code'],0)
                self.assertEqual(result['stdout'],'neutral')
                self.assertNotIn('B2_RESPONSE_MARKER',json.dumps(result))

    def assert_unbound_completion_retained(self,response):
        with tempfile.TemporaryDirectory(prefix='b2-neutral-controller-') as temporary:
            directory=Path(temporary)
            calls=[]
            def mocked(name,args,**kwargs):
                calls.append(name)
                if name=='executeCapturingScript':return 'transport-slot'
                if name=='capturedResultScript':return response
                raise AssertionError('Unexpected mocked transport mutation.')
            with patch.object(controller,'_recovery_directory',return_value=directory),patch.object(controller,'apple',side_effect=mocked),patch.object(controller,'VM_ID','vm-fixture'):
                result=controller.guest('fixture.exe',[],timeout=1,response_marker=MARKER)
            self.assertEqual(result['status'],'execution_error')
            self.assertNotEqual(result['exit_code'],0)
            self.assertEqual(result['stdout'],'')
            self.assertTrue(result['recovery_pending'])
            self.assertEqual(len(list(directory.glob('*.json'))),1)
            self.assertNotIn('executeScript',calls)
            self.assertNotIn('resultScript',calls)

    def test_reused_native_pid_old_result_rejected(self):
        self.assert_unbound_completion_retained(completed_response('old-neutral-result',OTHER_MARKER))

    def test_missing_completion_marker_rejected(self):
        self.assert_unbound_completion_retained('1\n0\n0\n'+base64.b64encode(b'neutral').decode())

    def test_duplicate_completion_marker_rejected(self):
        frame='\x1eB2_RESPONSE_MARKER:'+MARKER+'\x1f'
        self.assert_unbound_completion_retained(completed_response(frame))

    def test_conflicting_completion_markers_rejected(self):
        frame='\x1eB2_RESPONSE_MARKER:'+OTHER_MARKER+'\x1f'
        self.assert_unbound_completion_retained(completed_response(frame))

    def test_invalid_completion_base64_rejected(self):
        self.assert_unbound_completion_retained('1\n0\n0\n!invalid!')

    def test_transport_exception_never_terminates_reused_running_pid(self):
        with tempfile.TemporaryDirectory(prefix='b2-neutral-controller-') as temporary:
            directory=Path(temporary)
            captured_calls=[]
            def mocked(name,args,**kwargs):
                if name=='executeCapturingScript':return 'transport-slot'
                if name=='capturedResultScript':
                    captured_calls.append(name)
                    if len(captured_calls)==1:raise RuntimeError('neutral failure')
                    return '0'
                raise AssertionError('Unexpected mocked transport mutation.')
            with patch.object(controller,'_recovery_directory',return_value=directory),patch.object(controller,'apple',side_effect=mocked),patch.object(controller,'VM_ID','vm-fixture'):
                result=controller.guest('fixture.exe',[],timeout=1,response_marker=MARKER)
            self.assertEqual(result['status'],'execution_error')
            self.assertTrue(result['recovery_pending'])
            self.assertEqual(len(list(directory.glob('*.json'))),1)

    def test_recovery_rejects_old_result_for_reused_native_pid(self):
        with tempfile.TemporaryDirectory(prefix='b2-neutral-controller-') as temporary:
            directory=Path(temporary)
            with patch.object(controller,'_recovery_directory',return_value=directory):
                handle=controller._save_private_execution('transport-slot','vm-fixture','captured',MARKER)
                def mocked(name,args,**kwargs):
                    self.assertEqual(name,'capturedResultScript')
                    self.assertEqual(kwargs['vm_reference'],'vm-fixture')
                    return completed_response('old-neutral-result',OTHER_MARKER)
                ticks=itertools.count(0,0.25)
                with patch.object(controller,'apple',side_effect=mocked),patch.object(controller.time,'sleep'),patch.object(controller.time,'monotonic',side_effect=lambda:next(ticks)):
                    result=controller.recover_private_executions(timeout=1)
            self.assertEqual(result['completed_execution_count'],0)
            self.assertNotEqual(result['exit_code'],0)
            self.assertTrue(result['recovery_pending'])
            self.assertTrue(handle.exists())

    def test_legacy_unmarked_and_cleanup_handles_remain_pending(self):
        with tempfile.TemporaryDirectory(prefix='b2-neutral-controller-') as temporary:
            directory=Path(temporary)
            with patch.object(controller,'_recovery_directory',return_value=directory):
                unmarked=controller._save_private_execution('transport-slot','vm-fixture','captured')
                cleanup=controller._save_private_execution('other-transport-slot','vm-fixture','cleanup')
                value=json.loads(unmarked.read_text())
                value['schema_version']='1.0.0'
                value.pop('private_response_marker')
                unmarked.write_text(json.dumps(value))
                ticks=itertools.count(0,0.1)
                with patch.object(controller,'apple') as mocked,patch.object(controller.time,'sleep'),patch.object(controller.time,'monotonic',side_effect=lambda:next(ticks)):
                    result=controller.recover_private_executions(timeout=1)
            mocked.assert_not_called()
            self.assertEqual(result['pending_execution_count'],2)
            self.assertEqual(result['completed_execution_count'],0)
            self.assertTrue(unmarked.exists() and cleanup.exists())

    def test_private_response_marker_not_exported(self):
        value={'private_response_marker':MARKER,'response_marker_verified':True}
        self.assertEqual(controller.sanitize(value),{'response_marker_verified':True})

    def test_bound_nonzero_exit_is_preserved(self):
        fields=completed_response().split('\n',4)
        fields[1]='7'
        result=controller._bound_completed_response(fields,MARKER)
        self.assertEqual(result['exit_code'],7)
        self.assertEqual(result['stdout'],'neutral')

    def test_raw_poll_cannot_bypass_response_binding(self):
        output=io.StringIO()
        with patch.object(controller,'initialize'),patch.object(controller.sys,'argv',['neutral-controller','poll','transport-slot']),patch.object(controller,'apple') as mocked,contextlib.redirect_stdout(output):
            with self.assertRaises(SystemExit) as stopped:
                controller.main()
        self.assertEqual(stopped.exception.code,1)
        self.assertEqual(json.loads(output.getvalue())['status'],'unbound_poll_rejected')
        mocked.assert_not_called()

    def test_execution_requires_private_marker_before_launch(self):
        with patch.object(controller,'apple') as mocked:
            result=controller.guest('fixture.exe',[],timeout=1)
        self.assertEqual(result['status'],'execution_identity_unavailable')
        self.assertNotEqual(result['exit_code'],0)
        self.assertFalse(result['recovery_pending'])
        mocked.assert_not_called()

if __name__=='__main__':
    suite=unittest.defaultTestLoader.loadTestsFromTestCase(ControllerChecks)
    result=unittest.TextTestRunner(stream=io.StringIO()).run(suite)
    failed=[test.id().rsplit('.',1)[-1] for test,_ in result.failures+result.errors]
    print(json.dumps({'result':'passed' if result.wasSuccessful() else 'failed','test_cases':result.testsRun,'failed_cases':failed,'guest_calls':'all_mocked'}))
    raise SystemExit(0 if result.wasSuccessful() else 1)
