#!/usr/bin/env python3
"""Build the guest-owned explicit compute probe. Contributor: @DNPMBHC."""
import hashlib
import json
import pathlib
import re
import shutil
import subprocess


def main():
    directory = pathlib.Path(__file__).resolve().parent
    compiler = shutil.which("x86_64-w64-mingw32-g++")
    inspector = shutil.which("x86_64-w64-mingw32-objdump")
    if not compiler or not inspector:
        raise SystemExit("Windows x64 cross-compiler and binary inspector are required.")
    flags = ["-std=c++17", "-O2", "-Wall", "-Wextra", "-Werror", "-static",
             "-static-libgcc", "-static-libstdc++", "compute-probe.cpp", "-lws2_32",
             "-o", "compute-probe.exe"]
    result = subprocess.run([compiler] + flags, cwd=directory, capture_output=True, text=True)
    output = result.stdout + result.stderr
    output = re.sub(r"/(?:Users|Volumes)/[^\s:]+", "<LOCAL_PATH>", output)
    if output:
        print(output)
    if result.returncode:
        raise SystemExit(result.returncode)
    inspection = subprocess.run([inspector, "-p", "compute-probe.exe"], cwd=directory,
                                capture_output=True, text=True, check=True).stdout
    version = subprocess.run([compiler, "--version"], capture_output=True,
                             text=True, check=True).stdout.splitlines()[0]
    evidence = {
        "schemaVersion": 1,
        "contributor": "@DNPMBHC",
        "scope": "explicitComputeInterfaceOnly",
        "transparentPEMigration": False,
        "validationScope": "hostCrossCompileOnly",
        "probeArchitecture": "x86_64",
        "compiler": version,
        "compileFlags": flags,
        "compileExitCode": 0,
        "imports": re.findall(r"DLL Name:\s*(\S+)", inspection),
        "artifacts": {name: hashlib.sha256((directory / name).read_bytes()).hexdigest()
                      for name in ["compute-probe.cpp", "compute-probe.exe"]},
    }
    (directory / "probe-build.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps({"compileExitCode": 0, "probeArchitecture": "x86_64",
                      "artifactSHA256": evidence["artifacts"]["compute-probe.exe"]}))


if __name__ == "__main__":
    main()
