#!/usr/bin/env python3
"""Self-contained read-only official installer media on the owned clone. Owner: @DNPMBHC."""
import importlib.util
import json
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid
from pathlib import Path
EVIDENCE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location("own_media_bootstrap",EVIDENCE/"bootstrap_guest_clone.py")
bootstrap=importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)
EXPECTED_SHA="686ee838411863d2eccdbe8a0596129e509819ae46626408760588ae8b0c800e"
EXPECTED_SIZE=491792264

def stop_owned(owned,identifier):
    ctl=str(bootstrap.clone.controller())
    state=bootstrap.clone.command([ctl,"status",identifier]).decode().strip().lower()
    if state=="paused":
        bootstrap.clone.command([ctl,"start","--hide",identifier])
        state="started"
    method="already_stopped"
    if state=="started":
        bootstrap.clone.command([ctl,"stop","--hide",identifier,"--request"])
        method="guest_request"
        deadline=time.monotonic()+30
        while bootstrap.clone.command([ctl,"status",identifier]).decode().strip().lower()!="stopped":
            if time.monotonic()>=deadline:
                verified,observed=bootstrap.clone.own_clone(json.loads(bootstrap.clone.LEASE.read_text()))
                if verified!=owned or observed!=identifier:raise RuntimeError("media_poweroff_identity_mismatch")
                bootstrap.clone.command([ctl,"stop","--hide",identifier,"--force"])
                method="owned_force_after_request_timeout"
                break
            time.sleep(1)
    if bootstrap.clone.command([ctl,"status",identifier]).decode().strip().lower()!="stopped":
        raise RuntimeError("owned_media_offline_state_required")
    bootstrap.clone.save(EVIDENCE/"official-media-shutdown.json",{"owner":"@DNPMBHC","method":method,"primary_vm_control_actions":0})

def main():
    try:
        owned,identifier=bootstrap.runtime.authorize()
        sources=[p for p in bootstrap.runtime.ROOT.glob("*.exe") if p.stat().st_size==EXPECTED_SIZE and bootstrap.clone.digest(p)==EXPECTED_SHA]
        if len(sources)!=1:raise RuntimeError("official_media_source_not_unique")
        image=owned/"Data/official-tools.iso"
        if not image.exists():
            stage=Path(tempfile.mkdtemp(prefix="owned-installer-media-"))
            try:
                shutil.copyfile(sources[0],stage/"official-installer.exe")
                if bootstrap.clone.digest(stage/"official-installer.exe")!=EXPECTED_SHA:raise RuntimeError("media_staging_hash_failed")
                bootstrap.clone.command(["hdiutil","makehybrid","-iso","-joliet","-o",str(image),str(stage)],timeout=120)
            finally:shutil.rmtree(stage)
        stop_owned(owned,identifier)
        config=plistlib.loads((owned/"config.plist").read_bytes())
        if not any(d.get("ImageName")==image.name for d in config["Drive"]):
            config["Drive"].append({"Identifier":str(uuid.uuid4()).upper(),"ImageType":"CD","Interface":"USB","InterfaceVersion":1,"ImageName":image.name,"ReadOnly":True})
            bootstrap.clone.validate_disks(owned,config)
            (owned/"config.plist").write_bytes(plistlib.dumps(config))
            script="""on run argv
              tell application id "com.utmapp.UTM"
                reload configuration (virtual machine id (item 1 of argv))
              end tell
            end run"""
            bootstrap.clone.command(["osascript","-e",script,"--",identifier])
        bootstrap.clone.save(EVIDENCE/"official-media-readiness.json",{"owner":"@DNPMBHC","clone_identifier":identifier,"image_sha256":bootstrap.clone.digest(image),"read_only":True,"self_contained":True,"source_installer_sha256":EXPECTED_SHA,"primary_vm_control_actions":0})
        bootstrap.start_hidden(identifier)
        security=bootstrap.preflight(identifier)
        if not security["driver_ready"]:raise RuntimeError("official_media_whql_preflight_failed")
        report=bootstrap.powershell(identifier,r"""
$paths=@(Get-CimInstance Win32_CDROMDrive|ForEach-Object {Join-Path $_.Drive 'official-installer.exe'}|Where-Object {Test-Path -LiteralPath $_})
if($paths.Count -ne 1){throw 'official_media_installer_not_unique'}
$p=$paths[0];$sig=Get-AuthenticodeSignature -LiteralPath $p
@{owner='@DNPMBHC';sha256=(Get-FileHash -LiteralPath $p).Hash.ToLowerInvariant();size_bytes=(Get-Item -LiteralPath $p).Length;
 signature_status=[string]$sig.Status;version=(Get-Item -LiteralPath $p).VersionInfo.FileVersion;signature_type=[string]$sig.SignatureType;
 guest_installer_path=$p;drive=(Split-Path -Qualifier $p);media_readonly=$true}
""",timeout=90)
        report["verified"]=report["sha256"]==EXPECTED_SHA and report["size_bytes"]==EXPECTED_SIZE and report["signature_status"]=="Valid"
        report.update(primary_vm_control_actions=0,installer_started=False,human_login_completed=False,clone_identifier=identifier)
        bootstrap.clone.save(EVIDENCE/"official-installer-own-guest-trust.json",report)
        if not report["verified"]:raise RuntimeError("official_guest_media_signature_failed")
        print(json.dumps({"owner":"@DNPMBHC","official_installer_guest_verified":True,"read_only_media":True,"installer_started":False}))
        return 0
    except Exception as error:
        print(json.dumps({"owner":"@DNPMBHC","error_code":str(error) if isinstance(error,RuntimeError) else type(error).__name__}))
        return 1
if __name__=="__main__":raise SystemExit(main())
