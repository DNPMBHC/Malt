import ctypes
import struct
import unittest
from unittest import mock
from bench_real3d_cpu import family,Counter,HostCPUSampler

class CPUFamilyTests(unittest.TestCase):
    def test_pid_family_excludes_unrelated_processes_and_includes_detached_root(self):
        rows={10:(1,"wine"),11:(10,"child"),12:(11,"nested"),20:(1,"wineserver"),21:(20,"service"),30:(1,"other")}
        self.assertEqual(family(rows,{10,20}),{10,11,12,20,21})
        self.assertEqual(family(rows,{99}),set())

    def test_stop_freezes_measurement_before_finally_cleanup(self):
        with mock.patch("bench_real3d_cpu.Counter"):
            sampler=HostCPUSampler({10})
        sampler.samples=[{"wall_seconds":1.0,"cpu_seconds":0.5,"cpu_percent":50.0,"live_process_count":1}]
        with mock.patch.object(sampler,"tick") as tick:
            first=sampler.stop()
            second=sampler.stop()
        self.assertEqual(tick.call_count,1)
        self.assertIs(first,second)
        sampler.samples.append({"wall_seconds":9.0,"cpu_seconds":9.0,"cpu_percent":100.0,"live_process_count":1})
        self.assertEqual(first["sample_count"],1)
        self.assertEqual(len(first["samples"]),1)
        self.assertEqual(first["host_cpu_percent_mean"],50)

    def test_arm_host_ticks_are_converted_using_mach_timebase(self):
        clock=mock.MagicMock();proc=mock.MagicMock()
        def timebase(ptr):
            ctypes.memmove(ptr,struct.pack("<II",125,3),8);return 0
        def read(_pid,_flavor,ptr):
            payload=b"\0"*16+struct.pack("<10Q",24000000,0,0,0,0,0,0,0,17,0)
            ctypes.memmove(ptr,payload,len(payload));return 0
        clock.mach_timebase_info.side_effect=timebase
        proc.proc_pid_rusage.side_effect=read
        with mock.patch("bench_real3d_cpu.ctypes.CDLL",side_effect=[clock,proc]),mock.patch("bench_real3d_cpu.ctypes.util.find_library",return_value="proc"):
            value=Counter().read(10)
        self.assertEqual(value[0],17);self.assertAlmostEqual(value[1],1.0)

if __name__=="__main__":unittest.main()
