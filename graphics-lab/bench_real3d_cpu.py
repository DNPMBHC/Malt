"""Interval CPU accounting using macOS libproc; owner @DNPMBHC."""
import ctypes
import ctypes.util
import os
import statistics
import struct
import subprocess
import threading
import time


def process_table():
    r=subprocess.run(["ps","-axo","pid=,ppid=,comm="],capture_output=True,text=True)
    if r.returncode:
        raise RuntimeError("Process inventory unavailable")
    rows={}
    for line in r.stdout.splitlines():
        fields=line.strip().split(None,2)
        if len(fields)==3:
            rows[int(fields[0])] = (int(fields[1]),fields[2])
    return rows


def family(table, roots):
    selected=set(roots)&set(table)
    while True:
        extra={pid for pid,(parent,_name) in table.items() if parent in selected}
        expanded=selected|extra
        if expanded==selected:
            return selected
        selected=expanded


class Counter:
    def __init__(self):
        clock=ctypes.CDLL(None)
        info=ctypes.create_string_buffer(8)
        if clock.mach_timebase_info(ctypes.byref(info)):
            raise RuntimeError("Host clock timebase unavailable")
        numerator,denominator=struct.unpack("<II",info.raw)
        self.seconds_per_tick=numerator/denominator/1e9
        self.lib=ctypes.CDLL(ctypes.util.find_library("proc"),use_errno=True)
        self.lib.proc_pid_rusage.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_void_p]
        self.lib.proc_pid_rusage.restype=ctypes.c_int

    def read(self,pid):
        buf=ctypes.create_string_buffer(4096)
        if self.lib.proc_pid_rusage(pid,0,ctypes.byref(buf)):
            return None
        # SDK rusage_info_v0: 16 UUID bytes followed by 10 uint64 values.
        fields=struct.unpack_from("<10Q",buf.raw,16)
        return (fields[8],(fields[0]+fields[1])*self.seconds_per_tick)


class HostCPUSampler:
    def __init__(self,root_pids,interval_sec=0.05):
        self.roots=set(root_pids)
        self.interval_sec=interval_sec
        self.counter=Counter()
        self.samples=[]
        self.errors=0
        self._stop=threading.Event()
        self._thread=None
        self.previous={}
        self.previous_time=None
        self._result=None

    def tick(self):
        now=time.monotonic()
        table=process_table()
        pids=family(table,self.roots)
        current={pid:value for pid in pids if (value:=self.counter.read(pid)) is not None}
        if self.previous_time is not None:
            wall=now-self.previous_time
            cpu=sum(max(0.0,value[1]-self.previous[pid][1]) for pid,value in current.items()
                    if pid in self.previous and value[0]==self.previous[pid][0])
            if wall>0 and current:
                self.samples.append({"wall_seconds":wall,"cpu_seconds":cpu,"cpu_percent":100*cpu/wall,
                                     "live_process_count":len(current)})
            else:
                self.errors+=1
        self.previous=current
        self.previous_time=now

    def loop(self):
        while not self._stop.wait(self.interval_sec):
            try:self.tick()
            except (OSError,RuntimeError):self.errors+=1

    def start(self):
        if self._result is not None or self._thread is not None:
            raise RuntimeError("A sampler accounts for one measurement interval")
        self.tick()
        self._thread=threading.Thread(target=self.loop,daemon=True)
        self._thread.start()

    def stop(self):
        if self._result is not None:
            return self._result
        self._stop.set()
        if self._thread:self._thread.join(timeout=2)
        self._thread=None
        try:self.tick()
        except (OSError,RuntimeError):self.errors+=1
        wall=sum(s["wall_seconds"] for s in self.samples)
        cpu=sum(s["cpu_seconds"] for s in self.samples)
        mean=100*cpu/wall if wall else None
        cores=os.cpu_count() or 1
        self._result = {"method":"libproc RUSAGE_INFO_V0 user+system counter deltas; PID family and creation-time binding",
                "scope":"measurement phase only; roots and descendants", "sample_count":len(self.samples),
                "sample_errors":self.errors,"covered_wall_seconds":wall,"cpu_seconds":cpu,
                "host_cpu_percent_mean":mean,"host_cpu_percent_peak":max((s["cpu_percent"] for s in self.samples),default=None),
                "host_logical_cpu_count":cores,"host_capacity_percent_mean":mean/cores if mean is not None else None,
                "units":"100 percent equals one logical CPU; zeros retained", "samples":[sample.copy() for sample in self.samples],
                "limitation":"Counter sampling can miss CPU between the final available counter and process exit"}
        return self._result
