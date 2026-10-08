# One kiosk over weeks: its status timeline, reboots, screen events and
# uptime, worked out from the events CSV the collector already keeps.
#
# Nothing new is collected for this. HOST_STATUS rows are written when a
# kiosk's status changes and as a keepalive, so a status holds from its row
# to the next one. A gap longer than the keepalive (plus slack) means nobody
# was scanning: that time is shown as NO DATA, not as whatever the status was
# before, so a dead collector never looks like a kiosk that was fine.

$script:NoData = 'NO_DATA'
# The events worth listing on the page, newest first; status rows are shown
# as the timeline instead, and only where the status changed.
$script:Listed = @(
    'RESTART_TRIGGERED', 'RESTART_CONFIRMED', 'RESTART_FAILED', 'REBOOT_SCRIPT', 'REBOOT_EXTERNAL', 'REBOOT_UNEXPECTED',
    'WHITE_EPISODE_START', 'WHITE_EPISODE_END', 'LOWWHITE_EPISODE_START', 'LOWWHITE_EPISODE_END',
    'AGENT_START', 'AGENT_STOP', 'AGENT_ERROR', 'AGENT_RECOVERED', 'LOOP_GUARD_ENGAGED', 'LOOP_GUARD_RELEASED',
    'MESSAGE_SHOWN', 'MESSAGE_CLOSED', 'MESSAGE_EXPIRED', 'MESSAGE_REJECTED'
)
$script:MaxEvents = 400

function Get-KfwSeconds([datetime]$A, [datetime]$B) { [Math]::Max(0.0, ($B - $A).TotalSeconds) }
function Format-KfwLocalIso([datetime]$T) { Format-Local $T 'yyyy-MM-ddTHH:mm:ss' }
function Get-KfwMaxTime([datetime]$A, [datetime]$B) { if ($A -ge $B) { $A } else { $B } }
function Get-KfwMinTime([datetime]$A, [datetime]$B) { if ($A -le $B) { $A } else { $B } }

function Get-KfwKioskHistory($Rows, [string]$HostName, [int]$Days = 28, [int]$KeepaliveHours = 24, $Now = $null) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $now = if ($Now) { ([datetime]$Now).ToUniversalTime() } else { [datetime]::UtcNow }
    $key = $HostName.ToLowerInvariant()
    $mine = [Collections.Generic.List[object]]::new()
    foreach ($r in $Rows) { if (([string]$r['Host']).ToLowerInvariant() -eq $key) { $mine.Add($r) } }
    $localToday = $now.ToLocalTime().Date
    $firstDay = $localToday.AddDays(-($Days - 1))
    $start = Get-LocalMidnightUtc $firstDay
    $gap = [timespan]::FromHours($KeepaliveHours + 3)

    $out = [ordered]@{ Host = $HostName; Days = $Days; From = Format-KfwLocalIso $start; To = Format-KfwLocalIso $now; Found = [bool]$mine.Count }
    if ($mine.Count) {
        $newest = Get-KfwSorted $mine { param($r) [string]$r['EventTimeUtc'] } -Descending
        $out.Location = ''; $out.Type = ''
        foreach ($r in $newest) { if ($r['Location']) { $out.Location = $r['Location']; break } }
        foreach ($r in $newest) { if ($r['KioskType']) { $out.Type = $r['KioskType']; break } }
        $out.LastEvent = [string]$newest[0]['EventTimeLocal']
    }

    # --- the status timeline ------------------------------------------------------
    $status = [Collections.Generic.List[object]]::new()
    foreach ($r in $mine) {
        if ($r['EventType'] -cne 'HOST_STATUS') { continue }
        $t = ConvertFrom-UtcText $r['EventTimeUtc']
        if ($null -ne $t) { $status.Add(@($t, $(if ($r['Outcome']) { [string]$r['Outcome'] } else { 'UNKNOWN' }), $r)) }
    }
    $statusRows = Get-KfwSorted $status { param($x) $x[0].Ticks.ToString('D20') }

    $segments = [Collections.Generic.List[object]]::new()  # [start, end, status]
    $add = {
        param([datetime]$a, [datetime]$b, [string]$st)
        $a = Get-KfwMaxTime $a $start; $b = Get-KfwMinTime $b $now
        if ($b -le $a) { return }
        if ($segments.Count -and $segments[$segments.Count - 1][2] -ceq $st -and $segments[$segments.Count - 1][1] -ge $a) {
            $last = $segments[$segments.Count - 1]
            $last[1] = Get-KfwMaxTime $last[1] $b
        } else {
            $segments.Add([object[]]@($a, $b, $st))
        }
    }
    for ($i = 0; $i -lt $statusRows.Count; $i++) {
        $t = $statusRows[$i][0]; $st = $statusRows[$i][1]
        $next = if ($i + 1 -lt $statusRows.Count) { $statusRows[$i + 1][0] } else { $now }
        if (($next - $t) -gt $gap) {
            & $add $t ($t + $gap) $st
            & $add ($t + $gap) $next $script:NoData
        } else {
            & $add $t $next $st
        }
    }
    if ($statusRows.Count -and $statusRows[0][0] -gt $start) {
        $segments.Insert(0, [object[]]@($start, $statusRows[0][0], $script:NoData))
    } elseif (-not $statusRows.Count) {
        $segments.Clear()
        $segments.Add([object[]]@($start, $now, $script:NoData))
    }

    $span = Get-KfwSeconds $start $now
    if (-not $span) { $span = 1.0 }
    $byStatus = [ordered]@{}
    foreach ($s in $segments) { $byStatus[$s[2]] = [double]$byStatus[$s[2]] + (Get-KfwSeconds $s[0] $s[1]) }
    # INACTIVE is a kiosk nobody is watching on purpose: neither up nor down.
    $known = 0.0; $ok = 0.0
    foreach ($s in $byStatus.Keys) {
        if ($s -cnotin $script:NoData, 'INACTIVE') { $known += $byStatus[$s] }
        if ((Get-KfwSeverity $s) -eq 'OK') { $ok += $byStatus[$s] }
    }
    $out.Availability = if ($known) { Get-KfwRound (100.0 * $ok / $known) 1 } else { $null }
    $out.Coverage = Get-KfwRound (100.0 * $known / $span) 1
    $bs = foreach ($s in $byStatus.Keys) {
        $v = $byStatus[$s]
        [ordered]@{ Status = $s; Severity = $(if ($s -ceq $script:NoData) { 'INACTIVE' } else { Get-KfwSeverity $s }); Seconds = [long][Math]::Truncate($v)
            Text = Format-Minutes ($v / 60); Pct = Get-KfwRound (100.0 * $v / $span) 1 }
    }
    $out.ByStatus = Get-KfwSorted @($bs) { param($x) (999999999999 - $x.Seconds).ToString('D12') }
    $out.Timeline = @(foreach ($s in $segments) {
            [ordered]@{
                From = Format-KfwLocalIso $s[0]; To = Format-KfwLocalIso $s[1]; Status = $s[2]
                Severity = if ($s[2] -ceq $script:NoData) { 'INACTIVE' } else { Get-KfwSeverity $s[2] }
                Left = Get-KfwRound (100.0 * (Get-KfwSeconds $start $s[0]) / $span) 3; Width = Get-KfwRound (100.0 * (Get-KfwSeconds $s[0] $s[1]) / $span) 3
                For = Format-Minutes ((Get-KfwSeconds $s[0] $s[1]) / 60)
            }
        })
    $out.Changes = [Math]::Max(0, @($segments | Where-Object { $_[2] -cne $script:NoData }).Count - 1)

    # --- per day ---------------------------------------------------------------------
    $dayKeys = @(foreach ($d in 0..($Days - 1)) { $firstDay.AddDays($d).ToString('yyyy-MM-dd', $inv) })
    $perDay = [ordered]@{}
    foreach ($d in $dayKeys) { $perDay[$d] = [ordered]@{ Date = $d; Reboots = 0; Script = 0; Episodes = 0; OkPct = $null } }
    $reboots = [Collections.Generic.List[object]]::new()
    $events = [Collections.Generic.List[object]]::new()
    $limit = $now.AddMinutes(5)
    foreach ($r in $mine) {
        $t = ConvertFrom-UtcText $r['EventTimeUtc']
        if ($null -eq $t -or $t -lt $start -or $t -gt $limit) { continue }
        $d = if ($r['EventDate']) { [string]$r['EventDate'] } else { ConvertTo-LocalDate $t }
        $etype = [string]$r['EventType']
        $canon = $r['IsCanonicalReboot'] -ceq 'TRUE'
        if ($canon) {
            $reboots.Add(@($t, $r))
            if ($perDay.Contains($d)) {
                $perDay[$d].Reboots++
                if ($r['IsScriptReboot'] -ceq 'TRUE') { $perDay[$d].Script++ }
            }
        }
        if ($etype -cin 'WHITE_EPISODE_START', 'LOWWHITE_EPISODE_START' -and $perDay.Contains($d)) { $perDay[$d].Episodes++ }
        if ($etype -cin $script:Listed -or $canon) {
            $events.Add(@($t, [ordered]@{
                        Time = if ($r['EventTimeLocal']) { [string]$r['EventTimeLocal'] } else { Format-KfwLocalIso $t }; Type = $etype
                        Category = [string]$r['EventCategory']; Outcome = [string]$r['Outcome']
                        Severity = $(if ($r['Severity']) { ([string]$r['Severity']).ToUpperInvariant() } else { 'INFO' }); Reboot = $canon
                        Script = $r['IsScriptReboot'] -ceq 'TRUE'; Trigger = [string]$r['RebootTrigger']; Detail = [string]$r['Detail']
                    }))
        }
    }
    # How much of each day the kiosk was fine, of the time anyone was looking.
    foreach ($d in $dayKeys) {
        $day = Get-LocalMidnightUtc ([datetime]::ParseExact($d, 'yyyy-MM-dd', $inv))
        $dayEnd = Get-KfwMinTime $day.AddDays(1) $now
        $good = 0.0; $seen = 0.0
        foreach ($s in $segments) {
            $lo = Get-KfwMaxTime $s[0] $day; $hi = Get-KfwMinTime $s[1] $dayEnd
            if ($hi -le $lo -or $s[2] -cin $script:NoData, 'INACTIVE') { continue }
            $seen += Get-KfwSeconds $lo $hi
            if ((Get-KfwSeverity $s[2]) -eq 'OK') { $good += Get-KfwSeconds $lo $hi }
        }
        $perDay[$d].OkPct = if ($seen) { Get-KfwRound (100.0 * $good / $seen) 1 } else { $null }
    }
    foreach ($d in $dayKeys) {
        $dt = [datetime]::ParseExact($d, 'yyyy-MM-dd', $inv)
        $perDay[$d].Label = $dt.ToString('dd MMM', $inv)
        $perDay[$d].Weekday = $dt.ToString('ddd', $inv)
    }
    $out.PerDay = @($perDay.Values)
    $out.Reboots = $reboots.Count
    $out.ScriptReboots = @($reboots | Where-Object { $_[1]['IsScriptReboot'] -ceq 'TRUE' }).Count
    $ep = 0; foreach ($p in $perDay.Values) { $ep += $p.Episodes }
    $out.Episodes = $ep

    # --- uptime: the runs between reboots --------------------------------------------
    $sortedReboots = Get-KfwSorted $reboots { param($x) $x[0].Ticks.ToString('D20') }
    $runs = [Collections.Generic.List[object]]::new()
    $edges = [Collections.Generic.List[datetime]]::new()
    $edges.Add($start)
    foreach ($x in $sortedReboots) { $edges.Add($x[0]) }
    $ends = [Collections.Generic.List[object]]::new()
    foreach ($x in $sortedReboots) { $ends.Add($x) }
    $ends.Add(@($now, $null))
    for ($i = 0; $i -lt $ends.Count; $i++) {
        $end = $ends[$i][0]; $r = $ends[$i][1]
        $begin = $edges[$i]
        $endedBy = ''
        if ($r) {
            if ($r['IsScriptReboot'] -ceq 'TRUE') { $endedBy = 'the watchdog' }
            else {
                $why = if ($r['RebootTrigger']) { [string]$r['RebootTrigger'] } elseif ($r['EventType']) { [string]$r['EventType'] } else { 'a reboot' }
                $endedBy = $why.Replace('_', ' ').ToLowerInvariant()
            }
        }
        $runs.Add([ordered]@{
                From = Format-KfwLocalIso $begin; To = Format-KfwLocalIso $end
                Hours = Get-KfwRound ((Get-KfwSeconds $begin $end) / 3600) 1; For = Format-Minutes ((Get-KfwSeconds $begin $end) / 60)
                Open = $i -eq 0; Running = $null -eq $r; EndedBy = $endedBy; Detail = if ($r) { [string]$r['Detail'] } else { '' }
            })
    }
    # The first run started before the window (or at a boot nobody saw); its
    # real length is unknown, so it is shown but not counted as the longest.
    $closed = @($runs | Where-Object { -not $_.Open })
    $reversed = $runs.ToArray(); [Array]::Reverse($reversed)
    $out.Runs = $reversed
    # (By hand: Measure-Object -Property does not read a dictionary's keys.)
    $longest = $null; $sum = 0.0; $finished = 0
    foreach ($x in $closed) {
        if ($null -eq $longest -or $x.Hours -gt $longest) { $longest = $x.Hours }
        if (-not $x.Running) { $sum += $x.Hours; $finished++ }
    }
    $out.LongestRunHours = $longest
    $out.MeanRunHours = if ($finished) { Get-KfwRound ($sum / $finished) 1 } else { $null }
    $up = $null
    for ($i = $statusRows.Count - 1; $i -ge 0; $i--) {
        $t = $statusRows[$i][0]; $r = $statusRows[$i][2]
        if ($r['UptimeHours']) {
            $v = 0.0
            if ([double]::TryParse([string]$r['UptimeHours'], [Globalization.NumberStyles]::Float, $inv, [ref]$v)) { $up = $v + (Get-KfwSeconds $t $now) / 3600 } else { $up = $null }
            break
        }
        $boot = ConvertFrom-UtcText $r['BootTimeUtc']
        if ($null -ne $boot) { $up = (Get-KfwSeconds $boot $now) / 3600; break }
    }
    $out.UptimeHours = if ($null -ne $up) { Get-KfwRound $up 1 } else { $null }
    $out.Uptime = if ($null -ne $up) { Format-Minutes ($up * 60) } else { '' }

    $sortedEvents = Get-KfwSorted $events { param($x) $x[0].Ticks.ToString('D20') } -Descending
    $out.EventCount = $events.Count
    $out.Events = @($sortedEvents | Select-Object -First $script:MaxEvents | ForEach-Object { $_[1] })
    return $out
}
