# Read-only documented WMI process lifecycle capture. Owner: @DNPMBHC.
param([int]$Seconds=180,[string]$Output='C:\p5a-tools\game-lifecycle.json')
$ErrorActionPreference='Stop'
$records=[Collections.Generic.List[object]]::new()
$names=@{};$active=@{};$counter=0;$errors=[Collections.Generic.List[object]]::new()
$known=Get-Content C:\p5a-tools\backup-client-private.json -Raw|ConvertFrom-Json
foreach($exe in $known.executables){
 $counter++;$names[[IO.Path]::GetFileName($exe.path).ToLowerInvariant()]=@{alias=('client-exe-{0:d3}' -f $counter);role='client'}
}
foreach($exe in @(Get-ChildItem R:\p5a -Filter *.exe -Recurse -ErrorAction Stop)){
 $counter++;$names[$exe.Name.ToLowerInvariant()]=@{alias=('launcher-exe-{0:d3}' -f $counter);role='launcher'}
}
foreach($proc in @(Get-CimInstance Win32_Process)){
 $name=$proc.Name.ToLowerInvariant()
 if($names.ContainsKey($name)){$active[[string]$proc.ProcessId]=$names[$name]}
}
$started=[DateTimeOffset]::UtcNow
try{
 Register-WmiEvent -Class Win32_ProcessStartTrace -SourceIdentifier p5a-start|Out-Null
 Register-WmiEvent -Class Win32_ProcessStopTrace -SourceIdentifier p5a-stop|Out-Null
 @{status='ready';captured_at_utc=[DateTimeOffset]::UtcNow.ToString('o')}|ConvertTo-Json -Compress|Set-Content ($Output+'.ready') -Encoding UTF8
 $deadline=[DateTime]::UtcNow.AddSeconds($Seconds)
 while([DateTime]::UtcNow -lt $deadline){
  foreach($event in @(Get-Event -ErrorAction SilentlyContinue)){
   if($event.SourceIdentifier -notin @('p5a-start','p5a-stop')){continue}
   $item=$event.SourceEventArgs.NewEvent;$pidKey=[string]$item.ProcessID
   $name=([string]$item.ProcessName).ToLowerInvariant()
   if($names.ContainsKey($name) -or $active.ContainsKey($pidKey)){
    $id=if($names.ContainsKey($name)){$names[$name]}else{$active[$pidKey]}
    $kind=if($event.SourceIdentifier -eq 'p5a-start'){'start'}else{'stop'}
    if($kind -eq 'start'){$active[$pidKey]=$id}else{$active.Remove($pidKey)}
    $records.Add(@{kind=$kind;process_alias=$id.alias;role=$id.role;pid=[int]$item.ProcessID;parent_pid=[int]$item.ParentProcessID;event_time_utc=[DateTime]::FromFileTimeUtc([long]$item.TIME_CREATED).ToString('o');native_exit_code=if($kind -eq 'stop'){[uint32]$item.ExitStatus}else{$null}})
   }
   Remove-Event -EventIdentifier $event.EventIdentifier
  }
  @{owner='@DNPMBHC';status='capturing';method='Win32_ProcessStartTrace and Win32_ProcessStopTrace';records=@($records.ToArray());errors=@($errors.ToArray());started_at_utc=$started.ToString('o')}|ConvertTo-Json -Depth 8 -Compress|Set-Content $Output -Encoding UTF8
  Start-Sleep -Milliseconds 200
 }
}catch{
 $errors.Add(@{status='capture_failed';native_hresult=('0x{0:x8}' -f ($_.Exception.HResult -band 0xffffffffL))})
}finally{
 Unregister-Event -SourceIdentifier p5a-start -ErrorAction SilentlyContinue
 Unregister-Event -SourceIdentifier p5a-stop -ErrorAction SilentlyContinue
 Get-Job|Where-Object Name -in @('p5a-start','p5a-stop')|Remove-Job -Force -ErrorAction SilentlyContinue
 @{owner='@DNPMBHC';status=if($errors.Count){'incomplete'}else{'completed'};method='Win32_ProcessStartTrace and Win32_ProcessStopTrace';records=@($records.ToArray());errors=@($errors.ToArray());started_at_utc=$started.ToString('o');ended_at_utc=[DateTimeOffset]::UtcNow.ToString('o');limitation='Only known client and launcher image names are retained; unknown or short-lived image names can be missed.'}|ConvertTo-Json -Depth 8 -Compress|Set-Content $Output -Encoding UTF8
}
