# From the events CSV (and the collector's status file next to it) to what
# the page draws: the latest status per kiosk, reboot counts, a week of daily
# counts, the launcher details, and every kiosk's details card.
#
# The JSON keys are the PowerShell front end's (Host, Status, Launchers, ...),
# so the page and anything else built against them keep working.

$script:StatusRank = @{
    OFFLINE = 0; LOOP_GUARD = 1; NO_AGENT = 2; STALE = 3
    LAUNCHER_STALE = 1; LAUNCHER_STOPPED = 1; LAUNCHER_ERROR = 1; SIGNIN_BLOCKED = 1; WRONG_ACCOUNT = 1
    NO_ACCESS = 4; AGENT_OUTDATED = 5; EVENTLOG_UNAVAILABLE = 6
    RECOVERING = 5; NOT_SHOWING = 5; NO_DISPLAY = 5; HOLD = 6; UNSUPERVISED = 6; LAUNCHER_DISABLED = 6; LAUNCHER_NOT_RUN = 6
    OK = 9; INACTIVE = 10
}
$script:CriticalStatuses = @('OFFLINE', 'STALE', 'NO_AGENT', 'LOOP_GUARD', 'LAUNCHER_STALE', 'LAUNCHER_STOPPED', 'LAUNCHER_ERROR', 'SIGNIN_BLOCKED', 'WRONG_ACCOUNT')
$script:WarningStatuses = @('NO_ACCESS', 'AGENT_OUTDATED', 'EVENTLOG_UNAVAILABLE', 'RECOVERING', 'NOT_SHOWING', 'NO_DISPLAY', 'HOLD', 'UNSUPERVISED', 'LAUNCHER_DISABLED', 'LAUNCHER_NOT_RUN')

$script:LauncherFolders = [ordered]@{ NG = 'Mach2LauncherNG'; PBI = 'PbiLauncher'; WEB = 'WebLauncher' }
$script:LauncherNames = @{ NG = 'Mach2 Launcher NG'; PBI = 'PBI Launcher'; WEB = 'Web Launcher' }
$script:TabKinds = [ordered]@{ Mach2 = 'NG'; PBI = 'PBI'; Web = 'WEB' }
$script:KindTabs = @{ NG = 'Mach2'; PBI = 'PBI'; WEB = 'Web' }
$script:KindOfScreenLauncher = @{ MACH2 = 'NG'; PBI = 'PBI'; WEB = 'WEB' }
$script:LauncherTab = @{ MACH2 = 'Mach2'; PBI = 'PBI'; WEB = 'Web' }

function Get-KfwRank([string]$Status) { if ($script:StatusRank.ContainsKey($Status)) { $script:StatusRank[$Status] } else { 8 } }

function Test-KfwAttention($K) {
    # INACTIVE is a decision, not a fault.
    $K.Status -cnotin 'OK', 'INACTIVE'
}

function Get-KfwSeverity([string]$Status) {
    if ($Status -ceq 'OK') { return 'OK' }
    if ($Status -ceq 'INACTIVE') { return 'INACTIVE' }
    if ($Status -cin $script:CriticalStatuses) { return 'CRITICAL' }
    if ($Status -cin $script:WarningStatuses) { return 'WARNING' }
    return 'UNKNOWN'
}

function Get-KfwShortType([string]$Kind) {
    if (-not $Kind) { return '' }
    $t = $Kind.Trim()
    if ($t -match '^(PBI|POWER\s*BI)') { return 'PBI' }
    if ($t -match '^MACH') { return 'Mach2' }
    if ($t -match '^WEB') { return 'Web' }
    return ($t -split '[\s\-]')[0]
}

function Get-KfwKioskTab([string]$Kind) {
    $s = Get-KfwShortType $Kind
    if ($s -cin 'Mach2', 'PBI', 'Web') { return $s }
    return 'Other'
}

function Get-KfwKioskScreens($Entry) {
    # A kiosk's screens, whatever runs on them, from the collector's status file.
    $out = [ordered]@{}
    foreach ($pair in @(@('MACH2', $Entry.Ng), @('PBI', $Entry.Pbi), @('WEB', $Entry.Web))) {
        $kind = $pair[0]; $l = $pair[1]
        if (-not $l) { continue }
        foreach ($i in @($l['Instances'])) {
            if (-not $i) { continue }
            $screen = [string]$i['Screen']
            if (-not $screen) { $screen = if ($kind -eq 'MACH2') { [string]$i['Instance'] } else { 'S1' } }
            if (-not $screen) { $screen = 'S1' }
            $key = "$screen|$kind"
            if ($out.Contains($key)) { continue }
            $out[$key] = [ordered]@{ Screen = $screen.ToUpperInvariant(); Launcher = $kind; Instance = [string]$i['Instance']
                State = [string]$i['State']; HostStatus = [string]$i['HostStatus']; Detail = [string]$i['Detail']
                Version = [string]$i['Version']; Folder = [string]$i['Folder']; Watchdog = [bool]$i['Watchdog']; Source = $i }
        }
        foreach ($s in @($l['Screens'])) {
            if (-not $s) { continue }
            $key = "$s|$kind"
            if ($out.Contains($key)) { continue }
            $out[$key] = [ordered]@{ Screen = ([string]$s).ToUpperInvariant(); Launcher = $kind; Instance = [string]$s; State = 'NOT_RUN'
                HostStatus = 'LAUNCHER_NOT_RUN'; Detail = 'config written, no status yet'; Version = ''; Folder = ''; Watchdog = $false; Source = $null }
        }
    }
    return , (Get-KfwSorted @($out.Values) { param($x) $x.Screen + "`0" + $x.Launcher })
}

function Get-KfwKioskTabs([string]$Kind, $Screens) {
    $tabs = [Collections.Generic.List[string]]::new()
    $t = Get-KfwKioskTab $Kind
    if ($t -ne 'Other') { $tabs.Add($t) }
    foreach ($s in $Screens) {
        $tab = $script:LauncherTab[$s.Launcher]
        if ($tab -and -not $tabs.Contains($tab)) { $tabs.Add($tab) }
    }
    if (-not $tabs.Count) { $tabs.Add($t) }
    return , $tabs.ToArray()
}

function Read-KfwFleetState([string]$Path, $Rows) {
    # Everything a front end needs, in one pass over the CSV's rows.
    $state = @{ Ok = $false; Error = $null; Hosts = @(); LastCollected = $null; LastRun = $null; RowCount = 0
        DayKeys = @(); Pbi = @{}; Ng = @{}; Web = @{}; Sidecar = $null; Path = $Path }
    if (-not [IO.File]::Exists($Path)) {
        $state.Error = "No events file yet at $Path - run a scan once."
        return $state
    }
    if ($null -eq $Rows) {
        try { $Rows = Read-KfwCsvRows $Path } catch { $state.Error = "Could not read the events file: $($_.Exception.Message)"; return $state }
    }
    if (-not $Rows.Count) {
        $text = ''
        try { $text = Read-KfwFileText $Path } catch { }
        if (-not $text.Trim()) { $state.Error = 'The events file is empty.'; return $state }
    }
    $state.RowCount = $Rows.Count

    $sidecar = Get-KfwSidecarPath $Path
    if ([IO.File]::Exists($sidecar)) {
        try {
            $sc = ConvertFrom-Json (Read-KfwFileText $sidecar) -AsHashtable -Depth 30
            $state.Sidecar = $sc
            $state.LastRun = $sc['LastRunUtc']
            if ($sc['PbiLaunchers']) { $state.Pbi = $sc['PbiLaunchers'] }
            if ($sc['Mach2Launchers']) { $state.Ng = $sc['Mach2Launchers'] }
            if ($sc['WebLaunchers']) { $state.Web = $sc['WebLaunchers'] }
        } catch { }
    }

    $today = [datetime]::Now.Date
    $state.DayKeys = @(foreach ($d in 6..0) { $today.AddDays(-$d).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) })
    $cutoff24 = [datetime]::UtcNow.AddHours(-24)
    $byHost = [ordered]@{}

    foreach ($r in $Rows) {
        $etype = [string]$r['EventType']
        $tUtc = [string]$r['EventTimeUtc']
        if ($etype -ceq 'COLLECTOR_RUN') {
            if (-not $state.LastCollected -or [string]::CompareOrdinal($tUtc, $state.LastCollected) -gt 0) { $state.LastCollected = $tUtc }
            continue
        }
        $h = [string]$r['Host']
        if (-not $h) { continue }
        $e = $byHost[$h]
        if ($null -eq $e) {
            $e = [ordered]@{ Host = $h; Location = ''; Type = ''; Tab = ''; Tabs = @(); Status = 'UNKNOWN'; StatusRow = $null
                Reboots24 = 0; Script24 = 0; Episodes24 = 0; HasWatchdog = $false; Days = @{}; Pbi = $null; Ng = $null; Web = $null; Screens = @() }
            $byHost[$h] = $e
        }
        if ($etype -ceq 'HOST_STATUS') {
            if ($r['WatchdogRunning']) { $e.HasWatchdog = $true }
            if ($null -eq $e.StatusRow -or [string]::CompareOrdinal($tUtc, [string]$e.StatusRow['EventTimeUtc']) -gt 0) {
                $e.StatusRow = $r
                $e.Status = if ($r['Outcome']) { [string]$r['Outcome'] } else { 'UNKNOWN' }
            }
        }
        if ($r['Location']) { $e.Location = [string]$r['Location'] }
        if ($r['KioskType']) { $e.Type = [string]$r['KioskType'] }
        if ($r['IsCanonicalReboot'] -ceq 'TRUE') {
            $d = [string]$r['EventDate']
            if ($d) { $e.Days[$d] = 1 + [int]$e.Days[$d] }
            $when = ConvertFrom-LocalText $r['EventTimeLocal']
            if ($null -ne $when -and $when -ge $cutoff24) {
                $e.Reboots24++
                if ($r['IsScriptReboot'] -ceq 'TRUE') { $e.Script24++ }
            }
        }
        if ($etype -cin 'WHITE_EPISODE_START', 'LOWWHITE_EPISODE_START') {
            $when = ConvertFrom-LocalText $r['EventTimeLocal']
            if ($null -ne $when -and $when -ge $cutoff24) { $e.Episodes24++ }
        }
    }

    foreach ($e in $byHost.Values) {
        $e.Pbi = $state.Pbi[$e.Host]
        $e.Ng = $state.Ng[$e.Host]
        $e.Web = $state.Web[$e.Host]
        $e.Screens = Get-KfwKioskScreens $e
        $e.Tabs = Get-KfwKioskTabs $e.Type $e.Screens
        $e.Tab = Get-KfwKioskTab $e.Type
        if ($e.Tab -eq 'Other' -and $e.Tabs[0] -ne 'Other') { $e.Tab = $e.Tabs[0] }
    }

    # Trouble first, then the kiosks that run a watchdog, then by place.
    $state.Hosts = (Get-KfwSorted @($byHost.Values) {
            param($e) (Get-KfwRank $e.Status).ToString('00') + "`0" + $(if ($e.HasWatchdog) { '0' } else { '1' }) + "`0" + $e.Location.ToLowerInvariant() + "`0" + $e.Host.ToLowerInvariant()
        })
    $state.Ok = $true
    return $state
}

function Get-KfwFreshness($State, [int]$StaleMinutes = 45) {
    # How old the data is, and whether that is a problem in itself: a dead
    # collector must never look like a healthy fleet.
    $out = @{ text = 'collector has never run'; stale = $true; minutes = $null; lastRun = 'never' }
    $stamp = $null
    if ($State) { $stamp = if ($State.LastRun) { $State.LastRun } else { $State.LastCollected } }
    $last = ConvertFrom-UtcText $stamp
    if ($null -eq $last) { return $out }
    $out.lastRun = Format-Local $last 'ddd dd MMM HH:mm'
    $mins = [int][Math]::Max(0, [Math]::Truncate(([datetime]::UtcNow - $last).TotalMinutes))
    $out.minutes = $mins
    if ($mins -lt $StaleMinutes) {
        $out.stale = $false
        $out.text = if ($mins -le 1) { 'collected just now' } else { "collected $mins min ago" }
    } elseif ($mins -lt 1440) {
        $out.text = "STALE - collector last ran $([Math]::Floor($mins / 60)) h ago"
    } else {
        $out.text = "STALE - collector last ran $([Math]::Floor($mins / 1440)) days ago"
    }
    return $out
}

# --- one kiosk, as the page draws it ----------------------------------------------------------
function Get-KfwLauncherView($K, [string]$Tab = '') {
    # What a kiosk's launcher was doing at the last scan. Tab picks the
    # launcher that tab is about; without it, the kiosk's own, then any.
    $out = [ordered]@{ Kind = ''; Known = $false; Installed = $false; Old = $false; State = ''; For = ''; Account = ''
        Version = ''; Screen = ''; Severity = 'UNKNOWN'; Instances = @(); Status = ''; Error = '' }
    if (-not $K) { return $out }
    $want = if ($Tab) { $script:TabKinds[$Tab] } else { $script:TabKinds[[string]$K.Tab] }
    if ($null -eq $want) { $want = '' }
    $have = [ordered]@{ NG = $K.Ng; PBI = $K.Pbi; WEB = $K.Web }
    $entry = $null
    if ($want -and $have[$want]) {
        $entry = $have[$want]; $out.Kind = $want
    } elseif (-not $want -or -not $Tab) {
        foreach ($kind in $have.Keys) { if ($have[$kind]) { $entry = $have[$kind]; $out.Kind = $kind; break } }
    }
    if (-not $entry) {
        if ($Tab -eq 'Mach2' -or (-not $Tab -and $K.Tab -eq 'Mach2')) { $out.State = 'old launcher'; $out.Severity = 'INACTIVE' }
        return $out
    }
    $out.Known = $true
    $out.Status = [string]$entry['Status']
    $out.Error = [string]$entry['Error']
    $out.Installed = [bool]$entry['Installed']
    $out.Old = if ($out.Kind -eq 'NG') { [bool]$entry['OldLauncher'] } elseif ($out.Kind -eq 'PBI') { [bool]$entry['LegacyLauncher'] } else { $false }
    $out.Instances = @($entry['Instances'] | Where-Object { $null -ne $_ })
    if (-not $out.Installed) {
        $out.State = if ($out.Old) { 'old launcher' } else { 'no launcher' }
        $out.Severity = 'INACTIVE'
        return $out
    }
    if (-not $out.Instances.Count) { $out.State = 'not started'; $out.Severity = 'WARNING'; return $out }

    $first = $out.Instances[0]
    $screenOf = { param($i) if ($i['Screen']) { [string]$i['Screen'] } else { [string]$i['Instance'] } }
    $out.State = if ($out.Instances.Count -gt 1) { (@($out.Instances | ForEach-Object { "$(& $screenOf $_):$($_['State'])" })) -join ' ' } else { [string]$first['State'] }
    $out.For = Format-Minutes $first['StateMinutes']
    $out.Version = [string]$first['Version']
    if ($out.Kind -eq 'PBI') {
        $out.Account = [string]$first['SignedInAs']
    } elseif ($out.Kind -eq 'NG') {
        $pct = $first['ScreenWhitePercent']
        if ($null -eq $pct) { $pct = $first['PageWhitePercent'] }
        if ($null -ne $pct -and [string]$pct -ne '') { $out.Screen = "$(Format-KfwJsonNumber $pct)%" }
    }
    $st = [string]$first['State']
    if ($st -cin 'SHOWING', 'BROWSING') { $out.Severity = 'OK' }
    elseif ($st -cin 'LOADING', 'SIGNING_IN', 'LAUNCHING', 'STARTING', 'RESTARTING_PC') { $out.Severity = 'UNKNOWN' }
    elseif ($st -cin 'SIGNIN_BLOCKED', 'ERROR', 'STOPPED') { $out.Severity = 'CRITICAL' }
    else { $out.Severity = 'WARNING' }
    if ([string]$first['HostStatus'] -ceq 'LAUNCHER_STALE') {
        $out.State = '(' + $out.State + ')'
        $out.Severity = 'CRITICAL'
    }
    return $out
}

function New-KfwDetailRow([string]$Label, $Value, [string]$Sev = '', [bool]$Wrap = $false) {
    [ordered]@{ Label = $Label; Value = if ($null -eq $Value) { '' } else { Format-KfwJsonNumber $Value }; Sev = $Sev; Wrap = $Wrap }
}

function Get-KfwAgo($Iso) {
    $t = ConvertFrom-UtcText $Iso
    if ($null -eq $t) { return '' }
    return Format-Minutes ([datetime]::UtcNow - $t).TotalMinutes
}

function Format-KfwOrEmpty($V) { if ($null -eq $V) { '' } else { Format-KfwJsonNumber $V } }

function Get-KfwKioskDetail($K) {
    # The details card: sections of label/value rows, coloured by severity name.
    $sections = [Collections.Generic.List[object]]::new()
    $rows = [Collections.Generic.List[object]]::new()
    $r0 = $K.StatusRow
    if ($r0) {
        $when = ConvertFrom-UtcText $r0['EventTimeUtc']
        $rows.Add((New-KfwDetailRow 'Seen' $(if ($null -ne $when) { Format-Local $when 'ddd dd MMM HH:mm' } else { '' })))
        if ($r0['Detail']) { $rows.Add((New-KfwDetailRow 'Detail' $r0['Detail'] 'DIM' $true)) }
        $boot = ConvertFrom-UtcText $r0['BootTimeUtc']
        if ($null -ne $boot) { $rows.Add((New-KfwDetailRow 'PC up since' "$(Format-Local $boot 'dd MMM HH:mm')  ($(Format-Minutes ([datetime]::UtcNow - $boot).TotalMinutes))")) }
    } else {
        $rows.Add((New-KfwDetailRow 'Seen' 'no status row yet' 'WARNING'))
    }
    $rows.Add((New-KfwDetailRow 'Reboots 24h' ("$($K.Reboots24)" + $(if ($K.Script24) { " ($($K.Script24) by the watchdog)" } else { '' }))))
    $rows.Add((New-KfwDetailRow 'Screen events' "$($K.Episodes24) in 24h"))
    $sections.Add([ordered]@{ Title = 'LAST SCAN'; Rows = @($rows) })

    if ($K.HasWatchdog -and $r0) {
        $wd = switch -CaseSensitive ([string]$r0['WatchdogRunning']) { 'TRUE' { 'running' } 'FALSE' { 'DEAD' } default { 'unknown' } }
        $rows = [Collections.Generic.List[object]]::new()
        $rows.Add((New-KfwDetailRow 'State' $wd $(if ($wd -eq 'DEAD') { 'CRITICAL' } else { 'OK' })))
        $rows.Add((New-KfwDetailRow 'Version' ([string]$r0['AgentVersion'])))
        if ($r0['MinutesSinceLastLog']) {
            $m = 0.0
            if ([double]::TryParse([string]$r0['MinutesSinceLastLog'], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$m)) {
                $rows.Add((New-KfwDetailRow 'Last wrote' "$(Format-Minutes $m) ago"))
            }
        }
        $sections.Add([ordered]@{ Title = 'WATCHDOG'; Rows = @($rows) })
    }

    $kinds = [Collections.Generic.List[string]]::new()
    foreach ($pair in @(@('NG', $K.Ng), @('PBI', $K.Pbi), @('WEB', $K.Web))) { if ($pair[1]) { $kinds.Add($pair[0]) } }
    if (-not $kinds.Count -and $script:TabKinds.Contains([string]$K.Tab)) { $kinds.Add($script:TabKinds[[string]$K.Tab]) }
    $screens = @($K.Screens)
    if ($screens.Count -gt 1 -or $kinds.Count -gt 1) {
        $sections.Add([ordered]@{ Title = 'SCREENS'; Rows = @(foreach ($s in $screens) {
                        New-KfwDetailRow $s.Screen "$($script:LauncherNames[$script:KindOfScreenLauncher[$s.Launcher]])  -  $($s.State)" (Get-KfwSeverity $s.HostStatus)
                    })
            })
    }
    foreach ($kind in $kinds) {
        $rows = [Collections.Generic.List[object]]::new()
        $lv = Get-KfwLauncherView $K $script:KindTabs[$kind]
        if (-not $lv.Known) {
            $why = if ($kind -eq 'NG') { 'not installed - this kiosk still runs Mach2Launcher.exe and the MWST watchdog' } else { 'nothing was read at the last scan' }
            $rows.Add((New-KfwDetailRow 'Installed' $why 'DIM' $true))
        } elseif (-not $lv.Installed) {
            $why = if ($lv.Old) { 'no - still on the old launcher' }
            elseif (@($screens | Where-Object { $script:KindOfScreenLauncher[$_.Launcher] -eq $kind }).Count) { 'no - config written, launcher not installed' }
            else { 'no' }
            $rows.Add((New-KfwDetailRow 'Installed' $why 'WARNING' $true))
        } elseif (-not $lv.Instances.Count) {
            $rows.Add((New-KfwDetailRow 'State' 'installed, never started' 'WARNING'))
        }
        foreach ($i in $lv.Instances) {
            $label = if ($i['Screen']) { [string]$i['Screen'] } else { [string]$i['Instance'] }
            $rows.Add((New-KfwDetailRow $label "$($i['State']) for $(Format-Minutes $i['StateMinutes'])" (Get-KfwSeverity ([string]$i['HostStatus']))))
            if ($i['Detail']) { $rows.Add((New-KfwDetailRow '' $i['Detail'] 'DIM' $true)) }
            if ($kind -eq 'PBI') {
                $rows.Add((New-KfwDetailRow 'Signed in as' $(if ($i['SignedInAs']) { $i['SignedInAs'] } else { 'not seen yet' }) $(if ($K.Status -eq 'WRONG_ACCOUNT') { 'CRITICAL' } else { 'DIM' })))
            } elseif ($kind -eq 'NG') {
                $w = [Collections.Generic.List[string]]::new()
                if ($null -ne $i['ScreenWhitePercent'] -and [string]$i['ScreenWhitePercent'] -ne '') { $w.Add("screen $(Format-KfwJsonNumber $i['ScreenWhitePercent'])%") }
                if ($null -ne $i['PageWhitePercent'] -and [string]$i['PageWhitePercent'] -ne '') { $w.Add("page $(Format-KfwJsonNumber $i['PageWhitePercent'])%") }
                if ($w.Count) { $rows.Add((New-KfwDetailRow 'White' ($w -join ', ') 'DIM')) }
                if ($i['Watchdog']) { $rows.Add((New-KfwDetailRow 'Watchdog' 'this screen is the watchdog' 'DIM')) }
                if ($i['LoopGuard'] -and [string]$i['LoopGuard'] -cne 'OFF') { $rows.Add((New-KfwDetailRow 'Loop guard' $i['LoopGuard'] 'CRITICAL')) }
                if ($i['PcRestarts']) { $rows.Add((New-KfwDetailRow 'PC restarts' $i['PcRestarts'] 'DIM')) }
            }
            $rows.Add((New-KfwDetailRow 'Version' "v$([string]$i['Version'])   Edge $([string]$i['Edge'])" 'DIM'))
            $counts = if ($kind -eq 'WEB') { "$(Format-KfwOrEmpty $i['Reloads']) reloads, $(Format-KfwOrEmpty $i['BrowserStarts']) browser starts" }
            else { "$(Format-KfwOrEmpty $i['Reloads']) reloads, $(Format-KfwOrEmpty $i['SignIns']) sign-ins, $(Format-KfwOrEmpty $i['BrowserStarts']) browser starts" }
            $rows.Add((New-KfwDetailRow 'Counts' $counts 'DIM'))
            if ($i['UpdatedUtc']) { $rows.Add((New-KfwDetailRow 'Status written' ((Get-KfwAgo $i['UpdatedUtc']) + ' ago') 'DIM')) }
            if ($i['LastError']) { $rows.Add((New-KfwDetailRow 'Last error' $i['LastError'] 'WARNING' $true)) }
        }
        if ($lv.Error) { $rows.Add((New-KfwDetailRow 'Could not read' $lv.Error 'WARNING' $true)) }
        if ($lv.Installed -and $lv.Old) { $rows.Add((New-KfwDetailRow 'Old launcher' 'still on this kiosk' 'DIM')) }
        $sections.Add([ordered]@{ Title = $script:LauncherNames[$kind].ToUpperInvariant(); Rows = @($rows) })
    }
    return , $sections.ToArray()
}

function Get-KfwKioskView($K, $DayKeys) {
    $r0 = $K.StatusRow
    $logAge = ''; $uptime = ''; $watchdog = ''; $agent = ''; $note = ''
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($r0) {
        $v = 0.0
        if ($r0['MinutesSinceLastLog'] -and [double]::TryParse([string]$r0['MinutesSinceLastLog'], [Globalization.NumberStyles]::Float, $inv, [ref]$v)) {
            $logAge = "$([long][Math]::Truncate($v))m"
        }
        if ($r0['UptimeHours']) {
            if ([double]::TryParse([string]$r0['UptimeHours'], [Globalization.NumberStyles]::Float, $inv, [ref]$v)) {
                $uptime = if ($v -ge 48) { "$([long][Math]::Truncate($v / 24))d" } else { "$([long][Math]::Truncate($v))h" }
            }
        } elseif ($r0['BootTimeUtc']) {
            $boot = ConvertFrom-UtcText $r0['BootTimeUtc']
            if ($null -ne $boot) { $uptime = Format-Minutes ([datetime]::UtcNow - $boot).TotalMinutes }
        }
        $watchdog = switch -CaseSensitive ([string]$r0['WatchdogRunning']) { 'TRUE' { 'running' } 'FALSE' { 'DEAD' } default { '' } }
        $agent = [string]$r0['AgentVersion']
        $note = [string]$r0['Detail']
    }
    $reb = ''
    if ($K.Reboots24 -gt 0) { $reb = "$($K.Reboots24)" }
    if ($K.Script24 -gt 0) { $reb = "$($K.Reboots24) ($($K.Script24))" }

    $launchers = [ordered]@{}
    foreach ($tab in 'Mach2', 'PBI', 'Web', 'Other') {
        $lv = Get-KfwLauncherView $K $(if ($tab -eq 'Other') { '' } else { $tab })
        $launchers[$tab] = [ordered]@{ Kind = $lv.Kind; Known = $lv.Known; Installed = $lv.Installed; State = $lv.State; For = $lv.For
            Account = $lv.Account; Version = $lv.Version; Screen = $lv.Screen; Severity = $lv.Severity }
    }
    $screens = @(foreach ($s in @($K.Screens)) {
            $kind = $script:KindOfScreenLauncher[$s.Launcher]
            [ordered]@{ Screen = $s.Screen; Kind = $kind; Name = $script:LauncherNames[$kind]; State = $s.State; Severity = Get-KfwSeverity $s.HostStatus }
        })
    $installed = @(@($K.Ng, $K.Pbi, $K.Web) | Where-Object { $_ -and $_['Installed'] })
    $ver = if ($r0) { [string]$r0['AgentVersion'] } else { '' }
    $messageOk = $K.Tab -eq 'Mach2' -or [bool]$K.Ng
    $messageWhy = if ($messageOk) { '' } else { 'Only Mach2 kiosks have a watchdog to show a message' }
    if ($messageOk -and $ver -and -not (Test-KfwNgVersion $ver)) {
        $parts = ConvertTo-KfwVersionParts $ver
        if ($null -eq $parts -or $parts[0] -lt 7) {
            $messageOk = $false
            $messageWhy = "runs watchdog v$ver; messages need V7.0 or later, or Mach2 Launcher NG"
        }
    }
    [ordered]@{
        Host = $K.Host; Location = $K.Location; Type = $K.Type; Tab = $K.Tab; Tabs = @($K.Tabs)
        Status = $K.Status; Severity = Get-KfwSeverity $K.Status; Attention = Test-KfwAttention $K
        Rank = Get-KfwRank $K.Status
        LogAge = $logAge; Uptime = $uptime; Watchdog = $watchdog; Agent = $agent; Reboots = $reb
        Days = @(foreach ($d in $DayKeys) { [int]$K.Days[$d] }); Note = $note
        Launchers = $launchers; Screens = $screens; Detail = (Get-KfwKioskDetail $K)
        HasLauncher = [bool]$installed.Count; MessageOk = $messageOk; MessageWhy = $messageWhy
        Reboots24 = [int]$K.Reboots24; Script24 = [int]$K.Script24; Episodes24 = [int]$K.Episodes24
    }
}

function Get-KfwFleetView($State) {
    # The whole fleet as the page needs it. Freshness is left out: it changes
    # by the minute, so it is worked out when asked.
    if (-not $State -or -not $State.Ok) {
        return [ordered]@{ Ok = $false; Error = $(if ($State -and $State.Error) { $State.Error } else { 'not read yet' }); Kiosks = @() }
    }
    $hosts = @($State.Hosts)
    $kiosks = @(foreach ($k in $hosts) { Get-KfwKioskView $k $State.DayKeys })
    $attention = @($hosts | Where-Object { Test-KfwAttention $_ })
    $tabs = [ordered]@{}
    foreach ($t in 'Mach2', 'PBI', 'Web', 'Other') {
        $lst = @($hosts | Where-Object { $_.Tab -eq $t -or $_.Tabs -contains $t })
        $tabs[$t] = [ordered]@{ Count = $lst.Count; Attention = @($lst | Where-Object { Test-KfwAttention $_ }).Count }
    }
    $totals = @{}
    foreach ($k in $hosts) { foreach ($d in $k.Days.Keys) { $totals[$d] = [int]$totals[$d] + [int]$k.Days[$d] } }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $chart = @(foreach ($d in $State.DayKeys) {
            $day = [datetime]::ParseExact($d, 'yyyy-MM-dd', $inv)
            [ordered]@{ Day = $d; Label = $day.ToString('ddd', $inv); Long = $day.ToString('ddd dd MMM', $inv); Count = [int]$totals[$d] }
        })
    $sc = $State.Sidecar
    $collector = $null
    if ($sc) {
        $collector = [ordered]@{ Took = [int]$(if ($sc['DurationSeconds']) { $sc['DurationSeconds'] } else { 0 }); Reachable = $sc['Reachable']; Hosts = $sc['Hosts']
            NewEvents = $sc['NewEvents']; Version = [string]$sc['CollectorVersion']; Runner = [string]$sc['Runner'] }
    }
    $sum = { param($name) $n = 0; foreach ($k in $hosts) { $n += [int]$k[$name] }; $n }
    [ordered]@{
        Ok = $true; Error = $null; Total = $hosts.Count; Attention = $attention.Count
        Critical = @($attention | Where-Object { (Get-KfwSeverity $_.Status) -eq 'CRITICAL' }).Count
        Inactive = @($hosts | Where-Object { $_.Status -eq 'INACTIVE' }).Count
        Reboots24 = & $sum 'Reboots24'; Script24 = & $sum 'Script24'; Episodes24 = & $sum 'Episodes24'
        Launchers = [ordered]@{
            Ng = @($hosts | Where-Object { $_.StatusRow -and (Test-KfwNgVersion $_.StatusRow['AgentVersion']) }).Count
            Pbi = @($hosts | Where-Object { $_.Pbi -and $_.Pbi['Installed'] }).Count
            Web = @($hosts | Where-Object { $_.Web -and $_.Web['Installed'] }).Count
        }
        Tabs = $tabs; Chart = $chart; DayKeys = @($State.DayKeys); Collector = $collector
        RowCount = $State.RowCount; File = [IO.Path]::GetFileName($State.Path); Kiosks = $kiosks
    }
}
