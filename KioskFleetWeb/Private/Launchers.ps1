# Reading the launchers' state off a kiosk, and the watchdog's ledger.
#
# Each launcher instance (one per screen folder: S1, S2, ...) rewrites
# Status\<instance>.status.json every few seconds while it runs. This turns
# those files into one host status in the collector's vocabulary, plus the
# details the dashboard shows. Three launchers share it:
#
#   PBI Launcher       Users\Public\Documents\PbiLauncher       a Power BI report
#   Web Launcher       Users\Public\Documents\WebLauncher       one web page
#   Mach2 Launcher NG  Users\Public\Documents\Mach2LauncherNG   a Mach2 dashboard,
#                                                               and the watchdog
#
# Host statuses, worst first:
#
#   LAUNCHER_STALE     status not written for a while: not running    CRITICAL
#   LAUNCHER_STOPPED   stopped (kill.txt) - the screen is empty       CRITICAL
#   LAUNCHER_ERROR     Edge will not start, or Power BI refuses       CRITICAL
#   SIGNIN_BLOCKED     sign-in needs a person (password, MFA)         CRITICAL
#   WRONG_ACCOUNT      Power BI signed in as someone else             CRITICAL
#   RECOVERING         fixing an error or blank page                  WARNING
#   NOT_SHOWING        loading or signing in for over 15 minutes      WARNING
#   NO_DISPLAY         the configured screen is not connected         WARNING
#   HOLD               paused with hold.txt                           WARNING
#   UNSUPERVISED       only keeping Edge open                         WARNING
#   LAUNCHER_DISABLED  DisableStartup is set                          WARNING
#   LAUNCHER_NOT_RUN   installed, never started                       WARNING
#   OK

$script:StateRank = @{
    LAUNCHER_STALE = 1; LAUNCHER_STOPPED = 2; LAUNCHER_ERROR = 3; SIGNIN_BLOCKED = 4; WRONG_ACCOUNT = 5
    RECOVERING = 20; NOT_SHOWING = 21; NO_DISPLAY = 22; HOLD = 23; UNSUPERVISED = 24
    LAUNCHER_DISABLED = 25; LAUNCHER_NOT_RUN = 26; OK = 99
}

$script:NgFolder = 'Mach2LauncherNG'

function Test-KfwNgVersion($Version) {
    # 1.00NG and later: the watchdog is built into the launcher.
    [bool](([string]$Version).Trim() -cmatch '^\d+\.\d+NG$')
}

function Get-KfwInstanceStatus($Inst, [int]$StaleMinutes = 5, [int]$NotShowingMinutes = 15, [bool]$CheckAccount = $true) {
    $state = [string]$Inst.State
    if ($state -eq 'STOPPED') { return 'LAUNCHER_STOPPED', 'CRITICAL' }
    if ($state -eq 'DISABLED') { return 'LAUNCHER_DISABLED', 'WARNING' }
    $age = $Inst.AgeMinutes
    if ($null -eq $age -or $age -gt $StaleMinutes) { return 'LAUNCHER_STALE', 'CRITICAL' }
    switch -CaseSensitive ($state) {
        'ERROR' { return 'LAUNCHER_ERROR', 'CRITICAL' }
        'SIGNIN_BLOCKED' { return 'SIGNIN_BLOCKED', 'CRITICAL' }
        'RECOVERING' { return 'RECOVERING', 'WARNING' }
        'WAITING_DISPLAY' { return 'NO_DISPLAY', 'WARNING' }
        'HOLD' { return 'HOLD', 'WARNING' }
        'UNSUPERVISED' { return 'UNSUPERVISED', 'WARNING' }
    }
    if ($CheckAccount -and $Inst.UserName -and $Inst.SignedInAs -and $Inst.SignedInAs -cne $Inst.UserName) { return 'WRONG_ACCOUNT', 'CRITICAL' }
    $mins = $Inst.StateMinutes
    if ($state -cin 'LOADING', 'SIGNING_IN', 'STARTING', 'LAUNCHING' -and $null -ne $mins -and $mins -gt $NotShowingMinutes) { return 'NOT_SHOWING', 'WARNING' }
    return 'OK', 'INFO'
}

function Test-KfwHasConfig([string]$Dir, [string]$HostName) {
    $entries = Get-KfwFiles $Dir '*.json'
    $names = @($entries | ForEach-Object { $_.Name.ToLowerInvariant() })
    if ($HostName -and $names -contains "$($HostName.ToLowerInvariant()).json") { return $true }
    if ($names -contains 'config.json') { return $true }
    foreach ($e in $entries) {
        if ($e.Name -cnotin 'EXAMPLE.json', 'migration.json' -and -not $e.Name.ToLowerInvariant().EndsWith('.status.json')) { return $true }
    }
    return $false
}

function Get-KfwScreenFolders([string]$Docs, [string]$Name, [string]$HostName) {
    # Where a launcher keeps its screens: one folder per screen (S1, S2, ...),
    # and - for PBI Launcher before 2.0.1 - the launcher's own folder, as S1.
    $base = Join-KfwPath $Docs $Name
    $rel = 'Users\Public\Documents\' + $Name
    $out = [Collections.Generic.List[object]]::new()
    $entries = Get-KfwEntries $base
    if (-not $entries.Count -and -not (Test-Path -LiteralPath $base)) { return , $out }
    $dirs = @($entries | Where-Object { $_.IsDir -and $_.Name -match '^S\d+$' })
    foreach ($d in (Get-KfwSorted $dirs { param($e) $e.Name.ToUpperInvariant() })) {
        $out.Add([ordered]@{ Screen = $d.Name.ToUpperInvariant(); Folder = "$rel\$($d.Name)"; Path = $d.Path; HasConfig = Test-KfwHasConfig $d.Path $HostName })
    }
    # The layout from before the screen folders: config and Status\ next to the script.
    $names = @($entries | ForEach-Object { $_.Name.ToLowerInvariant() })
    $hostJson = [bool]$HostName -and $names -contains "$($HostName.ToLowerInvariant()).json"
    $s1 = @($out | Where-Object { $_.Screen -eq 'S1' -and $_.HasConfig })
    if (-not $s1.Count -and ($names -contains 'status' -or $hostJson)) {
        $rest = @($out | Where-Object { $_.Screen -ne 'S1' })
        $out = [Collections.Generic.List[object]]::new()
        $out.Add([ordered]@{ Screen = 'S1'; Folder = $rel; Path = $base; HasConfig = $hostJson; Legacy = $true })
        foreach ($r in $rest) { $out.Add($r) }
    }
    return , $out
}

function New-KfwEmptyObservation([string]$Kind) {
    [ordered]@{ Launcher = $Kind; Installed = $false; LegacyLauncher = $false; OldLauncher = $false; Screens = @(); Instances = @()
        Status = $null; Severity = $null; Summary = ''; LauncherVersion = ''; PcBootUtc = $null; Error = '' }
}

function Get-KfwAge([datetime]$Now, $Time) {
    if ($null -eq $Time) { return $null }
    return Get-KfwRound ($Now - $Time).TotalMinutes 1
}

function Format-KfwNum($Value) {
    if ($null -eq $Value) { return '' }
    $d = [double]$Value
    if ($d -eq [Math]::Floor($d)) { return ([long]$d).ToString([Globalization.CultureInfo]::InvariantCulture) }
    return Format-Float $d
}

function Get-KfwPbiObservation([string]$Docs, [datetime]$Now, [int]$StaleMinutes = 5, [string]$HostName = '', [string]$Name = 'PbiLauncher') {
    # Everything knowable about a kiosk's PBI Launcher (or, with Name =
    # WebLauncher, its Web Launcher) from its Public Documents. Never throws.
    $kind = if ($Name -eq 'WebLauncher') { 'WEB' } else { 'PBI' }
    $obs = New-KfwEmptyObservation $kind
    try {
        if ($Name -eq 'PbiLauncher') {
            foreach ($rel in 'Launchers', 'Mach2Launchers') {
                foreach ($d in (Get-KfwDirs (Join-KfwPath $Docs $rel))) {
                    if ($d.Name.ToUpperInvariant().StartsWith('LAUNCHER S') -and ((Test-KfwFile (Join-KfwPath $d.Path 'PowerBILauncher.exe')) -or (Test-KfwFile (Join-KfwPath $d.Path 'PowerBILauncher\PowerBILauncher.exe')))) {
                        $obs.LegacyLauncher = $true
                    }
                }
            }
        }
        $obs.Installed = Test-KfwFile (Join-KfwPath $Docs "$Name\$Name.ps1")
        $folders = Get-KfwScreenFolders $Docs $Name $HostName
        $obs.Screens = @($folders | Where-Object { $_.HasConfig } | ForEach-Object { $_.Screen })
        $tag = if ($kind -eq 'WEB') { 'web' } else { 'launcher' }
        if (-not $obs.Installed) {
            $obs.Summary = if ($obs.LegacyLauncher) { "$tag=old" } elseif ($obs.Screens.Count) { "$tag=config written, not installed" } else { "$tag=none" }
            return $obs
        }
        $files = [Collections.Generic.List[object]]::new()
        foreach ($sf in $folders) {
            foreach ($f in (Get-KfwFiles (Join-KfwPath $sf.Path 'Status') '*.status.json')) { $files.Add(@($f, $sf)) }
        }
        if (-not $files.Count) {
            $obs.Status = 'LAUNCHER_NOT_RUN'; $obs.Severity = 'WARNING'; $obs.Summary = "$tag=installed, not started"
            return $obs
        }
        $worst = $null
        $instances = [Collections.Generic.List[object]]::new()
        foreach ($pair in $files) {
            $f = $pair[0]; $sf = $pair[1]
            $s = Read-KfwJsonFile $f.Path
            if ($s -isnot [Collections.IDictionary]) { continue }
            $updated = ConvertFrom-UtcText $s.UpdatedUtc; $since = ConvertFrom-UtcText $s.StateSinceUtc
            $inst = [ordered]@{
                Instance = [string]$s.Instance; Screen = $sf.Screen; Folder = $sf.Folder; Launcher = $kind
                State = [string]$s.State; Detail = [string]$s.Detail
                UpdatedUtc = $updated; AgeMinutes = Get-KfwAge $Now $updated; StateMinutes = Get-KfwAge $Now $since
                LastShownUtc = ConvertFrom-UtcText $s.LastShownUtc; LauncherVersion = [string]$s.LauncherVersion
                EdgeVersion = ([string]$s.EdgeVersion) -creplace '^Edg/', ''
                UserName = [string]$s.UserName; SignedInAs = [string]$s.SignedInAs
                SignIns = $s.SignIns; Reloads = $s.Reloads; BrowserStarts = $s.BrowserStarts
                LastError = [string]$s.LastError; PcBootUtc = ConvertFrom-UtcText $s.PcBootUtc
                HostStatus = ''; Severity = ''
            }
            $inst.HostStatus, $inst.Severity = Get-KfwInstanceStatus $inst $StaleMinutes
            $instances.Add($inst)
            if ($null -eq $worst -or $script:StateRank[$inst.HostStatus] -lt $script:StateRank[$worst.HostStatus]) { $worst = $inst }
        }
        if ($null -eq $worst) {
            $obs.Status = 'LAUNCHER_NOT_RUN'; $obs.Severity = 'WARNING'; $obs.Summary = "$tag=status unreadable"
            return $obs
        }
        $obs.Instances = @($instances)
        $obs.Status = $worst.HostStatus; $obs.Severity = $worst.Severity
        $obs.LauncherVersion = $worst.LauncherVersion; $obs.PcBootUtc = $worst.PcBootUtc
        $parts = foreach ($i in $instances) {
            $as = if ($i.SignedInAs) { " as=$($i.SignedInAs)" } else { '' }
            "$tag=$($i.Screen):$($i.State)$as age=$(Format-KfwNum $i.AgeMinutes)m v$($i.LauncherVersion)"
        }
        $obs.Summary = @($parts) -join '; '
    } catch {
        $obs.Error = $_.Exception.Message
    }
    return $obs
}

function Get-KfwWebObservation([string]$Docs, [datetime]$Now, [int]$StaleMinutes = 5, [string]$HostName = '') {
    Get-KfwPbiObservation $Docs $Now $StaleMinutes $HostName 'WebLauncher'
}

function Get-KfwNgObservation([string]$Docs, [datetime]$Now, [int]$StaleMinutes = 5) {
    # Mach2 Launcher NG, from the kiosk's Public Documents. Never throws.
    $obs = New-KfwEmptyObservation 'MACH2'
    try {
        foreach ($d in (Get-KfwDirs (Join-KfwPath $Docs 'Mach2Launchers'))) {
            if ($d.Name.ToUpperInvariant().StartsWith('LAUNCHER S') -and (Test-KfwFile (Join-KfwPath $d.Path 'Mach2Launcher.exe'))) { $obs.OldLauncher = $true }
        }
        $root = Join-KfwPath $Docs $script:NgFolder
        $obs.Installed = Test-KfwFile (Join-KfwPath $root 'Mach2LauncherNG.ps1')
        $subdirs = Get-KfwDirs $root
        $screens = @($subdirs | Where-Object { $_.Name -match '^S\d+$' -and @((Get-KfwFiles $_.Path '*.json') | Where-Object { $_.Name -cne 'EXAMPLE.json' }).Count } |
                ForEach-Object { $_.Name.ToUpperInvariant() })
        $obs.Screens = Get-KfwSorted $screens { param($x) $x }
        if (-not $obs.Installed) {
            $obs.Summary = if ($obs.OldLauncher) { 'launcher=old' } else { '' }
            return $obs
        }
        $files = [Collections.Generic.List[object]]::new()
        foreach ($d in $subdirs) {
            foreach ($f in (Get-KfwFiles (Join-KfwPath $d.Path 'Status') '*.status.json')) { $files.Add(@($f, $d.Name)) }
        }
        if (-not $files.Count) {
            $obs.Status = 'LAUNCHER_NOT_RUN'; $obs.Severity = 'WARNING'; $obs.Summary = 'launcher=NG installed, not started'
            return $obs
        }
        $worst = $null
        $instances = [Collections.Generic.List[object]]::new()
        foreach ($pair in $files) {
            $f = $pair[0]; $dname = $pair[1]
            $s = Read-KfwJsonFile $f.Path
            if ($s -isnot [Collections.IDictionary]) { continue }
            $updated = ConvertFrom-UtcText $s.UpdatedUtc; $since = ConvertFrom-UtcText $s.StateSinceUtc
            $inst = [ordered]@{
                Instance = [string]$s.Instance; Screen = $dname.ToUpperInvariant()
                Folder = "Users\Public\Documents\$($script:NgFolder)\$dname"; Launcher = 'MACH2'
                State = [string]$s.State; Detail = [string]$s.Detail
                UpdatedUtc = $updated; AgeMinutes = Get-KfwAge $Now $updated; StateMinutes = Get-KfwAge $Now $since
                LastShownUtc = ConvertFrom-UtcText $s.LastShownUtc; LauncherVersion = [string]$s.LauncherVersion
                EdgeVersion = ([string]$s.EdgeVersion) -creplace '^Edg/', ''
                Watchdog = [bool]$s.Watchdog; LoopGuard = [string]$s.LoopGuard
                PageWhitePercent = $s.PageWhitePercent; ScreenWhitePercent = $s.ScreenWhitePercent
                SignIns = $s.SignIns; Reloads = $s.Reloads; BrowserStarts = $s.BrowserStarts
                PcRestarts = $s.PcRestarts; LastError = [string]$s.LastError
                PcBootUtc = ConvertFrom-UtcText $s.PcBootUtc; HostStatus = ''; Severity = ''
            }
            $inst.HostStatus, $inst.Severity = Get-KfwInstanceStatus $inst $StaleMinutes 15 $false
            $instances.Add($inst)
            if ($null -eq $worst -or $script:StateRank[$inst.HostStatus] -lt $script:StateRank[$worst.HostStatus]) { $worst = $inst }
        }
        if ($null -eq $worst) {
            $obs.Status = 'LAUNCHER_NOT_RUN'; $obs.Severity = 'WARNING'; $obs.Summary = 'launcher=NG status unreadable'
            return $obs
        }
        $obs.Instances = @($instances)
        $obs.Status = $worst.HostStatus; $obs.Severity = $worst.Severity
        $obs.LauncherVersion = $worst.LauncherVersion; $obs.PcBootUtc = $worst.PcBootUtc
        $parts = foreach ($i in (Get-KfwSorted $instances { param($x) $x.Instance })) {
            $w = if ($null -ne $i.ScreenWhitePercent) { " screen=$(Format-KfwJsonNumber $i.ScreenWhitePercent)%" }
            elseif ($null -ne $i.PageWhitePercent) { " page=$(Format-KfwJsonNumber $i.PageWhitePercent)%" } else { '' }
            "launcher=$($i.Instance):$($i.State)$w age=$(Format-KfwNum $i.AgeMinutes)m v$($i.LauncherVersion)"
        }
        $obs.Summary = @($parts) -join '; '
    } catch {
        $obs.Error = $_.Exception.Message
    }
    return $obs
}

function Format-KfwJsonNumber($Value) {
    # A number from a JSON file as Python prints it: 72, 63.5, True.
    if ($Value -is [bool]) { if ($Value) { return 'True' } else { return 'False' } }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        $s = Format-Float ([double]$Value)
        if ($s -notmatch '[.eE]') { $s += '.0' }
        return $s
    }
    return [string]$Value
}

function Format-KfwIso($Time) {
    if ($null -eq $Time) { return '' }
    return ConvertTo-UtcIso $Time
}

function Get-KfwSidecarEntry($Obs) {
    # The per-kiosk details the dashboard shows, small enough for the collector's status file.
    if ($Obs.Launcher -eq 'MACH2') {
        return [ordered]@{
            Launcher = 'MACH2'; Installed = $Obs.Installed; OldLauncher = $Obs.OldLauncher; Screens = @($Obs.Screens)
            Status = $Obs.Status; Error = $Obs.Error
            Instances = @(foreach ($i in $Obs.Instances) {
                    [ordered]@{
                        Instance = $i.Instance; Screen = $i.Screen; Folder = $i.Folder; State = $i.State; Detail = $i.Detail
                        HostStatus = $i.HostStatus; UpdatedUtc = Format-KfwIso $i.UpdatedUtc; StateMinutes = $i.StateMinutes
                        LastShownUtc = Format-KfwIso $i.LastShownUtc; Version = $i.LauncherVersion; Edge = $i.EdgeVersion
                        Watchdog = $i.Watchdog; LoopGuard = $i.LoopGuard; PageWhitePercent = $i.PageWhitePercent
                        ScreenWhitePercent = $i.ScreenWhitePercent; SignIns = $i.SignIns; Reloads = $i.Reloads
                        BrowserStarts = $i.BrowserStarts; PcRestarts = $i.PcRestarts; LastError = $i.LastError
                    }
                })
        }
    }
    return [ordered]@{
        Launcher = $Obs.Launcher; Installed = $Obs.Installed; LegacyLauncher = $Obs.LegacyLauncher; Screens = @($Obs.Screens)
        Status = $Obs.Status; Error = $Obs.Error
        Instances = @(foreach ($i in $Obs.Instances) {
                [ordered]@{
                    Instance = $i.Instance; Screen = $i.Screen; Folder = $i.Folder; State = $i.State; Detail = $i.Detail
                    HostStatus = $i.HostStatus; UpdatedUtc = Format-KfwIso $i.UpdatedUtc; StateMinutes = $i.StateMinutes
                    LastShownUtc = Format-KfwIso $i.LastShownUtc; Version = $i.LauncherVersion; Edge = $i.EdgeVersion
                    UserName = $i.UserName; SignedInAs = $i.SignedInAs; SignIns = $i.SignIns; Reloads = $i.Reloads
                    BrowserStarts = $i.BrowserStarts; LastError = $i.LastError
                }
            })
    }
}

# --- the watchdog's ledger ---------------------------------------------------------------
function Read-KfwAgentLedger([string]$Docs) {
    # Every ledger file a kiosk has, oldest first: rolled-over files (named
    # by their timestamp) before the live one, so file order is event order.
    $result = @{ Files = 0; Rows = [Collections.Generic.List[object]]::new(); Errors = [Collections.Generic.List[string]]::new() }
    $files = Get-KfwSorted (Get-KfwFiles $Docs 'mwst_events*.csv') { param($e) ($(if ($e.Name.ToLowerInvariant() -eq 'mwst_events.csv') { '1' } else { '0' })) + "`0" + $e.Name }
    $result.Files = $files.Count
    foreach ($f in $files) {
        try {
            $text = Read-KfwText $f.Path
            # Only complete lines: a row mid-append would otherwise be taken
            # truncated, and never replaced since its EventId is already known.
            $cut = $text.LastIndexOf("`n")
            if ($cut -lt 0) { continue }
            foreach ($r in (ConvertFrom-KfwCsvText $text.Substring(0, $cut + 1))) { $result.Rows.Add($r) }
        } catch {
            $result.Errors.Add("Ledger $($f.Name): $($_.Exception.Message)")
        }
    }
    return $result
}
