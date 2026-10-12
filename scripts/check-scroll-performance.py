#!/usr/bin/env python3
"""Run while scrolling a transcript: python3 scripts/check-scroll-performance.py PID.

Checks the macOS physical memory footprint (including compressed memory),
and fails if scrolling leaves the app continuously busy for five seconds.
"""
import ctypes
import json
import subprocess
import sys
import time

pid = int(sys.argv[1])
assert subprocess.check_output(["ps", "-p", str(pid), "-o", "comm="], text=True).strip().endswith("/ccode"), "Expected the ccode process"

# Public Darwin rusage_info_v4 layout, from sys/resource.h.
class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16), ("values", ctypes.c_uint64 * 35)]

lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]

timebase = Timebase()
system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
system.mach_timebase_info.argtypes = [ctypes.POINTER(Timebase)]
assert system.mach_timebase_info(ctypes.byref(timebase)) == 0
usage = Usage()
busy_since = None
previous_cpu = None
previous_time = time.monotonic()
samples = []
for _ in range(120):
    assert lib.proc_pid_rusage(pid, 4, ctypes.byref(usage)) == 0, "App exited or memory measurement failed"
    memory = usage.values[7] / 1024**2
    now = time.monotonic()
    ticks = usage.values[0] + usage.values[1]
    cpu = 0 if previous_cpu is None else (ticks - previous_cpu) * timebase.numer / timebase.denom / 1e9 / (now - previous_time) * 100
    previous_cpu, previous_time = ticks, now
    samples.append({"memoryMB": round(memory, 1), "cpu": cpu})
    busy_since = (busy_since or now) if cpu > 70 else None
    assert memory < 256, f"Memory regression: {memory:.1f} MB during scrolling"
    assert busy_since is None or now - busy_since < 5, "Scrolling left the app busy for five seconds"
    time.sleep(0.25)
print(json.dumps({"peakMB": max(s["memoryMB"] for s in samples), "finalMB": samples[-1]["memoryMB"], "lifetimePeakMB": round(usage.values[28] / 1024**2, 1), "finalCPU": samples[-1]["cpu"]}))
