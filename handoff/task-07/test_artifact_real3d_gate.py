# Maintainer: @DNPMBHC
import json
import pathlib
import tempfile
import unittest

from artifact_real3d_gate import summarize_real3d


class Real3DArtifactTests(unittest.TestCase):
    def fixture(self, root):
        path = root / 'probe.csv'
        path.write_text('frame_index,cpu_frame_ms,device_memory_bytes\n0,1,33554432\n1,1,33554432\n2,1,33554432\n')
        metadata = {'width': 1280, 'height': 720, 'draws_per_frame': 2048, 'cb_updates_per_frame': 256,
                    'async_swapchain': True, 'adapter_is_software': False}
        completion = {'measured_frames': 3, 'total_draw_calls': 6144, 'measurement_wall_ms': 6,
                      'throughput_including_gpu_drain_fps': 500, 'gpu_drain_ms': 2}
        return path, metadata, completion

    def summarize(self, path, metadata, completion):
        stdout = 'real3d_metadata_json=' + json.dumps(metadata) + '\nreal3d_completion_json=' + json.dumps(completion)
        return summarize_real3d(path, stdout, 3, 2048)

    def test_throughput_uses_completion_wall_time_including_gpu_drain(self):
        with tempfile.TemporaryDirectory() as tmp:
            path, metadata, completion = self.fixture(pathlib.Path(tmp))
            result = self.summarize(path, metadata, completion)
            self.assertEqual(result['derivedFPS'], 500)
            self.assertEqual(result['frameIntervalP95Ms'], 1)
            self.assertEqual(result['deviceMemoryMiBMean'], 32)
            self.assertEqual(result['errors'], [])

    def test_incomplete_or_wrong_workload_cannot_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            path, metadata, completion = self.fixture(pathlib.Path(tmp))
            metadata['draws_per_frame'] = 16
            completion['measured_frames'] = 2
            result = self.summarize(path, metadata, completion)
            self.assertIn('incomplete_real3d_frames', result['errors'])
            self.assertIn('real3d_workload_mismatch', result['errors'])

    def test_queued_fps_or_duplicate_frame_indices_cannot_claim_completion(self):
        with tempfile.TemporaryDirectory() as tmp:
            path, metadata, completion = self.fixture(pathlib.Path(tmp))
            path.write_text(path.read_text().replace('2,1,33554432', '1,1,33554432'))
            completion['throughput_including_gpu_drain_fps'] = 1000
            result = self.summarize(path, metadata, completion)
            self.assertIn('real3d_completion_throughput_mismatch', result['errors'])
            self.assertIn('real3d_frame_sequence_mismatch', result['errors'])
