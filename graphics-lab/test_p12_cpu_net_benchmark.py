#!/usr/bin/env python3
"""Unit tests for Phase 12A CPU/Network/I/O benchmark analytics, redaction, and echo server.

Owner: @DNPMBHC
"""
from __future__ import annotations

import os
import socket
import struct
import unittest

import p12_cpu_net_benchmark as p12


class P12CpuNetBenchmarkTests(unittest.TestCase):
    def test_analyze_tick_packet_trace_computes_rtt_loss_burst_and_jitter(self) -> None:
        # 10 packets: seq 2,3,4 lost (1 burst >=3), seq 7 lost (single loss)
        rtts = {
            0: 1.0,
            1: 1.5,
            5: 4.0,
            6: 2.0,
            8: 1.2,
            9: 1.8,
        }
        res = p12.analyze_tick_packet_trace(10, rtts)
        self.assertEqual(res["sent_packets"], 10)
        self.assertEqual(res["received_packets"], 6)
        self.assertEqual(res["lost_packets"], 4)
        self.assertEqual(res["loss_pct"], 40.0)
        self.assertEqual(res["burst_loss_events_ge3"], 1)
        self.assertEqual(res["max_consecutive_loss"], 3)
        self.assertEqual(res["rtt_ms"]["min"], 1.0)
        self.assertEqual(res["rtt_ms"]["max"], 4.0)
        self.assertGreater(res["jitter"]["mean_ms"], 0.0)

    def test_compare_network_arms_and_select_optimal_vcpu(self) -> None:
        slirp = {
            "overall_60s": {"rtt_ms": {"p50": 2.0, "p99": 25.0}, "jitter": {"mean_ms": 1.8}, "loss_pct": 1.2, "burst_loss_events_ge3": 3},
            "loaded_last_30s": {"rtt_ms": {"p99": 40.0}},
            "host_cpu": {"qemu_main_thread_cpu": {"mean": 30.0}, "qemu_worker_cpu": {"mean": 400.0}},
        }
        vmnet = {
            "overall_60s": {"rtt_ms": {"p50": 0.5, "p99": 2.0}, "jitter": {"mean_ms": 0.2}, "loss_pct": 0.0, "burst_loss_events_ge3": 0},
            "loaded_last_30s": {"rtt_ms": {"p99": 3.0}},
            "host_cpu": {"qemu_main_thread_cpu": {"mean": 12.0}, "qemu_worker_cpu": {"mean": 360.0}},
        }
        cmp_res = p12.compare_network_arms(slirp, vmnet)
        self.assertEqual(cmp_res["overall_p50_rtt_delta_pct"], -75.0)
        self.assertEqual(cmp_res["overall_p99_rtt_delta_pct"], -92.0)
        self.assertEqual(cmp_res["candidate_burst_loss_events"], 0)
        self.assertEqual(cmp_res["qemu_main_thread_cpu_delta_pct"], -60.0)

        arms = {
            "vcpu_6": {
                "vcpu": 6,
                "drawcall_only": {"probe": {"fps": {"mean": 52.0, "p1_low": 40.0}}},
                "drawcall_with_mt_load": {"probe": {"fps": {"mean": 41.0, "p1_low": 29.0}}, "host": {"qemu_render_server_cpu": {"mean": 10.0}, "qemu_worker_cpu": {"mean": 450.0}}},
                "multithread_cpu": {"total_ops_per_sec": 12000.0},
            },
            "vcpu_7": {
                "vcpu": 7,
                "drawcall_only": {"probe": {"fps": {"mean": 55.0, "p1_low": 44.0}}},
                "drawcall_with_mt_load": {"probe": {"fps": {"mean": 48.0, "p1_low": 38.0}}, "host": {"qemu_render_server_cpu": {"mean": 11.0}, "qemu_worker_cpu": {"mean": 520.0}}},
                "multithread_cpu": {"total_ops_per_sec": 14500.0},
            },
            "vcpu_8": {
                "vcpu": 8,
                "drawcall_only": {"probe": {"fps": {"mean": 54.0, "p1_low": 39.0}}},
                "drawcall_with_mt_load": {"probe": {"fps": {"mean": 46.0, "p1_low": 33.0}}, "host": {"qemu_render_server_cpu": {"mean": 12.0}, "qemu_worker_cpu": {"mean": 610.0}}},
                "multithread_cpu": {"total_ops_per_sec": 15200.0},
            },
        }
        decision = p12.select_optimal_vcpu(arms)
        self.assertEqual(decision["recommended_vcpu"], 7)
        self.assertEqual(decision["winning_arm"], "vcpu_7")
        self.assertEqual(len(decision["ranking"]), 3)

    def test_host_udp_echo_server_roundtrip_and_redaction(self) -> None:
        srv = p12.HostUdpEchoServer()
        port = srv.start()
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as cli:
                cli.settimeout(2.0)
                payload = struct.pack("<IIqq", 7, 0, 123456, 0) + b"x" * 72
                cli.sendto(payload, ("127.0.0.1", port))
                data, _ = cli.recvfrom(2048)
                self.assertEqual(len(data), len(payload))
                seq, _pad, client_ts, host_ts = struct.unpack("<IIqq", data[:24])
                self.assertEqual(seq, 7)
                self.assertEqual(client_ts, 123456)
                self.assertGreater(host_ts, 0)
        finally:
            srv.stop()

        user = os.environ.get("USER", "someone")
        raw = f"/Volumes/PrivateSSD/vms/{user}/11111111-2222-3333-4444-555555555555"
        clean = p12.redact_p12_text(raw)
        self.assertNotIn("PrivateSSD", clean)
        self.assertNotIn("11111111-2222-3333-4444-555555555555", clean)
        self.assertIn("/Volumes/<EXTERNAL_VOLUME>", clean)
        if user:
            self.assertNotIn(user, clean)

    def test_render_p12a_report_markdown_is_complete_and_redacted(self) -> None:
        doc = {
            "captured_at_utc": "2026-11-25T07:00:00+00:00",
            "golden_id": "golden-win11-arm64-v1",
            "golden_manifest_sha256": "abc123",
            "host_hardware": {"total_cpus": 10, "p_cores": 4, "host_network_capabilities": {"official_utm_vmnet_entitled": True, "socket_vmnet_installed": False}},
            "network_benchmark": {
                "protocol": "UDP 128-tick 60s",
                "arms": {
                    "slirp_baseline": {"network_mode": "emulated", "overall_60s": {"rtt_ms": {"p50": 2.0, "p99": 20.0}, "loss_pct": 0.5, "burst_loss_events_ge3": 1, "jitter": {"mean_ms": 1.2}}, "loaded_last_30s": {"rtt_ms": {"p99": 30.0}}, "host_cpu": {"qemu_main_thread_cpu": {"mean": 25.0}, "qemu_worker_cpu": {"mean": 300.0}}},
                    "async_socket_stream": {"network_mode": "socket-stream", "overall_60s": {"rtt_ms": {"p50": 0.7, "p99": 4.0}, "loss_pct": 0.0, "burst_loss_events_ge3": 0, "jitter": {"mean_ms": 0.3}}, "loaded_last_30s": {"rtt_ms": {"p99": 5.0}}, "host_cpu": {"qemu_main_thread_cpu": {"mean": 15.0}, "qemu_worker_cpu": {"mean": 280.0}}},
                    "vmnet_shared_native": {"network_mode": "vmnet-shared", "overall_60s": {"rtt_ms": {"p50": 0.4, "p99": 1.8}, "loss_pct": 0.0, "burst_loss_events_ge3": 0, "jitter": {"mean_ms": 0.2}}, "loaded_last_30s": {"rtt_ms": {"p99": 2.2}}, "host_cpu": {"qemu_main_thread_cpu": {"mean": 12.0}, "qemu_worker_cpu": {"mean": 270.0}}},
                },
                "comparisons": {
                    "vmnet_shared_vs_slirp": {"overall_p50_rtt_delta_pct": -80.0, "overall_p99_rtt_delta_pct": -91.0, "loaded_p99_rtt_delta_pct": -92.67, "overall_jitter_mean_delta_pct": -83.33, "qemu_main_thread_cpu_delta_pct": -52.0},
                    "async_socket_stream_vs_slirp": {"overall_p50_rtt_delta_pct": -65.0, "overall_p99_rtt_delta_pct": -80.0, "loaded_p99_rtt_delta_pct": -83.33, "overall_jitter_mean_delta_pct": -75.0, "qemu_main_thread_cpu_delta_pct": -40.0},
                },
            },
            "storage_io_and_ram_benchmark": {
                "arms": {
                    "nvme_baseline_8gib": {"io": {"rand_4k_read_iops": 8000.0, "rand_4k_write_iops": 900.0, "seq_64k_stream_read_mib_s": 500.0, "trim_retrim_ok": True, "disk_model": "QEMU NVMe"}},
                    "virtio_blk_iothread_q4_10gib": {"io": {"rand_4k_read_iops": 12000.0, "rand_4k_write_iops": 1400.0, "seq_64k_stream_read_mib_s": 850.0, "trim_retrim_ok": True, "disk_model": "Red Hat VirtIO SCSI Disk Device"}},
                },
                "virtio_iothread_10gib_vs_nvme_8gib": {"rand_4k_read_iops_delta_pct": 50.0, "rand_4k_write_iops_delta_pct": 55.56, "seq_64k_stream_read_mib_s_delta_pct": 70.0},
            },
            "vcpu_scaling_benchmark": {
                "arms": {
                    f"vcpu_{n}": {
                        "vcpu": n,
                        "drawcall_only": {"probe": {"fps": {"mean": 50.0 + n, "p1_low": 40.0 + n}, "cpu_submit_ms": {"mean": 18.0}}},
                        "drawcall_with_mt_load": {"probe": {"fps": {"mean": 45.0 + n, "p1_low": 35.0 + n}}, "host": {"qemu_render_server_cpu": {"mean": 10.0}, "qemu_worker_cpu": {"mean": 400.0}, "total_hypervisor_rss_mib": {"max": 3200.0}}},
                        "multithread_cpu": {"total_ops_per_sec": 10000.0 + n * 1000},
                    }
                    for n in (6, 7, 8)
                },
                "decision": {"recommended_vcpu": 7, "rationale": "7 vCPU optimal"},
            },
            "guest_optimizer_v31_verification": {
                "profile_revision": 4,
                "profile_version": "3.1",
                "security_invariants_passed": True,
                "spice_webdavd_before": {"Name": "spice-webdavd", "StartMode": "Auto", "State": "Running"},
                "spice_webdavd_after_apply": {"Name": "spice-webdavd", "StartMode": "Disabled", "State": "Stopped"},
                "spice_new_crashes_after_apply": 0,
                "pagefile_apply": {"status": "applied", "requested_initial_mb": 8192, "requested_maximum_mb": 12288, "applied_initial_mb": 7500, "applied_maximum_mb": 7500, "drive_free_mb": 7600, "current_pagefile_mb": 2048},
                "rollback": {"rollback_consistent": True, "mismatch_count": 0, "security_invariants_passed": True, "spice_webdavd_after_rollback": {"Name": "spice-webdavd", "StartMode": "Auto"}},
            },
            "zero_drift_verification": {"golden_readonly": True, "golden_zero_drift": True, "primary_zero_drift": True, "zero_drift": True, "utm_defaults_restored": True, "original_utm_app_present": True},
        }
        md = p12.render_p12a_report_markdown(doc, bench_sha="deadbeef", drift_sha="cafebabe")
        self.assertIn("Phase 12A 执行报告", md)
        self.assertIn("spice-webdavd", md)
        self.assertIn("rollback_consistent = True", md)
        self.assertIn("zero_drift = True", md)
        user = os.environ.get("USER", "")
        if user:
            self.assertNotIn(user, md)


if __name__ == "__main__":
    unittest.main()
