"""Read-only owned-clone snapshots for A1. Owner: @DNPMBHC.

The established collector correlates on-disk hashes with documented loaded-image
and SCM APIs. A second inventory covers all SYS/DLL files in explicit roots.
Private paths stay in the disposable Guest; evidence uses neutral aliases.
"""
import json
from pathlib import Path
import bench_real3d_support as support
import bench_real3d_guest as guest


def real_run_dir():
    task=next((support.ROOT/"handoff/phase-5").glob("window-5a-*.md"))
    import re
    matches=re.findall(r"handoff/module-f/[^`\s]+real-runs/",task.read_text())
    if not matches:
        raise RuntimeError("Task evidence directory could not be resolved")
    target=support.ROOT/matches[0]
    target.mkdir(parents=True,exist_ok=True)
    return target


def snapshot(stage,roots=()):
    if stage not in ("before","after","diagnostic"):
        raise ValueError("Explicit evidence stage required")
    collector=support.ROOT/"graphics-lab/bench_real3d_ace_capture.ps1"
    # Reuse a read-only established collector; never modify shared-window files.
    local=guest.GUEST_DIR+r"\p5a-readonly-inventory.ps1"
    support.push(collector,local)
    state=guest.GUEST_DIR+r"\p5a-current-inventory-private-state.json"
    output=guest.GUEST_DIR+"\\p5a-"+stage+"-inventory.json"
    root_args=" -InstallRoot @("+",".join(guest.quote(r) for r in roots)+")" if roots else ""
    # Script block invocation leaves global and process execution policies intact.
    command=("$text=[IO.File]::ReadAllText("+guest.quote(local)+");"
             "$block=[scriptblock]::Create($text);& $block -Stage "+guest.quote(stage)
             +" -StateFile "+guest.quote(state)+" -OutputFile "+guest.quote(output)+root_args)
    result=support.ps(command,180)
    value=json.loads(guest.text_file(output))
    if value.get("status")=="failed":
        raise RuntimeError("Read-only collector did not complete")
    value["owner"]="@DNPMBHC"
    value["collector_sha256"]=support.sha256(collector)
    value["native_invocation_response"]=json.loads(result)
    destination=real_run_dir()/(stage+"-kernel-inventory.json")
    support.write_json(destination,value)
    return value


FILE_INVENTORY=r"""
param([string[]]$Roots)
$ErrorActionPreference='Stop';$errors=[Collections.Generic.List[object]]::new()
$files=[Collections.Generic.List[object]]::new();$seen=@{};$count=0;$dirs=0
foreach($root in $Roots){
 if(-not(Test-Path -LiteralPath $root)){$errors.Add(@{scope='root';status='missing'});continue}
 $queue=[Collections.Generic.Queue[string]]::new();$queue.Enqueue($root)
 while($queue.Count){
  $dir=$queue.Dequeue();$dirs++;$walkErrors=@()
  $children=@(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue -ErrorVariable walkErrors)
  if($walkErrors.Count){$errors.Add(@{scope='enumeration';count=$walkErrors.Count})}
  foreach($f in $children){
   if($f.Attributes -band [IO.FileAttributes]::ReparsePoint){$errors.Add(@{scope='reparse_point';status='skipped'});continue}
   if($f.PSIsContainer){$queue.Enqueue($f.FullName);continue}
   if($f.Extension -notin @('.sys','.dll') -or $seen.ContainsKey($f.FullName)){continue}
   $seen[$f.FullName]=$true;$count++;$alias=('artifact-{0:d4}{1}' -f $count,$f.Extension.ToLowerInvariant())
   try{
    $stream=[IO.File]::Open($f.FullName,'Open','Read','ReadWrite,Delete');$reader=[IO.BinaryReader]::new($stream)
    $machine=$null;$valid=$false
    try{if($stream.Length -ge 64 -and $reader.ReadUInt16() -eq 0x5a4d){
     $stream.Position=60;$off=$reader.ReadUInt32()
     if($off -ge 64 -and $off+24 -le $stream.Length){$stream.Position=$off
      if($reader.ReadUInt32() -eq 0x4550){$machine=('0x{0:x4}' -f $reader.ReadUInt16());$valid=$true}
     }
    }}finally{$reader.Dispose()}
    $sig=Get-AuthenticodeSignature -LiteralPath $f.FullName
    $version=[Diagnostics.FileVersionInfo]::GetVersionInfo($f.FullName).FileVersion
    if($version -notmatch '^\d+(?:[., ]\s*\d+){1,5}$'){$version=$null}
    $files.Add(@{artifact_alias=$alias;extension=$f.Extension.ToLowerInvariant();size_bytes=$f.Length;
     pe_valid=$valid;pe_machine=$machine;file_version=$version;sha256=(Get-FileHash -LiteralPath $f.FullName).Hash.ToLowerInvariant();
     signature=@{status=[string]$sig.Status;signature_type=[string]$sig.SignatureType;
     signer_alias=if($sig.SignerCertificate){'publisher-x'}else{$null};
     whql_publisher=($sig.SignerCertificate -and $sig.SignerCertificate.Subject -match 'Microsoft Windows Hardware Compatibility Publisher')}})
   }catch{$errors.Add(@{artifact_alias=$alias;status='metadata_failed';native_hresult=('0x{0:x8}' -f ($_.Exception.HResult -band 0xffffffffL))})}
  }
 }
}
@{owner='@DNPMBHC';captured_at_utc=[DateTimeOffset]::UtcNow.ToString('o');inventory_complete=($errors.Count -eq 0);
 root_count=$Roots.Count;directories_scanned=$dirs;files=@($files.ToArray());errors=@($errors.ToArray());
 signature_method='Get-AuthenticodeSignature; trust does not prove kernel acceptance'}|ConvertTo-Json -Depth 8 -Compress
"""


def files_snapshot(stem,roots):
    if not stem.replace('-','').isalnum() or not roots:
        raise ValueError("Neutral stem and explicit installed roots required")
    encoded=__import__('base64').b64encode(FILE_INVENTORY.encode('utf-8')).decode()
    source=("$text=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("+guest.quote(encoded)+"));"
            "& ([scriptblock]::Create($text)) -Roots @("+','.join(guest.quote(r) for r in roots)+")")
    output=guest.GUEST_DIR+"\\"+stem+"-sys-dll-inventory.json"
    support.ps(source+" | Set-Content -LiteralPath "+guest.quote(output)+" -Encoding UTF8;'captured'",600)
    value=json.loads(guest.text_file(output))
    support.write_json(real_run_dir()/(stem+'-sys-dll-inventory.json'),value)
    return value


def service_snapshot(stem):
    # CIM exports both Win32 and service-specific status codes; no start/stop calls.
    source=r"""$items=@(Get-CimInstance Win32_SystemDriver)+@(Get-CimInstance Win32_Service)
$index=0;$records=@($items|ForEach-Object{$index++;@{service_alias=('service-{0:d4}' -f $index);
 state=$_.State;started=$_.Started;start_mode=$_.StartMode;exit_code=$_.ExitCode;
 service_specific_exit_code=$_.ServiceSpecificExitCode;service_type=$_.ServiceType}})
@{captured_at_utc=[DateTimeOffset]::UtcNow.ToString('o');services=$records;status='observed';
 limitation='Supplementary uncorrelated snapshot; kernel collector supplies stable driver aliases'}|ConvertTo-Json -Depth 6 -Compress"""
    output=guest.GUEST_DIR+"\\"+stem+"-scm-status.json"
    support.ps(source+" | Set-Content -LiteralPath "+guest.quote(output)+" -Encoding UTF8;'captured'",90)
    value=json.loads(guest.text_file(output))
    support.write_json(real_run_dir()/(stem+'-scm-status.json'),value)
    return value


def events_snapshot(stage, stem):
    """Use record IDs so Guest clock correction cannot discard launch events."""
    if stage not in ('before', 'after') or not stem.replace('-', '').isalnum():
        raise ValueError('Explicit stage and neutral evidence stem required')
    collector = support.ROOT / 'graphics-lab/bench_real3d_events.ps1'
    local = guest.GUEST_DIR + r'\p5a-readonly-events.ps1'
    state = guest.GUEST_DIR + r'\p5a-event-bookmarks.json'
    output = guest.GUEST_DIR + '\\' + stem + '-events.json'
    support.push(collector, local)
    command = ('$block=[scriptblock]::Create([IO.File]::ReadAllText('
               + guest.quote(local) + '));& $block -Stage ' + guest.quote(stage)
               + ' -StateFile ' + guest.quote(state) + ' -OutputFile '
               + guest.quote(output))
    started = support.utc()
    support.ps(command, 180)
    value = json.loads(guest.text_file(output))
    value['host_query_started_utc'] = started
    value['host_query_completed_utc'] = support.utc()
    value['collector_sha256'] = support.sha256(collector)
    support.write_json(real_run_dir() / (stem + '-events.json'), value)
    return value
