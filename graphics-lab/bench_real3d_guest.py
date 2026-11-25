"""Explicit owned-clone interactive execution. Owner: @DNPMBHC."""
import base64
import json
import time
import socket
import threading
import secrets
from pathlib import Path
import bench_real3d_support as support
from bench_real3d_cpu import HostCPUSampler,process_table
from bench_real3d_runner import parse_probe_json_lines,summarize_real3d_csv

GUEST_DIR=r"C:\p5a-tools"


def quote(value):return "'"+value.replace("'","''")+"'"


def launch(executable,args,stem,run_level="Limited"):
    if run_level not in ("Limited","Highest"):raise ValueError("Explicit scheduled task run level required")
    if not stem.replace("-","").isalnum():raise ValueError("Neutral run stem required")
    task="p5a-"+stem
    files={name:GUEST_DIR+"\\"+stem+"."+name for name in ["stdout.log","stderr.log","done","pid","ps1"]}
    argument_fragment = (" -ArgumentList @("+",".join(quote(a) for a in args)+")") if args else ""
    script=("$ErrorActionPreference='Stop';try {$p=Start-Process -WindowStyle Normal -FilePath "+quote(executable)
            +argument_fragment+" -PassThru -RedirectStandardOutput "
            +quote(files["stdout.log"])+" -RedirectStandardError "+quote(files["stderr.log"])
            +";$handle=$p.Handle;$p.Id|Set-Content "+quote(files["pid"])
            +";$p.WaitForExit();$code=$p.ExitCode;if($null -eq $code){$code=1};$code|Set-Content "+quote(files["done"])
            +"}catch{1|Set-Content "+quote(files["done"])+";$_|Out-File "+quote(files["stderr.log"])+"}")
    encoded=base64.b64encode(script.encode("utf-8")).decode()
    command=base64.b64encode(script.encode("utf-16-le")).decode()
    setup=("$ErrorActionPreference='Stop';$user=(Get-CimInstance Win32_ComputerSystem).UserName;"
           "if(!$user){throw 'Visible interactive desktop required'};"
           "Remove-Item -LiteralPath @("+",".join(quote(files[n]) for n in ["stdout.log","stderr.log","done","pid"])+") -ErrorAction SilentlyContinue;"
           "$bytes=[Convert]::FromBase64String("+quote(encoded)+");[IO.File]::WriteAllBytes("+quote(files["ps1"])+",$bytes);"
           "$a=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "+quote('-NoProfile -WindowStyle Hidden -EncodedCommand '+command)+";"
           "$p=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel "+run_level+";"
           "Register-ScheduledTask -TaskName "+quote(task)+" -Action $a -Principal $p -Force|Out-Null;"
           "Start-ScheduledTask -TaskName "+quote(task)+";'started'")
    support.ps(setup,30)
    return files


def wait(stem,timeout=300):
    deadline=time.monotonic()+timeout
    done=GUEST_DIR+"\\"+stem+".done"
    while time.monotonic()<deadline:
        value=support.ps("if(Test-Path "+quote(done)+"){(Get-Content "+quote(done)+").Trim()}else{'pending'}",20)
        if value!='pending':return int(value)
        time.sleep(.2)
    raise TimeoutError("Owned Guest run has not completed")


def text_file(path):
    try:
        raw=support.pull(path)
    except RuntimeError:
        # utmctl can reject an empty artifact. Confirm emptiness independently.
        size=support.ps("if(Test-Path -LiteralPath "+quote(path)+"){[string](Get-Item -LiteralPath "+quote(path)+").Length}else{'missing'}",20)
        if size=='0':return ''
        raise
    return raw.decode("utf-16") if raw.startswith((b"\xff\xfe",b"\xfe\xff")) else raw.decode("utf-8-sig",errors="replace")


def remove_task(stem):
    support.ps("Unregister-ScheduledTask -TaskName "+quote("p5a-"+stem)+" -Confirm:$false -ErrorAction SilentlyContinue",20)


def benchmark(probe,output_dir,rounds=3,warmup=120,frames=900,draws=2048,cb_updates=256):
    output_dir.mkdir(parents=True,exist_ok=True)
    exe=GUEST_DIR+r"\bench_real3d_probe.exe"
    support.push(probe,exe)
    actual=json.loads(support.ps("(Get-FileHash "+quote(exe)+").Hash.ToLowerInvariant()|ConvertTo-Json -Compress",20))
    if actual!=support.sha256(probe):raise RuntimeError("Guest binary hash mismatch")
    runs=[]
    for index in range(1,rounds+1):
        stem=f"guest-qemu-r{index}"
        csv=GUEST_DIR+"\\"+stem+".csv"
        print("Guest pressure round",index,flush=True)
        args=["--width","1280","--height","720","--warmup",str(warmup),"--frames",str(frames),
              "--draws",str(draws),"--cb-updates",str(cb_updates),"--csv",csv]
        isolation=support.runtime_isolation()
        roots=set(isolation['root_pids'])
        if not roots:raise RuntimeError("Owned hypervisor worker is absent")
        sampler=HostCPUSampler(roots)
        gateway=json.loads(support.ps("(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0'|Select-Object -First 1 -ExpandProperty NextHop)|ConvertTo-Json -Compress",20))
        marker=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
        marker.bind(("",0));marker.settimeout(1)
        token=secrets.token_hex(12)
        args.extend(["--notify-host",gateway,"--notify-port",str(marker.getsockname()[1]),"--notify-token",token])
        cpu_box=[]
        stop_marker=threading.Event()
        active_box=[]
        def receive_markers():
            while not stop_marker.is_set():
                try:message,_peer=marker.recvfrom(256)
                except socket.timeout:continue
                if message==f"{token}|begin".encode() and not active_box:
                    sampler.start();active_box.append(True)
                elif message==f"{token}|end".encode() and active_box:
                    cpu_box.append(sampler.stop());return
        listener=threading.Thread(target=receive_markers);listener.start()
        files=launch(exe,args,stem)
        active=False
        try:
            done=files["done"]
            value=support.ps("while(-not(Test-Path "+quote(done)+")){Start-Sleep -Milliseconds 500};(Get-Content "+quote(done)+").Trim()",timeout=300)
            code=int(value)
            listener.join(timeout=2)
            cpu=cpu_box[0] if cpu_box else {}
            cpu["boundary_method"]="two token-bound UDP markers outside frame loop; no repeated QGA polling"
            stdout=text_file(files["stdout.log"]);stderr=text_file(files["stderr.log"])
            (output_dir/(stem+".stdout.log")).write_text(support.redact(stdout))
            (output_dir/(stem+".stderr.log")).write_text(support.redact(stderr))
            if code:raise RuntimeError("Guest probe exit "+str(code)+"; see captured stderr")
            if not cpu.get("sample_count"):raise RuntimeError("Guest measurement markers were not received; CPU baseline invalid")
            meta,completion=parse_probe_json_lines(stdout)
            if meta.get("adapter_is_software") or meta.get("vendor_id")!=0x1af4:
                raise RuntimeError("Guest did not use WHQL hardware adapter")
            local=output_dir/(stem+".csv");local.write_bytes(support.pull(csv))
            item={"arm":"guest_qemu_viogpu3d","domain":"guest_qemu_viogpu3d","round":index,
                  "metadata":meta,"completion":completion,"csv_summary":summarize_real3d_csv(local),
                  "host_cpu":cpu,"host_runtime_isolation":isolation,
                  "native_exit_code":code,"probe_sha256":actual,
                  "files":{"csv":local.name,"csv_sha256":support.sha256(local)}}
            runs.append(item);support.write_json(output_dir/(stem+".json"),item)
        finally:
            stop_marker.set();listener.join(timeout=2);marker.close()
            if active_box:sampler.stop()
            remove_task(stem)
    result={"runs":runs,"digests":{"guest_probe_exe":actual},"captured_at_utc":support.utc()}
    support.write_json(output_dir/"guest-runs.json",result)
    return result
