# Read-only event bookmarks and numeric error evidence. Owner: @DNPMBHC.
param(
    [Parameter(Mandatory)][ValidateSet('before','after')][string]$Stage,
    [Parameter(Mandatory)][string]$StateFile,
    [Parameter(Mandatory)][string]$OutputFile,
    [ValidateRange(1,10000)][int]$MaxEvents = 5000
)
$ErrorActionPreference = 'Stop'
$logs = @('System','Application','Microsoft-Windows-CodeIntegrity/Operational')
$bookmarks = @{}
if ($Stage -eq 'before') {
    if (Test-Path -LiteralPath $StateFile) { throw 'Use a fresh event bookmark state.' }
} else {
    $saved = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
    foreach ($entry in $saved.bookmarks) { $bookmarks[$entry.log_alias] = [long]$entry.record_id }
}
$coverage = [Collections.Generic.List[object]]::new()
$records = [Collections.Generic.List[object]]::new()
for ($index = 0; $index -lt $logs.Count; $index++) {
    $log = $logs[$index]
    $alias = @('system','application','code-integrity')[$index]
    try {
        $config = Get-WinEvent -ListLog $log -ErrorAction Stop
        if ($Stage -eq 'after' -and -not $bookmarks.ContainsKey($alias)) {
            throw 'This channel has no valid baseline bookmark.'
        }
        $floor = if ($Stage -eq 'before') { 0L } else { $bookmarks[$alias] }
        $last = 0L
        if ($config.RecordCount -gt 0) {
            $last = [long](Get-WinEvent -LogName $log -MaxEvents 1 -ErrorAction Stop).RecordId
        }
        $items = @()
        $empty = $false
        if ($Stage -eq 'before') { $bookmarks[$alias] = $last }
        elseif ($last -ge $floor) {
            $query = '*[System[EventRecordID > ' + $floor + ']]'
            if ($alias -eq 'system') {
                $query = '*[System[EventRecordID > ' + $floor + " and Provider[@Name='Service Control Manager']]]"
            }
            try { $items = @(Get-WinEvent -LogName $log -FilterXPath $query -MaxEvents $MaxEvents -ErrorAction Stop) }
            catch {
                if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { $empty = $true }
                else { throw }
            }
        }
        foreach ($event in $items) {
            $xml = [xml]$event.ToXml()
            $codes = [Collections.Generic.List[object]]::new()
            $data = $xml.SelectNodes("/*[local-name()='Event']/*[local-name()='EventData']/*[local-name()='Data']")
            foreach ($entry in $data) {
                $value = $entry.InnerText
                foreach ($match in [regex]::Matches($value,'%%(\d+)')) {
                    $codes.Add(@{kind='win32_message_code';value=[long]$match.Groups[1].Value})
                }
                foreach ($match in [regex]::Matches($value,'\b0x[0-9a-fA-F]{8}\b')) {
                    $codes.Add(@{kind='hex_status';value=$match.Value.ToLowerInvariant()})
                }
                if ($entry.Name -match '^(?:ErrorCode|Status|ExceptionCode|FailureCode|ExitCode|BugcheckCode)$' -and $value -match '^\d{1,10}$') {
                    $codes.Add(@{kind=$entry.Name;value=[long]$value})
                }
            }
            $records.Add(@{log_alias=$alias;record_id=[long]$event.RecordId;event_id=$event.Id;
                level=$event.Level;guest_time_utc=$event.TimeCreated.ToUniversalTime().ToString('o');
                codes=@($codes.ToArray());raw_message_exported=$false;raw_xml_exported=$false})
        }
        $coverage.Add(@{log_alias=$alias;enabled=[bool]$config.IsEnabled;status='available';
            baseline_record_id=$bookmarks[$alias];latest_record_id=$last;sampled=$items.Count;
            no_matching_events=$empty;possibly_truncated=($items.Count -eq $MaxEvents);
            record_id_reset=($Stage -eq 'after' -and $last -lt $floor)})
    } catch {
        $coverage.Add(@{log_alias=$alias;status='unavailable';exception_type=$_.Exception.GetType().FullName})
    }
}
if ($Stage -eq 'before') {
    $state = @{bookmarks=@($bookmarks.GetEnumerator() | ForEach-Object {@{log_alias=$_.Key;record_id=$_.Value}})}
    [IO.File]::WriteAllText($StateFile,($state | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
}
$report = @{owner='@DNPMBHC';stage=$Stage;guest_capture_time_utc=[DateTimeOffset]::UtcNow.ToString('o');
    selection='record IDs after baseline; System SCM, all Application and CodeIntegrity events';
    coverage=@($coverage.ToArray());events=@($records.ToArray());
    limitations=@('Raw messages and identities are withheld. Numeric event codes do not independently prove vendor attribution.',
        'A reset bookmark, disabled channel, read error or sampling limit prevents a complete absence claim.')}
[IO.File]::WriteAllText($OutputFile,($report | ConvertTo-Json -Depth 8 -Compress),[Text.UTF8Encoding]::new($false))
'captured'
