# The fleet collector: one run is one scan of the fleet, merged into one CSV.
#
# Collect-MWSTFleet.ps1 (collector v6.2) as the web app runs it, unchanged in
# what it writes, so the Power BI report and anything else reading
# MWST_FleetEvents.csv see no difference. For every kiosk on the list it:
#
#   - checks the kiosk is reachable (ping, falling back to SMB on 445)
#   - reads the watchdog's event ledger (mwst_events*.csv) from its Public
#     Documents share, including the Windows System-log records (1074, 6008,
#     6005) each kiosk's agent copies into it
#   - checks how recently mwst.log was written, to tell whether the watchdog is alive
#   - reads the launchers' status files (PBI Launcher, Web Launcher, Mach2 Launcher NG)
#
# and merges it all into a long fact table with one row per event. Every row
# has a stable EventId, so reading the same ledger again never duplicates.
#
# Why no reboot is missed, and why one boot is one reboot however many
# records describe it, is explained at Update-KfwRebootFlags. Count rows with
# IsScriptReboot = TRUE (reboots the watchdog caused) or IsCanonicalReboot =
# TRUE (every reboot), never EventType rows directly.
#
# The CSV is a cache of durable sources: rewritten in full (atomically) when
# something changed, re-derivable from the kiosks. Two copies are kept - the
# published one (KFW_PUBLISH_CSV, e.g. a synced SharePoint folder) and the
# local one in the data folder - and each run merges both, so either
# restores the other.

$script:CollectorVersion = '6.2-ps'

$script:Columns = [string[]]@(
    'EventId', 'EventTimeUtc', 'EventTimeLocal', 'EventDate',
    'Host', 'Location', 'KioskType', 'RestartGroup',
    'EventCategory', 'EventType', 'Severity', 'Outcome',
    'IsCanonicalReboot', 'IsScriptReboot', 'RebootTrigger',
    'WhitePercent', 'StreakChecks', 'DurationSeconds',
    'Reachable', 'WatchdogRunning', 'MinutesSinceLastLog',
    'AgentVersion', 'BootTimeUtc', 'UptimeHours',
    'Source', 'ScanId', 'CollectedUtc', 'Detail'
)
$script:ColumnSet = [Collections.Generic.HashSet[string]]::new($script:Columns, [StringComparer]::Ordinal)

$script:CategoryByType = @{
    RESTART_TRIGGERED = 'REBOOT'; RESTART_CONFIRMED = 'REBOOT'; RESTART_FAILED = 'REBOOT'
    REBOOT_SCRIPT = 'REBOOT'; REBOOT_EXTERNAL = 'REBOOT'; REBOOT_UNEXPECTED = 'REBOOT'; BOOT = 'REBOOT'
    WHITE_EPISODE_START = 'SCREEN'; WHITE_EPISODE_END = 'SCREEN'
    LOWWHITE_EPISODE_START = 'SCREEN'; LOWWHITE_EPISODE_END = 'SCREEN'
    AGENT_START = 'AGENT'; AGENT_STOP = 'AGENT'; AGENT_ERROR = 'AGENT'; AGENT_RECOVERED = 'AGENT'
    LOOP_GUARD_ENGAGED = 'AGENT'; LOOP_GUARD_RELEASED = 'AGENT'
    MESSAGE_SHOWN = 'AGENT'; MESSAGE_CLOSED = 'AGENT'; MESSAGE_EXPIRED = 'AGENT'; MESSAGE_REJECTED = 'AGENT'
    HOST_STATUS = 'STATUS'; COLLECTOR_RUN = 'COLLECTOR'
}

$script:GuidRx = [regex]'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$script:Strict = [Text.UTF8Encoding]::new($false, $true)

function Get-KfwMono { [Diagnostics.Stopwatch]::GetTimestamp() / [double][Diagnostics.Stopwatch]::Frequency }

function Test-KfwOrdinalLess([string]$A, [string]$B) { [string]::CompareOrdinal($A, $B) -lt 0 }

# --- value formatting: culture-invariant, TRUE/FALSE, "" for not applicable --------------
function Format-KfwNumber($Value, [int]$Decimals = 2) {
    if ($null -eq $Value) { return '' }
    $d = 0.0
    if ($Value -is [string]) {
        if (-not $Value.Trim()) { return '' }
        if (-not [double]::TryParse($Value.Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return '' }
    } else {
        try { $d = [double]$Value } catch { return '' }
    }
    $r = Get-KfwRound $d $Decimals
    if ($r -eq 0) { return '0' }  # never "-0"
    return Format-Float $r
}

function Format-KfwBool($Value) {
    if ($null -eq $Value) { return '' }
    if ($Value) { return 'TRUE' }
    return 'FALSE'
}

function ConvertTo-KfwPyString($Value) {
    # str() as Python has it, for the values a ledger's JSON holds.
    if ($null -eq $Value) { return 'None' }
    if ($Value -is [bool]) { if ($Value) { return 'True' } else { return 'False' } }
    if ($Value -is [double]) { return Format-KfwJsonNumber $Value }
    return [string]$Value
}

function New-KfwRow([Collections.IDictionary]$Values) {
    # The only way a row is made: every column, unknown names refused, the
    # category and the local-time columns derived.
    $row = [Collections.Generic.Dictionary[string, string]]::new(32, [StringComparer]::Ordinal)
    foreach ($c in $script:Columns) { $row[$c] = '' }
    foreach ($k in $Values.Keys) {
        if (-not $script:ColumnSet.Contains([string]$k)) { throw "New-KfwRow: unknown column '$k'" }
        $v = $Values[$k]
        $row[[string]$k] = if ($null -eq $v) { '' } else { [string]$v }
    }
    if (-not $row['EventCategory'] -and $script:CategoryByType.ContainsKey($row['EventType'])) { $row['EventCategory'] = $script:CategoryByType[$row['EventType']] }
    if (-not $row['IsCanonicalReboot']) { $row['IsCanonicalReboot'] = 'FALSE' }
    if (-not $row['IsScriptReboot']) { $row['IsScriptReboot'] = 'FALSE' }
    # Local time always from UTC on this machine, so every row agrees on DST.
    $t = ConvertFrom-UtcText $row['EventTimeUtc']
    if ($null -ne $t) {
        $row['EventTimeLocal'] = ConvertTo-LocalIso $t
        $row['EventDate'] = ConvertTo-LocalDate $t
    }
    $detail = ($row['Detail'] -replace '[\r\n\t]+', ' ').Trim()
    if ($detail.Length -gt 1000) { $detail = $detail.Substring(0, 1000) }
    $row['Detail'] = $detail
    return $row
}

# --- the CSV -------------------------------------------------------------------------------
function Read-KfwFleetCsv([string]$Path) {
    # A file that exists but is not one of ours (someone saved it from Excel,
    # with semicolons) comes back with Error set, and must then be left alone
    # rather than overwritten with a copy missing its history.
    $result = @{ Exists = $false; Error = $null; Rows = [Collections.Generic.List[object]]::new() }
    if (-not $Path -or -not [IO.File]::Exists($Path)) { return $result }
    $result.Exists = $true
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $start = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
        $text = $script:Strict.GetString($bytes, $start, $bytes.Length - $start)
        if (-not $text.Trim()) { return $result }
        $first = ($text -split '\r?\n', 2)[0]
        $header = @($first.Split(',') | ForEach-Object { $_.Trim().Trim('"') })
        if ($header -cnotcontains 'EventId' -or $header -cnotcontains 'EventTimeUtc' -or $header -cnotcontains 'EventType') {
            $result.Error = "Unrecognised layout (first line: '$($first.Substring(0, [Math]::Min(80, $first.Length)))'). Was it saved from Excel?"
            return $result
        }
        $same = ($header -join ',') -ceq ($script:Columns -join ',')
        foreach ($r in [KioskFleetWeb.Csv]::Rows($text)) {
            if (-not ([string]$r['EventId']).Trim()) { continue }
            if ($same) {
                $result.Rows.Add($r)
            } else {
                $v = @{}
                foreach ($k in $r.Keys) { if ($script:ColumnSet.Contains($k)) { $v[$k] = $r[$k] } }
                $result.Rows.Add((New-KfwRow $v))
            }
        }
    } catch {
        $result.Error = $_.Exception.Message
    }
    return $result
}

function Write-KfwAtomic([string]$Path, [byte[]]$Data, [int]$Attempts = 6) {
    $tmp = Join-Path ([IO.Path]::GetDirectoryName($Path)) ('~' + [IO.Path]::GetFileNameWithoutExtension($Path) + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp')
    try {
        [IO.File]::WriteAllBytes($tmp, $Data)
        $last = $null
        for ($i = 1; $i -le $Attempts; $i++) {
            try {
                [IO.File]::Move($tmp, $Path, $true)
                return
            } catch {
                $last = $_.Exception.Message
                Start-Sleep -Milliseconds ([int]($(if ($Attempts -gt 3) { [Math]::Min(2 * $i, 10) } else { 0.2 * $i }) * 1000))
            }
        }
        # Some sync clients refuse a replace outright. Not atomic, but better than not publishing.
        try { [IO.File]::WriteAllBytes($Path, $Data) } catch { throw "could not replace '$Path': $last / $($_.Exception.Message)" }
    } finally {
        if ([IO.File]::Exists($tmp)) { try { [IO.File]::Delete($tmp) } catch { } }
    }
}

function Write-KfwFleetCsv($Rows, [string]$Path) {
    $dir = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if (-not [IO.Directory]::Exists($dir)) { throw "folder does not exist: $dir" }
    $text = [KioskFleetWeb.Csv]::Write($Rows, $script:Columns, $true)
    $body = [Text.UTF8Encoding]::new($false).GetBytes($text)
    $data = [byte[]]::new($body.Length + 3)
    $data[0] = 0xEF; $data[1] = 0xBB; $data[2] = 0xBF
    [Array]::Copy($body, 0, $data, 3, $body.Length)
    Write-KfwAtomic $Path $data
}

function Get-KfwSidecarPath([string]$CsvPath) { [IO.Path]::ChangeExtension($CsvPath, '.status.json') }

function Write-KfwStatusSidecar([string]$CsvPath, $Values) {
    # When the collector last RAN, which the CSV cannot say: it is only
    # rewritten when something changed. Written on every run.
    $path = Get-KfwSidecarPath $CsvPath
    if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($path)))) { return }
    try {
        $body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Values -Depth 30 -Compress))
        Write-KfwAtomic $path ([byte[]](@(0xEF, 0xBB, 0xBF) + $body)) 3
    } catch { }
}

# --- ledger rows and Windows events -----------------------------------------------------------
function ConvertFrom-KfwRebootEvent($Record, [string]$HostName, [string]$ScanId, [string]$Collected) {
    # A Windows System-log record (1074, 6008, 6005) as a row.
    $utc = [datetime]$Record.TimeCreated
    $values = @{
        EventId = "EVT-$HostName-$(ConvertTo-KfwPyString $Record.RecordId)-$($utc.ToString('yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture))"
        EventTimeUtc = ConvertTo-UtcIso $utc; Host = $HostName; Source = 'EventLog'; ScanId = $ScanId; CollectedUtc = $Collected
    }
    $props = @(foreach ($p in @($Record.Properties)) { if ($null -eq $p) { '' } else { ConvertTo-KfwPyString $p } })
    $rid = $Record.Id; $provider = $Record.ProviderName
    if ($rid -eq 1074 -and $provider -ceq 'User32') {
        # "The process %1 has initiated the %5 of computer %2 on behalf of
        #  user %7 for the following reason: %3 ... Comment: %6"
        $get = { param($i) if ($props.Count -gt $i) { $props[$i] } else { '' } }
        $process = & $get 0; $reason = & $get 2; $kindTxt = & $get 4; $comment = & $get 5; $user = & $get 6
        $joined = $props -join ' | '
        $kind = $null; $token = $null
        $m = [regex]::Match($joined, 'MWST-WATCHDOG\s+(LOWWHITE|WHITE|BROWSER)\b(?:\s+id=([0-9a-fA-F]{8}))?', 'IgnoreCase')
        if ($m.Success) {
            $kind = $m.Groups[1].Value.ToUpperInvariant()
            if ($m.Groups[2].Success) { $token = $m.Groups[2].Value.ToLowerInvariant() }
        } elseif ($joined -match 'KPI screen has been below') { $kind = 'LOWWHITE' }
        elseif ($joined -match 'KPI screen has been white') { $kind = 'WHITE' }
        $detail = "Process=$process; User=$user; Type=$kindTxt; Reason=$reason; Comment=$comment"
        if ($kind) {
            $values.EventType = 'REBOOT_SCRIPT'; $values.Severity = 'CRITICAL'; $values.Outcome = 'REBOOT'; $values.RebootTrigger = "WATCHDOG_$kind"
            $values.Detail = if ($token) { "id=$token; $detail" } else { "legacy-agent; $detail" }
        } else {
            $values.EventType = 'REBOOT_EXTERNAL'; $values.Severity = 'WARNING'; $values.Outcome = 'REBOOT'; $values.RebootTrigger = 'EXTERNAL'; $values.Detail = $detail
        }
    } elseif ($rid -eq 6008 -and $provider -ceq 'EventLog') {
        $msg = if ($Record.Message) { $Record.Message } else { 'Previous shutdown was unexpected. ' + ($props -join ' ') }
        $values.EventType = 'REBOOT_UNEXPECTED'; $values.Severity = 'CRITICAL'; $values.Outcome = 'UNEXPECTED'; $values.RebootTrigger = 'UNEXPECTED'; $values.Detail = $msg
    } elseif ($rid -eq 6005 -and $provider -ceq 'EventLog') {
        $values.EventType = 'BOOT'; $values.Severity = 'INFO'; $values.Outcome = 'BOOT'; $values.Detail = 'System booted (event log service started).'
    } else {
        return $null
    }
    return New-KfwRow $values
}

function ConvertFrom-KfwLedgerWinEvent($Row, [string]$HostName, [string]$ScanId, [string]$Collected) {
    # A System-log record the kiosk's agent copied into its ledger verbatim,
    # rebuilt and classified by the same code as one read over the network.
    try { $payload = ConvertFrom-Json ([string]$Row['Detail']) -AsHashtable } catch { return $null }
    if ($payload -isnot [Collections.IDictionary] -or -not $payload['Id']) { return $null }
    $t = ConvertFrom-UtcText $Row['EventTimeUtc']
    if ($null -eq $t) { return $null }
    $props = $payload['Props']
    if ($null -eq $props) { $props = @() } elseif ($props -isnot [Collections.IList]) { $props = @($props) }
    $rid = 0
    try { $rid = [int][Math]::Truncate([double]::Parse([string]$payload['Id'], [Globalization.CultureInfo]::InvariantCulture)) } catch { return $null }
    $record = @{ Id = $rid; ProviderName = [string]$payload['Provider']; RecordId = $payload['RecordId']; TimeCreated = $t
        Properties = $props; Message = [string]$payload['Msg'] }
    return ConvertFrom-KfwRebootEvent $record $HostName $ScanId $Collected
}

function ConvertFrom-KfwLedgerRow($Row, [string]$HostName, [string]$ScanId, [string]$Collected) {
    $etype = ([string]$Row['EventType']).Trim().ToUpperInvariant()
    if ($etype -eq 'WINEVENT') { return ConvertFrom-KfwLedgerWinEvent $Row $HostName $ScanId $Collected }
    $eid = [string]$Row['EventId']
    if (-not $script:GuidRx.IsMatch($eid)) { return $null }
    $t = ConvertFrom-UtcText $Row['EventTimeUtc']
    if ($null -eq $t -or -not $etype) { return $null }
    $detail = [string]$Row['Detail']
    $trigger = ''
    if ($etype -cin 'RESTART_TRIGGERED', 'RESTART_CONFIRMED', 'RESTART_FAILED') {
        $m = [regex]::Match($detail, '^(?:Kind=)?(LOWWHITE|WHITE|BROWSER)\b', 'IgnoreCase')
        $trigger = if ($m.Success) { 'WATCHDOG_' + $m.Groups[1].Value.ToUpperInvariant() } else { 'WATCHDOG' }
    }
    $boot = ConvertFrom-UtcText $Row['BootTimeUtc']
    return New-KfwRow @{
        EventId = $eid.ToLowerInvariant(); EventTimeUtc = ConvertTo-UtcIso $t; Host = $HostName; EventType = $etype
        Severity = ([string]$Row['Severity']).Trim().ToUpperInvariant(); Outcome = ([string]$Row['Outcome']).Trim().ToUpperInvariant()
        RebootTrigger = $trigger; WhitePercent = Format-KfwNumber $Row['WhitePercent'] 2
        StreakChecks = Format-KfwNumber $Row['StreakChecks'] 0; DurationSeconds = Format-KfwNumber $Row['DurationSeconds'] 0
        AgentVersion = ([string]$Row['AgentVersion']).Trim(); BootTimeUtc = if ($null -ne $boot) { ConvertTo-UtcIso $boot } else { '' }
        Source = 'Agent'; ScanId = $ScanId; CollectedUtc = $Collected; Detail = $detail
    }
}

# --- the upgrade cutoff ---------------------------------------------------------------------
function ConvertTo-KfwVersionParts([string]$Text) {
    $t = $Text.Trim()
    if ($t -cnotmatch '^\d+(\.\d+){1,3}$') { return $null }
    return , ([int[]]($t.Split('.')))
}

function Test-KfwTrustedAgent([string]$Version, [string]$TrustedFrom) {
    if (-not ([string]$Version).Trim()) { return $false }
    if (Test-KfwNgVersion $Version) { return $true }
    $v = ConvertTo-KfwVersionParts $Version
    if ($null -eq $v) { return $false }
    $m = ConvertTo-KfwVersionParts $TrustedFrom
    if ($null -eq $m) { return $true }
    $n = [Math]::Max($v.Count, $m.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $a = if ($i -lt $v.Count) { $v[$i] } else { 0 }
        $b = if ($i -lt $m.Count) { $m[$i] } else { 0 }
        if ($a -ne $b) { return $a -gt $b }
    }
    return $true
}

function Get-KfwUpgradeCutoffs($Rows, [string]$TrustedFrom) {
    # The moment each kiosk started running a trusted agent: its earliest
    # AGENT_START at that version. Its rows from before then are dropped -
    # the previous watchdog could reboot a kiosk every couple of minutes.
    $out = @{}
    foreach ($r in $Rows) {
        if ($r['EventType'] -cne 'AGENT_START' -or -not $r['Host']) { continue }
        if (-not (Test-KfwTrustedAgent $r['AgentVersion'] $TrustedFrom)) { continue }
        $h = $r['Host']
        if (-not $out.ContainsKey($h) -or (Test-KfwOrdinalLess $r['EventTimeUtc'] $out[$h])) { $out[$h] = $r['EventTimeUtc'] }
    }
    return $out
}

# --- reboot reconciliation ---------------------------------------------------------------------
function Get-KfwIdToken([string]$Text) {
    $m = [regex]::Match([string]$Text, '\bid=([0-9a-fA-F]{8})\b', 'IgnoreCase')
    if ($m.Success) { return $m.Groups[1].Value.ToLowerInvariant() }
    return $null
}

function Update-KfwRebootFlags($Rows, [datetime]$RecomputeFrom, $NewIds) {
    # Decides, per host, which row is THE row for each physical reboot.
    #
    # The unit is the boot interval: between two consecutive boots (6005)
    # there was exactly one shutdown, however many records describe it.
    # Windows alone writes two 1074s for one restart from the Start menu, and
    # a feature update a burst of them. Each event-log record is assigned to
    # the boot it led to, and within one interval exactly one wins:
    #
    #   REBOOT_SCRIPT      first choice - the watchdog's shutdown.exe call as
    #                      Windows logged it, unless the agent later reported
    #                      that reboot as failed
    #   REBOOT_EXTERNAL    next - update, operator, other process
    #   REBOOT_UNEXPECTED  last - power loss or hard hang; a 6008 is written
    #                      just after the boot that follows, so it belongs to
    #                      the interval ending at that boot
    # Ties go to the latest record. Agent rows:
    #
    #   RESTART_TRIGGERED  counts only when no REBOOT_SCRIPT corroborates it
    #                      (matched by the id= token; by time for the previous
    #                      agent, which had none)
    #   RESTART_CONFIRMED  never counts; it corroborates
    #   RESTART_FAILED     never counts; no reboot happened
    #
    # And the safety net: a BOOT that nothing explains counts, as UNEXPLAINED -
    # provided the previous boot is in the data too.
    #
    # Returns the number of field changes.
    $changed = 0
    $newLower = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($i in $NewIds) { [void]$newLower.Add(([string]$i).ToLowerInvariant()) }
    $byHost = [ordered]@{}
    foreach ($r in $Rows) {
        if ($r['EventCategory'] -cne 'REBOOT' -or -not $r['Host']) { continue }
        $t = ConvertFrom-UtcText $r['EventTimeUtc']
        if ($null -eq $t) { continue }
        if (-not $byHost.Contains($r['Host'])) { $byHost[$r['Host']] = [Collections.Generic.List[object]]::new() }
        $byHost[$r['Host']].Add(@($r, $t))
    }
    $priority = @{ REBOOT_SCRIPT = 1; REBOOT_EXTERNAL = 2; REBOOT_UNEXPECTED = 3 }
    foreach ($list in $byHost.Values) {
        $items = Get-KfwSorted $list { param($x) $x[1].Ticks.ToString('D20') }

        $failed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($x in $items) {
            if ($x[0]['EventType'] -ceq 'RESTART_FAILED') {
                $m = [regex]::Match($x[0]['Detail'], 'TriggerEventId=([0-9a-fA-F-]{36})', 'IgnoreCase')
                if ($m.Success) { [void]$failed.Add($m.Groups[1].Value.ToLowerInvariant()) }
            }
        }
        $boots = @(foreach ($x in $items) { if ($x[0]['EventType'] -ceq 'BOOT') { $x[1] } })
        $decision = @{}
        $winners = [ordered]@{}
        $explained = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

        foreach ($x in $items) {
            $r = $x[0]; $t = $x[1]
            $etype = $r['EventType']
            if (-not $priority.ContainsKey($etype)) { continue }
            if ($etype -ceq 'REBOOT_SCRIPT') {
                $token = Get-KfwIdToken $r['Detail']
                if ($token -and @($failed | Where-Object { $_.StartsWith($token) }).Count) {
                    $decision[$r['EventId']] = $false
                    continue
                }
            }
            $key = $null
            if ($etype -ceq 'REBOOT_UNEXPECTED') {
                $near = @($boots | Where-Object { [Math]::Abs(($_ - $t).TotalSeconds) -le 1800 })
                if ($near.Count) {
                    $best = $near[0]
                    foreach ($b in $near) { if ([Math]::Abs(($b - $t).TotalSeconds) -lt [Math]::Abs(($best - $t).TotalSeconds)) { $best = $b } }
                    $key = "b$($best.Ticks)"
                }
            }
            if ($null -eq $key) {
                $after = @($boots | Where-Object { $_ -gt $t })
                $key = if ($after.Count) { "b$($after[0].Ticks)" } else { 'open' }
            }
            [void]$explained.Add($key)
            $decision[$r['EventId']] = $false
            $cur = $winners[$key]
            if ($null -eq $cur -or $priority[$etype] -lt $priority[$cur[0]['EventType']] -or
                ($priority[$etype] -eq $priority[$cur[0]['EventType']] -and $t -ge $cur[1])) {
                $winners[$key] = @($r, $t)
            }
        }
        foreach ($w in $winners.Values) { $decision[$w[0]['EventId']] = $true }

        $scriptEvents = @($items | Where-Object { $_[0]['EventType'] -ceq 'REBOOT_SCRIPT' })
        $prevBoot = $null
        foreach ($x in $items) {
            $r = $x[0]; $t = $x[1]
            $recompute = $t -ge $RecomputeFrom -or $newLower.Contains($r['EventId'].ToLowerInvariant()) -or -not $r['IsCanonicalReboot']
            if ($recompute) {
                $etype = $r['EventType']
                $trigger = $r['RebootTrigger']
                $canonical = $false
                if ($decision.ContainsKey($r['EventId'])) {
                    $canonical = $decision[$r['EventId']]
                } elseif ($etype -ceq 'RESTART_TRIGGERED') {
                    $rid = $r['EventId'].ToLowerInvariant()
                    if ($failed.Contains($rid)) {
                        $canonical = $false
                    } else {
                        $corroborated = $false
                        foreach ($se in $scriptEvents) {
                            $token = Get-KfwIdToken $se[0]['Detail']
                            if ($token) {
                                if ($rid.StartsWith($token)) { $corroborated = $true; break }
                            } elseif ([Math]::Abs(($se[1] - $t).TotalSeconds) -le 900) {
                                $corroborated = $true; break
                            }
                        }
                        $canonical = -not $corroborated
                    }
                } elseif ($etype -ceq 'BOOT') {
                    $isExplained = $explained.Contains("b$($t.Ticks)")
                    if (-not $isExplained) {
                        foreach ($y in $items) {
                            if ($y[0]['EventType'] -cne 'RESTART_TRIGGERED' -or $failed.Contains($y[0]['EventId'].ToLowerInvariant())) { continue }
                            if ($y[1] -le $t -and ($null -eq $prevBoot -or $y[1] -gt $prevBoot)) { $isExplained = $true; break }
                        }
                    }
                    $canonical = (-not $isExplained) -and $null -ne $prevBoot
                    $trigger = if ($canonical) { 'UNEXPLAINED' } else { '' }
                }
                $canonText = if ($canonical) { 'TRUE' } else { 'FALSE' }
                $scriptText = if ($canonical -and $trigger.ToUpperInvariant().StartsWith('WATCHDOG')) { 'TRUE' } else { 'FALSE' }
                if ($r['IsCanonicalReboot'] -cne $canonText) { $r['IsCanonicalReboot'] = $canonText; $changed++ }
                if ($r['IsScriptReboot'] -cne $scriptText) { $r['IsScriptReboot'] = $scriptText; $changed++ }
                if ($r['RebootTrigger'] -cne $trigger) { $r['RebootTrigger'] = $trigger; $changed++ }
            }
            if ($r['EventType'] -ceq 'BOOT') { $prevBoot = $t }
        }
    }
    return $changed
}

# --- host status ---------------------------------------------------------------------------------
function New-KfwObs {
    @{
        Reachable = $false; Method = $null; ShareOk = $null; LogFound = $null; LedgerFound = $null; LedgerFiles = 0
        LogAgeMinutes = $null; EventLogOk = $null; LoopGuard = $false; WinEventRows = 0; PreUpgrade = 0; AgentVersion = ''
        LedgerBoot = $null; EventBoot = $null; NewEvents = 0; IsPbi = $false; IsWeb = $false; WatchdogFound = $false
        Pbi = $null; Web = $null; Ng = $null; Notes = [Collections.Generic.List[string]]::new()
    }
}

function Get-KfwHostStatus($Kiosk, $Obs, [int]$StaleMinutes) {
    # One status per host per scan, worst condition first:
    #
    #   OFFLINE               no ping and no SMB                   CRITICAL
    #   NO_ACCESS             reachable, share not readable        WARNING
    #   NO_AGENT              watchdog expected, no trace of it    CRITICAL
    #   STALE                 mwst.log not written recently        CRITICAL
    #   LOOP_GUARD            has stopped restarting a screen      CRITICAL
    #   (a launcher's status)
    #   AGENT_OUTDATED        running, but no ledger (old agent)   WARNING
    #   EVENTLOG_UNAVAILABLE  one reboot witness missing           WARNING
    #   OK
    if (-not $Obs.Reachable) { return 'OFFLINE', 'CRITICAL' }
    $launchers = @($Obs.Pbi, $Obs.Web, $Obs.Ng | Where-Object { $_ -and $_.Status })
    $worst = $null
    foreach ($l in $launchers) {
        $rank = if ($script:StateRank.ContainsKey([string]$l.Status)) { $script:StateRank[[string]$l.Status] } else { 50 }
        if ($null -eq $worst -or $rank -lt $worst[2]) { $worst = @($l.Status, $l.Severity, $rank) }
    }
    if ($Kiosk.RunsWatchdog -or $Obs.WatchdogFound) {
        if ($Obs.ShareOk -ne $true) { return 'NO_ACCESS', 'WARNING' }
        if (-not $Obs.LogFound -and -not $Obs.LedgerFound) { return 'NO_AGENT', 'CRITICAL' }
        if ($null -eq $Obs.LogAgeMinutes -or $Obs.LogAgeMinutes -gt $StaleMinutes) { return 'STALE', 'CRITICAL' }
        if ($Obs.LoopGuard) { return 'LOOP_GUARD', 'CRITICAL' }
        if ($worst -and $worst[0] -ne 'OK') { return $worst[0], $worst[1] }
        if (-not $Obs.LedgerFound) { return 'AGENT_OUTDATED', 'WARNING' }
    } elseif ($Obs.IsPbi -or $Obs.IsWeb -or $launchers.Count) {
        if ($Obs.ShareOk -eq $false) { return 'NO_ACCESS', 'WARNING' }
        if ($worst) { return $worst[0], $worst[1] }
    }
    if ($Obs.EventLogOk -eq $false) { return 'EVENTLOG_UNAVAILABLE', 'WARNING' }
    return 'OK', 'INFO'
}

function Get-KfwStatusSignature($Row) {
    # What counts as "the status changed": not the values that move on every scan.
    $m = [regex]::Match($Row['Detail'], 'eventlog=(ok|FAIL)', 'IgnoreCase')
    $ev = if ($m.Success) { $m.Groups[1].Value } else { '' }
    return @($Row['Outcome'], $Row['Reachable'], $Row['WatchdogRunning'], $Row['AgentVersion'], $Row['BootTimeUtc'], $ev) -join '|'
}

function Test-KfwStatusRowNeeded($Row, $Previous, [datetime]$Now, [int]$KeepaliveHours) {
    if (-not $Previous) { return $true }
    $prev = ConvertFrom-UtcText $Previous['EventTimeUtc']
    $fresh = $null -ne $prev -and ($Now - $prev).TotalHours -lt $KeepaliveHours
    return -not ($fresh -and (Get-KfwStatusSignature $Previous) -ceq (Get-KfwStatusSignature $Row))
}

# --- reading the kiosks, several at once ------------------------------------------------------------
function New-KfwFetch([string]$HostName) {
    [hashtable]::Synchronized(@{
        Host = $HostName; Reachable = $false; Method = $null; ShareOk = $null; LogFound = $null; LogAgeMinutes = $null
        Ledger = $null; Ng = $null; Pbi = $null; Web = $null; PbiShareOk = $null
        Notes = [Collections.ArrayList]::Synchronized([Collections.ArrayList]::new()); Fatal = $null; TimedOut = $false
        Started = $null; Seconds = 0.0
    })
}

function Get-KfwIoError($Exception) {
    # The file-system error inside what PowerShell wrapped it in, or $null.
    $e = $Exception
    while ($e) {
        if ($e -is [IO.IOException] -or $e -is [UnauthorizedAccessException]) { return $e }
        $e = $e.InnerException
    }
    return $null
}

function Invoke-KfwFetchKiosk($F, $Kiosk, $S, [datetime]$Now) {
    # Only reading happens here; what the rows mean is decided later, in list order.
    $F.Started = Get-KfwMono
    try {
        $h = $F.Host
        $reach = Test-KfwReachable $h $S
        $F.Reachable = $reach.Ok; $F.Method = $reach.Method
        if (-not $reach.Ok) {
            [void]$F.Notes.Add($(if ($reach.Error) { $reach.Error } else { 'unreachable' }))
            return
        }
        $folder = Get-KfwDocs $S $h
        try {
            [void](Connect-KfwKiosk $S $h)
            $F.PbiShareOk = Test-KfwDir $folder
            if ($F.PbiShareOk) {
                $F.Pbi = Get-KfwPbiObservation $folder $Now $S.LauncherStaleMinutes $h
                if ($F.Pbi.Error) { [void]$F.Notes.Add("PBI Launcher: $($F.Pbi.Error)") }
                $F.Web = Get-KfwWebObservation $folder $Now $S.LauncherStaleMinutes $h
                if ($F.Web.Error) { [void]$F.Notes.Add("Web Launcher: $($F.Web.Error)") }
            } elseif ((Test-KfwPowerBi $Kiosk.Type) -or (Test-KfwWeb $Kiosk.Type)) {
                [void]$F.Notes.Add("Cannot open $folder")
            }
            # Mach2 Launcher NG, where installed - it is the watchdog as well,
            # so its ledger is read even on a kiosk the list calls Power BI.
            if (Test-KfwDir $folder) {
                $F.Ng = Get-KfwNgObservation $folder $Now $S.LauncherStaleMinutes
                if ($F.Ng.Error) { [void]$F.Notes.Add("Launcher: $($F.Ng.Error)") }
            }
            if ($Kiosk.RunsWatchdog -or ($F.Ng -and $F.Ng.Installed)) {
                $F.ShareOk = Test-KfwDir $folder
                if (-not $F.ShareOk) {
                    [void]$F.Notes.Add("Cannot open $folder")
                } else {
                    $mt = Get-KfwMTime (Join-KfwPath $folder 'mwst.log')
                    $F.LogFound = $null -ne $mt
                    if ($null -ne $mt) { $F.LogAgeMinutes = ($Now - $mt).TotalMinutes }
                    $F.Ledger = Read-KfwAgentLedger $folder
                    foreach ($e in $F.Ledger.Errors) { [void]$F.Notes.Add($e) }
                }
            }
        } catch {
            $io = Get-KfwIoError $_.Exception
            if (-not $io) { throw }
            $F.ShareOk = $false
            $F.PbiShareOk = $false
            [void]$F.Notes.Add("Share: $($io.Message)")
        }
    } catch {
        # One kiosk must never stop a scan.
        $F.Fatal = $_.Exception.Message
    } finally {
        $F.Seconds = Get-KfwRound ((Get-KfwMono) - $(if ($null -ne $F.Started) { $F.Started } else { Get-KfwMono })) 1
    }
}

function Invoke-KfwFetchAll($Kiosks, $S, [datetime]$Now, [scriptblock]$Progress) {
    # A kiosk that is given up on still reports how far it got. A thread that
    # hangs in a share call is left behind, not waited for: the scan is a
    # process of its own, which ends when it has written its files.
    $parallel = [Math]::Max(1, [int]$S.ParallelHosts)
    $limit = [int]$S.HostTimeoutSeconds
    $results = [ordered]@{}
    $work = [Collections.Generic.List[object]]::new()
    $pool = New-KfwRunspacePool $parallel
    try {
        foreach ($k in $Kiosks) {
            $f = New-KfwFetch $k.Host.ToUpperInvariant()
            $results[$f.Host] = $f
            $work.Add(@{ F = $f; W = (Invoke-KfwInBackground $pool 'Invoke-KfwFetchKiosk' @($f, $k, $S, $Now)) })
        }
        $hardStop = (Get-KfwMono) + $limit * ([Math]::Ceiling($work.Count / $parallel) + 1)
        $pending = [Collections.Generic.List[object]]::new($work)
        $done = 0
        while ($pending.Count) {
            Start-Sleep -Milliseconds 100
            $outOfTime = (Get-KfwMono) -gt $hardStop
            $still = [Collections.Generic.List[object]]::new()
            foreach ($x in $pending) {
                $f = $x.F
                $alive = -not $x.W.Handle.IsCompleted
                $late = $null -ne $f.Started -and ((Get-KfwMono) - $f.Started) -gt $limit
                if ($alive -and -not $late -and -not $outOfTime) { $still.Add($x); continue }
                if ($alive) {
                    [void]$f.Notes.Add($(if ($null -ne $f.Started) { "Gave up reading this kiosk after ${limit}s" } else { 'Never got its turn: the scan ran out of time' }))
                    $f.TimedOut = $true
                    if ($null -ne $f.Started -and -not $f.Seconds) { $f.Seconds = Get-KfwRound ((Get-KfwMono) - $f.Started) 1 }
                    try { [void]$x.W.PS.BeginStop($null, $null) } catch { }
                } else {
                    [void](Complete-KfwBackground $x.W)
                }
                $done++
                if ($Progress) { & $Progress 'scanning' $done $work.Count $f.Host }
            }
            $pending = $still
        }
    } finally {
        if (-not @($work | Where-Object { $_.F.TimedOut }).Count) { try { $pool.Close(); $pool.Dispose() } catch { } }
    }
    return $results
}

# --- one run -----------------------------------------------------------------------------------------
$script:ScanLogPath = $null

function Write-KfwScanLog([string]$Message, [string]$Level = 'INFO') {
    $line = "[$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture))] [$Level] $Message"
    try {
        $p = $script:ScanLogPath
        if ($p) {
            if ([IO.File]::Exists($p) -and ([IO.FileInfo]::new($p)).Length -ge 5MB) { [IO.File]::Move($p, "$p.1", $true) }
            [IO.File]::AppendAllText($p, $line + "`n")
        }
    } catch { }
    [Console]::Out.WriteLine($line)
}

function Get-KfwRunnerName { "$([Environment]::UserName)@$([Net.Dns]::GetHostName())" }

function Invoke-KfwScan {
    # One scan of the fleet. Returns the exit code: 0, or 1 when something
    # could not be read or written.
    [CmdletBinding()]
    param($Settings, [string]$ProgressFile, [switch]$DryRun,
        # The scan's time, for the tests; the clock otherwise.
        $Now = $null)
    if (-not $Settings) { $Settings = Get-KfwSettings }
    Initialize-KfwDirs $Settings
    $script:ScanLogPath = Join-Path (Get-KfwLogDir $Settings) 'collector.log'
    $progress = {
        param($Phase, $Index, $Total, $HostName = '')
        if (-not $ProgressFile) { return }
        try { [IO.File]::WriteAllText($ProgressFile, (ConvertTo-Json -Compress ([ordered]@{ Pid = $PID; Phase = $Phase; Index = $Index; Total = $Total; Host = $HostName }))) } catch { }
    }.GetNewClosure()

    # One collector at a time; the lock goes with the process if it dies.
    $lockPath = Join-Path $Settings.DataDir 'collector.lock'
    try {
        $lock = [IO.FileStream]::new($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        if (-not $IsWindows) { $lock.Lock(0, 1) }
    } catch {
        Write-KfwScanLog 'Another collector run is in progress; exiting without scanning.' 'WARN'
        return 0
    }
    try {
        return (Invoke-KfwScanCore $Settings $progress $DryRun $Now)
    } catch {
        Write-KfwScanLog "Scan failed: $($_.Exception.Message)" 'ERROR'
        return 1
    } finally {
        $lock.Dispose()
    }
}

function Invoke-KfwScanCore($Settings, [scriptblock]$Progress, [bool]$DryRun, $Now = $null) {
    $S = $Settings
    $exitCode = 0
    $start = Get-KfwMono
    $u = if ($Now) { ([datetime]$Now).ToUniversalTime() } else { [datetime]::UtcNow }
    $now = [datetime]::new($u.Year, $u.Month, $u.Day, $u.Hour, $u.Minute, $u.Second, [DateTimeKind]::Utc)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $scanId = $now.ToString("yyyyMMdd'T'HHmmss'Z'", $inv)
    $collected = ConvertTo-UtcIso $now
    $retentionCutoff = ConvertTo-UtcIso $now.AddDays(-$S.RetentionDays)
    $runCutoff = ConvertTo-UtcIso $now.AddDays(-$S.RunRowRetentionDays)
    $runner = Get-KfwRunnerName

    Write-KfwScanLog "Scan $scanId starting (collector v$($script:CollectorVersion), run by $runner$(if ($DryRun) { ', DRY RUN' }))."
    if ((Test-KfwUsesUnc $S) -and -not (Test-KfwHasCredential $S)) {
        Write-KfwScanLog "No share account: kiosks are opened as $([Environment]::UserDomainName)\$([Environment]::UserName)."
    }

    $listPath = Resolve-KfwKioskList $S
    if (-not $listPath) { throw 'No kiosk list: upload one in Settings, or set KFW_KIOSK_LIST.' }
    $imported = Import-KfwKioskList $listPath $S.KioskListSheet $S.IncludeAllHosts
    $kiosks = $imported.Kiosks; $statsList = $imported.Stats
    if (-not $kiosks.Count) { throw "Kiosk list '$listPath' yielded no hosts." }
    $watchdogCount = @($kiosks | Where-Object { $_.RunsWatchdog }).Count
    Write-KfwScanLog "$($kiosks.Count) host(s) from ${listPath}: $watchdogCount run the watchdog, $($kiosks.Count - $watchdogCount) ping-only."
    if ($statsList.Inactive) { Write-KfwScanLog "$($statsList.Inactive) kiosk(s) skipped: ACTIVE is set to something other than Y in the list." 'WARN' }

    $output = if ($S.PublishCsv) { $S.PublishCsv } else { Get-KfwLocalCsv $S }
    $local = Get-KfwLocalCsv $S
    $samePath = [IO.Path]::GetFullPath($output) -eq [IO.Path]::GetFullPath($local)

    $known = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $allRows = [Collections.Generic.List[object]]::new()
    $dirty = $false

    $primary = Read-KfwFleetCsv $output
    $primaryWritable = -not $primary.Error
    if ($primary.Error) {
        Write-KfwScanLog "Published CSV could not be read and will NOT be overwritten this run: $($primary.Error)" 'ERROR'
        $exitCode = 1
    }
    foreach ($r in $primary.Rows) { if ($known.Add($r['EventId'].ToLowerInvariant())) { $allRows.Add($r) } }

    $localWritable = $true
    if (-not $samePath) {
        $loc = Read-KfwFleetCsv $local
        if ($loc.Error) {
            Write-KfwScanLog "Local CSV could not be read and will NOT be overwritten this run: $($loc.Error)" 'ERROR'
            $localWritable = $false
        }
        $restored = 0
        foreach ($r in $loc.Rows) { if ($known.Add($r['EventId'].ToLowerInvariant())) { $allRows.Add($r); $restored++ } }
        if ($restored) {
            Write-KfwScanLog "Merged $restored row(s) from the local copy that were missing from the published CSV."
            $dirty = $true
        }
        if (-not $primary.Exists -and $loc.Exists) { $dirty = $true }
    }

    $lastStatus = @{}
    $lastRunIso = $null
    foreach ($r in $allRows) {
        if ($r['EventType'] -ceq 'HOST_STATUS') {
            $prev = $lastStatus[$r['Host']]
            if ($null -eq $prev -or [string]::CompareOrdinal($r['EventTimeUtc'], $prev['EventTimeUtc']) -gt 0) { $lastStatus[$r['Host']] = $r }
        } elseif ($r['EventType'] -ceq 'COLLECTOR_RUN') {
            if ($null -eq $lastRunIso -or [string]::CompareOrdinal($r['EventTimeUtc'], $lastRunIso) -gt 0) { $lastRunIso = $r['EventTimeUtc'] }
        }
    }

    Write-KfwScanLog "Loaded $($allRows.Count) existing row(s). Scanning $($kiosks.Count) kiosk(s), $($S.ParallelHosts) at a time..."

    $newIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $newRows = [Collections.Generic.List[object]]::new()
    $hostResults = [Collections.Generic.List[object]]::new()
    $pbiDetails = [ordered]@{}; $webDetails = [ordered]@{}; $ngDetails = [ordered]@{}
    $stats = @{ Reachable = 0; LedgersRead = 0; EventLogsRead = 0; HostErrors = 0; InvalidLedgerRows = 0 }

    $readStart = Get-KfwMono
    $fetched = Invoke-KfwFetchAll $kiosks $S $now $Progress
    $slow = Get-KfwSorted @($fetched.Values | Where-Object { $_.Seconds -ge 10 }) { param($f) (100000 - $f.Seconds).ToString('000000.0', $inv) }
    $slowText = if ($slow.Count) { '; slowest ' + ((@($slow) | Select-Object -First 3 | ForEach-Object { "$($_.Host) $($_.Seconds.ToString('F0', $inv))s" }) -join ', ') } else { '' }
    Write-KfwScanLog "Read $($kiosks.Count) kiosk(s) in $(((Get-KfwMono) - $readStart).ToString('F0', $inv))s$slowText."

    $isKnown = { param($eid) $known.Contains($eid.ToLowerInvariant()) -or $newIds.Contains($eid.ToLowerInvariant()) }

    foreach ($k in $kiosks) {
        $h = $k.Host.ToUpperInvariant()
        $fetch = $fetched[$h]
        $obs = New-KfwObs
        $obs.IsPbi = Test-KfwPowerBi $k.Type; $obs.IsWeb = Test-KfwWeb $k.Type
        try {
            $obs.Reachable = $fetch.Reachable; $obs.Method = $fetch.Method
            if ($obs.Reachable) { $stats.Reachable++ }
            foreach ($n in $fetch.Notes) { $obs.Notes.Add($n) }
            if ($fetch.Fatal) {
                $stats.HostErrors++
                $obs.Notes.Add("Scan error: $($fetch.Fatal)")
                Write-KfwScanLog "${h}: $($fetch.Fatal)" 'WARN'
            } elseif ($fetch.TimedOut) {
                $stats.HostErrors++
                Write-KfwScanLog "${h}: gave up reading it after $($S.HostTimeoutSeconds)s" 'WARN'
            }
            if ($fetch.Ng -and $fetch.Ng.Installed) {
                $obs.Ng = $fetch.Ng
                $obs.WatchdogFound = $true
                $ngDetails[$h] = Get-KfwSidecarEntry $fetch.Ng
            }
            if ($obs.Reachable -and ($k.RunsWatchdog -or $obs.WatchdogFound)) {
                $obs.ShareOk = $fetch.ShareOk
                if ($obs.ShareOk) {
                    $obs.LogFound = $fetch.LogFound
                    $obs.LogAgeMinutes = $fetch.LogAgeMinutes
                    $latest = $null
                    if ($fetch.Ledger) {
                        $ledger = $fetch.Ledger
                        $obs.LedgerFiles = $ledger.Files
                        $obs.LedgerFound = $ledger.Files -gt 0
                        if ($obs.LedgerFound) { $stats.LedgersRead++ }
                        $converted = [Collections.Generic.List[object]]::new()
                        $guard = $null
                        foreach ($lr in $ledger.Rows) {
                            $row = ConvertFrom-KfwLedgerRow $lr $h $scanId $collected
                            if (-not $row) { $stats.InvalidLedgerRows++; continue }
                            # The loop guard holds if its last row (in file order) says so.
                            if ($row['EventType'].StartsWith('LOOP_GUARD_')) { $guard = $row }
                            if ($row['Source'] -ceq 'EventLog') { $obs.WinEventRows++ }
                            if ($row['EventType'] -ceq 'BOOT') {
                                $bt = ConvertFrom-UtcText $row['EventTimeUtc']
                                if ($null -ne $bt -and ($null -eq $obs.EventBoot -or $bt -gt $obs.EventBoot)) { $obs.EventBoot = $bt }
                            }
                            if ($row['BootTimeUtc'] -and ($null -eq $latest -or [string]::CompareOrdinal($row['EventTimeUtc'], $latest['EventTimeUtc']) -ge 0)) { $latest = $row }
                            $converted.Add($row)
                        }
                        $cutoff = $null
                        if (-not $S.KeepPreUpgradeHistory) { $cutoff = (Get-KfwUpgradeCutoffs $converted $S.TrustedFromAgentVersion)[$h] }
                        foreach ($row in $converted) {
                            if ($cutoff -and (Test-KfwOrdinalLess $row['EventTimeUtc'] $cutoff)) { $obs.PreUpgrade++; continue }
                            if (& $isKnown $row['EventId']) { continue }
                            if (Test-KfwOrdinalLess $row['EventTimeUtc'] $retentionCutoff) { continue }
                            [void]$newIds.Add($row['EventId'].ToLowerInvariant())
                            $newRows.Add($row)
                            $obs.NewEvents++
                        }
                        $obs.LoopGuard = [bool]($guard -and $guard['EventType'] -ceq 'LOOP_GUARD_ENGAGED')
                    }
                    if ($latest) {
                        $obs.AgentVersion = $latest['AgentVersion']
                        $obs.LedgerBoot = ConvertFrom-UtcText $latest['BootTimeUtc']
                    } elseif ($obs.LogFound) {
                        $obs.AgentVersion = 'legacy'
                    }
                }
            }
            if ($obs.Reachable) {
                if ($null -eq $obs.ShareOk -and ($obs.IsPbi -or $obs.IsWeb)) { $obs.ShareOk = $fetch.PbiShareOk }
                if ($fetch.PbiShareOk -and $fetch.Pbi -and ($obs.IsPbi -or $fetch.Pbi.Installed -or @($fetch.Pbi.Screens).Count)) {
                    $obs.Pbi = $fetch.Pbi
                    $pbiDetails[$h] = Get-KfwSidecarEntry $fetch.Pbi
                }
                if ($fetch.PbiShareOk -and $fetch.Web -and ($obs.IsWeb -or $fetch.Web.Installed -or @($fetch.Web.Screens).Count)) {
                    $obs.Web = $fetch.Web
                    $webDetails[$h] = Get-KfwSidecarEntry $fetch.Web
                }
            }
        } catch {
            $stats.HostErrors++
            $obs.Notes.Add("Scan error: $($_.Exception.Message)")
            Write-KfwScanLog "${h}: $($_.Exception.Message)" 'WARN'
        }

        # The ledger's boot time is authoritative once the agent has run since
        # the latest boot; if it has not, the System log's newer boot wins.
        $boot = $obs.LedgerBoot
        if ($null -ne $obs.EventBoot -and ($null -eq $boot -or $obs.EventBoot -gt $boot.AddMinutes(10))) { $boot = $obs.EventBoot }
        if ($null -eq $boot -and $obs.Pbi -and $null -ne $obs.Pbi.PcBootUtc) { $boot = $obs.Pbi.PcBootUtc }
        if ($null -eq $boot -and $obs.Web -and $null -ne $obs.Web.PcBootUtc) { $boot = $obs.Web.PcBootUtc }
        if (-not $obs.WatchdogFound -or -not $obs.AgentVersion) {
            if ($obs.Pbi -and $obs.Pbi.LauncherVersion) { $obs.AgentVersion = "pbi-$($obs.Pbi.LauncherVersion)" }
            elseif ($obs.Web -and $obs.Web.LauncherVersion) { $obs.AgentVersion = "web-$($obs.Web.LauncherVersion)" }
        }

        $watchdogRunning = $null
        if (($k.RunsWatchdog -or $obs.WatchdogFound) -and $obs.Reachable -and $obs.ShareOk) {
            $watchdogRunning = $null -ne $obs.LogAgeMinutes -and $obs.LogAgeMinutes -le $S.AgentStaleMinutes
        }
        $status, $severity = Get-KfwHostStatus $k $obs $S.AgentStaleMinutes

        $checks = [Collections.Generic.List[string]]::new()
        $checks.Add('reach=' + $(if ($obs.Reachable) { $obs.Method } else { 'FAIL' }))
        if ($null -ne $obs.ShareOk) { $checks.Add('share=' + $(if ($obs.ShareOk) { 'ok' } else { 'FAIL' })) }
        if ($null -ne $obs.LogFound) { $checks.Add('log=' + $(if ($obs.LogFound) { (Format-KfwNumber $obs.LogAgeMinutes 1) + 'm' } else { 'missing' })) }
        if ($null -ne $obs.LedgerFound) { $checks.Add('ledger=' + $(if ($obs.LedgerFound) { "ok($($obs.LedgerFiles))" } else { 'missing' })) }
        if ($obs.LoopGuard) { $checks.Add('loopguard=HOLD') }
        if ($null -ne $obs.EventLogOk) { $checks.Add('eventlog=' + $(if ($obs.EventLogOk) { 'ok' } else { 'FAIL' })) }
        elseif (($k.RunsWatchdog -or $obs.WatchdogFound) -and $obs.ShareOk) { $checks.Add("eventlog=agent($($obs.WinEventRows))") }
        foreach ($l in $obs.Pbi, $obs.Web, $obs.Ng) { if ($l -and $l.Summary) { $checks.Add($l.Summary) } }
        $checks.Add("new=$($obs.NewEvents)")
        $detail = $checks -join ' '
        if ($obs.Notes.Count) { $detail += ' | ' + ($obs.Notes -join ' | ') }

        $statusRow = New-KfwRow @{
            EventId = "STAT-$h-$scanId"; EventTimeUtc = $collected; Host = $h; EventType = 'HOST_STATUS'
            Severity = $severity; Outcome = $status; Reachable = Format-KfwBool $obs.Reachable
            WatchdogRunning = Format-KfwBool $watchdogRunning; MinutesSinceLastLog = Format-KfwNumber $obs.LogAgeMinutes 1
            AgentVersion = $obs.AgentVersion; BootTimeUtc = if ($null -ne $boot) { ConvertTo-UtcIso $boot } else { '' }
            UptimeHours = if ($null -ne $boot) { Format-KfwNumber ($now - $boot).TotalHours 1 } else { '' }
            Source = 'Collector'; ScanId = $scanId; CollectedUtc = $collected; Detail = $detail
        }
        # (A second scan within the same second would reuse the EventId: skipped.)
        if (-not (& $isKnown $statusRow['EventId']) -and (Test-KfwStatusRowNeeded $statusRow $lastStatus[$h] $now $S.KeepaliveHours)) {
            [void]$newIds.Add($statusRow['EventId'].ToLowerInvariant())
            $newRows.Add($statusRow)
        }

        $insts = [Collections.Generic.List[object]]::new()
        foreach ($l in $obs.Pbi, $obs.Web, $obs.Ng) { if ($l) { foreach ($i in $l.Instances) { $insts.Add($i) } } }
        $launcherTxt = ((Get-KfwSorted $insts { param($i) $i.Screen }) | ForEach-Object { "$($_.Screen):$($_.State)" }) -join ','
        $hostResults.Add([ordered]@{
            Host = $h; Type = $k.Type; Location = $k.Location; Status = $status
            Watchdog = if ($null -eq $watchdogRunning) { '' } elseif ($watchdogRunning) { 'running' } else { 'DEAD' }
            LogAgeMin = Format-KfwNumber $obs.LogAgeMinutes 1; Agent = $obs.AgentVersion; Launcher = $launcherTxt
            NewEvents = $obs.NewEvents; PreUpgrade = $obs.PreUpgrade; Notes = $obs.Notes -join ' | '
        })
    }
    & $Progress 'saving' $kiosks.Count $kiosks.Count

    # Kiosks deliberately not scanned get a status of their own, so their
    # last real status does not stay on the dashboard for ever.
    foreach ($dead in $statsList.InactiveRows) {
        $dh = $dead.Host.ToUpperInvariant()
        $row = New-KfwRow @{
            EventId = "STAT-$dh-$scanId"; EventTimeUtc = $collected; Host = $dh; Location = $dead.Location
            KioskType = $dead.Type; RestartGroup = $dead.RestartGroup; EventType = 'HOST_STATUS'; Severity = 'INFO'
            Outcome = 'INACTIVE'; Source = 'Collector'; ScanId = $scanId; CollectedUtc = $collected
            Detail = "not scanned: ACTIVE is '$($dead.Active)' in the kiosk list"
        }
        if (-not (& $isKnown $row['EventId']) -and (Test-KfwStatusRowNeeded $row $lastStatus[$dh] $now $S.KeepaliveHours)) {
            [void]$newIds.Add($row['EventId'].ToLowerInvariant())
            $newRows.Add($row)
        }
    }

    if ($stats.InvalidLedgerRows) { Write-KfwScanLog "$($stats.InvalidLedgerRows) ledger row(s) were malformed and skipped." 'WARN' }

    # --- merge ---
    foreach ($r in $newRows) { [void]$known.Add($r['EventId'].ToLowerInvariant()); $allRows.Add($r) }
    $eventRows = @($newRows | Where-Object { $_['EventType'] -cne 'HOST_STATUS' }).Count
    if ($newRows.Count) { $dirty = $true }

    # Kiosk attributes follow the current list across their whole history.
    $meta = @{}
    foreach ($k in $kiosks) { $meta[$k.Host.ToUpperInvariant()] = @($k.Location, $k.Type, $k.RestartGroup) }
    foreach ($dead in $statsList.InactiveRows) { if (-not $meta.ContainsKey($dead.Host.ToUpperInvariant())) { $meta[$dead.Host.ToUpperInvariant()] = @($dead.Location, $dead.Type, $dead.RestartGroup) } }
    $metaChanges = 0
    foreach ($r in $allRows) {
        if (-not $r['Host']) { continue }
        $m = $meta[$r['Host']]
        if (-not $m) { continue }
        $cols = 'Location', 'KioskType', 'RestartGroup'
        for ($i = 0; $i -lt 3; $i++) {
            $val = [string]$m[$i]
            if ($r[$cols[$i]] -cne $val) { $r[$cols[$i]] = $val; $metaChanges++ }
        }
    }
    if ($metaChanges) { $dirty = $true }

    $flagChanges = Update-KfwRebootFlags $allRows $now.AddDays(-$S.ReconcileDays) $newIds
    if ($flagChanges) { $dirty = $true }

    # --- retention ---
    $cutoffs = if ($S.KeepPreUpgradeHistory) { @{} } else { Get-KfwUpgradeCutoffs $allRows $S.TrustedFromAgentVersion }
    $kept = [Collections.Generic.List[object]]::new()
    $preUpgradePruned = 0
    foreach ($r in $allRows) {
        $t = $r['EventTimeUtc']
        if ($t) {
            if (Test-KfwOrdinalLess $t $retentionCutoff) { continue }
            if ($r['EventType'] -ceq 'COLLECTOR_RUN' -and (Test-KfwOrdinalLess $t $runCutoff)) { continue }
            if ($r['Host'] -and $cutoffs.ContainsKey($r['Host']) -and (Test-KfwOrdinalLess $t $cutoffs[$r['Host']])) { $preUpgradePruned++; continue }
        }
        $kept.Add($r)
    }
    $pruned = $allRows.Count - $kept.Count
    if ($pruned) { $dirty = $true }
    if ($preUpgradePruned) { Write-KfwScanLog "Dropped $preUpgradePruned row(s) from before kiosks upgraded to agent $($S.TrustedFromAgentVersion)." 'WARN' }

    $heartbeatDue = $true
    if ($lastRunIso) {
        $lr = ConvertFrom-UtcText $lastRunIso
        if ($null -ne $lr -and ($now - $lr).TotalMinutes -lt $S.HeartbeatMinutes) { $heartbeatDue = $false }
    }

    $scriptNew = @($newRows | Where-Object { $_['EventType'] -cin 'RESTART_TRIGGERED', 'REBOOT_SCRIPT' }).Count
    $preSkipped = 0
    foreach ($x in $hostResults) { $preSkipped += $x.PreUpgrade }
    $summary = "hosts=$($kiosks.Count) reachable=$($stats.Reachable) watchdog_hosts=$watchdogCount " +
    "ledgers_read=$($stats.LedgersRead) eventlogs_read=$($stats.EventLogsRead) new_events=$eventRows " +
    "status_rows=$($newRows.Count - $eventRows) flag_changes=$flagChanges pruned=$pruned " +
    "pre_upgrade_skipped=$preSkipped host_errors=$($stats.HostErrors)"

    $elapsed = (Get-KfwMono) - $start
    $dataChanged = $false
    if ($dirty -or $heartbeatDue) {
        $partial = $stats.HostErrors -gt 0 -or -not $primaryWritable
        $kept.Add((New-KfwRow @{
                    EventId = "RUN-$scanId"; EventTimeUtc = $collected; EventType = 'COLLECTOR_RUN'
                    Severity = if ($partial) { 'WARNING' } else { 'INFO' }; Outcome = if ($partial) { 'PARTIAL' } else { 'OK' }
                    DurationSeconds = Format-KfwNumber $elapsed 0; Source = 'Collector'; ScanId = $scanId; CollectedUtc = $collected
                    Detail = "v$($script:CollectorVersion); $summary; list=$listPath; runner=$runner"
                }))
        $kept = Get-KfwSorted $kept { param($r) $r['EventTimeUtc'] + "`0" + $r['EventId'].ToLowerInvariant() }
        if ($DryRun) {
            Write-KfwScanLog "DRY RUN: would write $($kept.Count) row(s) to $output"
        } else {
            if ($primaryWritable) {
                try {
                    Write-KfwFleetCsv $kept $output
                    $dataChanged = $true
                    Write-KfwScanLog "Wrote $($kept.Count) row(s) to $output"
                } catch {
                    Write-KfwScanLog "Could not write the published CSV: $($_.Exception.Message)" 'ERROR'
                    $exitCode = 1
                }
            }
            if (-not $samePath -and $localWritable) {
                try { Write-KfwFleetCsv $kept $local } catch {
                    Write-KfwScanLog "Could not write the local CSV: $($_.Exception.Message)" 'ERROR'
                    $exitCode = 1
                }
            }
        }
    } else {
        Write-KfwScanLog 'Nothing new; CSV left untouched.'
    }

    if (-not $DryRun) {
        $sidecar = [ordered]@{
            LastRunUtc = $collected; LastRunLocal = ConvertTo-LocalIso $now; DurationSeconds = [int][Math]::Truncate($elapsed)
            Hosts = $kiosks.Count; Reachable = $stats.Reachable; WatchdogHosts = $watchdogCount
            NeedsAttention = @($hostResults | Where-Object { $_.Status -ne 'OK' }).Count; NewEvents = $eventRows
            DataChanged = $dataChanged; HostErrors = $stats.HostErrors; SkippedInactive = $statsList.Inactive
            CollectorVersion = $script:CollectorVersion; Runner = $runner
            PbiLaunchers = $pbiDetails; Mach2Launchers = $ngDetails; WebLaunchers = $webDetails
        }
        if ($primaryWritable) { Write-KfwStatusSidecar $output $sidecar }
        if (-not $samePath -and $localWritable) { Write-KfwStatusSidecar $local $sidecar }
    }

    Write-KfwScanLog "Scan $scanId done in $(((Get-KfwMono) - $start).ToString('F1', $inv))s. $summary"
    if ($scriptNew) { Write-KfwScanLog "$scriptNew new watchdog reboot record(s) collected this run." 'WARN' }

    # A summary table for whoever is watching the output.
    $order = Get-KfwSorted $hostResults { param($x) ($(if ($x.Status -eq 'OK') { '1' } else { '0' })) + "`0" + $x.Host }
    $cols = 'Host', 'Type', 'Location', 'Status', 'Watchdog', 'LogAgeMin', 'Agent', 'Launcher', 'NewEvents'
    $widths = @{}
    foreach ($c in $cols) {
        $w = $c.Length
        foreach ($x in $order) { $w = [Math]::Max($w, ([string]$x[$c]).Length) }
        $widths[$c] = $w
    }
    $out = [Text.StringBuilder]::new()
    [void]$out.AppendLine()
    [void]$out.AppendLine((($cols | ForEach-Object { $_.PadRight($widths[$_]) }) -join '  '))
    [void]$out.AppendLine((($cols | ForEach-Object { '-' * $widths[$_] }) -join '  '))
    foreach ($x in $order) { [void]$out.AppendLine((($cols | ForEach-Object { ([string]$x[$_]).PadRight($widths[$_]) }) -join '  ')) }
    $byType = @{}
    foreach ($r in $newRows) { if ($r['EventType'] -cne 'HOST_STATUS') { $byType[$r['EventType']] = 1 + [int]$byType[$r['EventType']] } }
    if ($byType.Count) {
        [void]$out.AppendLine().AppendLine('New events this run:')
        foreach ($t in (Get-KfwSorted @($byType.Keys) { param($x) $x })) { [void]$out.AppendLine("  $($t.PadRight(24)) $($byType[$t])") }
    }
    [Console]::Out.Write($out.ToString())
    [Console]::Out.Flush()
    return $exitCode
}
