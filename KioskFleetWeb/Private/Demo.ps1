# A fleet that is not there: kiosks as folders, a thread playing their
# launchers and watchdog, and the events of a recent scan. For trying the app
# (Start-KioskFleetWeb.ps1 -Demo) and for the tests.

$script:DemoPng = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==')
$script:LedgerHeader = 'EventId,EventTimeUtc,EventTimeLocal,Host,EventType,Severity,Outcome,WhitePercent,StreakChecks,DurationSeconds,AgentVersion,BootTimeUtc,Detail'

function Get-KfwDemoDocs([string]$Root, [string]$HostName) { Join-KfwPath $Root "$HostName\Users\Public\Documents" }

function Write-KfwDemoJson([string]$Path, $Object) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Object -Depth 10 -Compress))
}

function Format-KfwDemoIso([datetime]$T) { $T.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffff', [Globalization.CultureInfo]::InvariantCulture) + 'Z' }

function New-KfwDemoKiosks([string]$Root) {
    # MWEB1 runs Mach2 Launcher NG on S1 (and is the watchdog), PWEB1 runs
    # PBI Launcher in its old single-folder layout, NEWWEB1 is an empty PC.
    $now = [datetime]::UtcNow
    $ng = Join-KfwPath (Get-KfwDemoDocs $Root 'MWEB1') 'Mach2LauncherNG\S1'
    $pbi = Join-KfwPath (Get-KfwDemoDocs $Root 'PWEB1') 'PbiLauncher'
    foreach ($d in (Join-KfwPath $ng 'Status'), (Join-KfwPath $ng 'Logs'), (Join-KfwPath $pbi 'Status'), (Get-KfwDemoDocs $Root 'NEWWEB1'), (Join-KfwPath (Get-KfwDemoDocs $Root 'MWEB1') 'mwst_inbox')) {
        [void][IO.Directory]::CreateDirectory($d)
    }
    [IO.File]::WriteAllText((Join-KfwPath ([IO.Path]::GetDirectoryName($ng)) 'Mach2LauncherNG.ps1'), '# fake')
    [IO.File]::WriteAllText((Join-KfwPath $pbi 'PbiLauncher.ps1'), '# fake')
    Write-KfwDemoJson (Join-KfwPath $ng 'MWEB1.json') ([ordered]@{ ConfigVersion = '1.00NG'; LoginURL = 'http://station:302/prelogin?clear=true'
            DisplayURL = 'http://station:302/ord/dashboard'; UserName = 'operator'; ScreenSelect = '1'; Watchdog = '1'; LogName = 'MWEB1_Mach2LauncherNG.log' })
    Write-KfwDemoJson (Join-KfwPath $ng 'Status\S1.status.json') ([ordered]@{
            Instance = 'S1'; State = 'SHOWING'; LauncherVersion = '1.00NG'; EdgeVersion = 'Edg/153.0'; UpdatedUtc = Format-KfwDemoIso $now
            StateSinceUtc = Format-KfwDemoIso $now.AddMinutes(-55); Watchdog = $true; LoopGuard = 'OFF'; ScreenWhitePercent = 72
            PageWhitePercent = 63; SignIns = 1; Reloads = 2; BrowserStarts = 1; PcRestarts = 0; LastError = '' })
    [IO.File]::WriteAllText((Join-KfwPath $ng 'Logs\MWEB1_Mach2LauncherNG.log'),
        '<![LOG[The dashboard is on screen.]LOG]!><time="08:30:00.000+000" date="09-20-2026" component="Mach2LauncherNG" context="" type="1" thread="1" file="">')
    Write-KfwDemoJson (Join-KfwPath $pbi 'PWEB1.json') ([ordered]@{ DisplayURL = 'https://app.powerbi.test/report'; UserName = 'kiosk@contoso.test' })
    Write-KfwDemoJson (Join-KfwPath $pbi 'Status\PWEB1.status.json') ([ordered]@{
            Instance = 'PWEB1'; State = 'SHOWING'; LauncherVersion = '2.0.0'; EdgeVersion = 'Edg/153.0'; UpdatedUtc = Format-KfwDemoIso $now
            StateSinceUtc = Format-KfwDemoIso $now.AddMinutes(-30); UserName = 'kiosk@contoso.test'; SignedInAs = 'kiosk@contoso.test'
            SignIns = 1; Reloads = 3; BrowserStarts = 1; LastError = '' })
    # The watchdog's own files: a fresh log and a ledger.
    $mweb1 = Get-KfwDemoDocs $Root 'MWEB1'
    [IO.File]::WriteAllText((Join-KfwPath $mweb1 'mwst.log'), "heartbeat`n")
    $boot = $now.AddHours(-9)
    $rows = @($script:LedgerHeader, "$([guid]::NewGuid()),$(ConvertTo-UtcIso $now.AddDays(-2)),,MWEB1,AGENT_START,INFO,STARTED,,,,1.00NG,$(ConvertTo-UtcIso $boot),started")
    [IO.File]::WriteAllText((Join-KfwPath $mweb1 'mwst_events.csv'), ($rows -join "`r`n") + "`r`n")
    return @{ ng = $ng; pbi = $pbi }
}

function Start-KfwFakeLauncher([string]$Root, $Dirs, $Control) {
    # Takes control files, answers snapshot.txt with a picture, stores
    # password.seed, and plays the watchdog for messages - leaving hold.txt
    # alone, as a real launcher does. Runs until $Control.Stop.
    $pairs = @(@($Dirs.ng, 'S1'), @($Dirs.pbi, 'PWEB1'))
    $mweb1 = Get-KfwDemoDocs $Root 'MWEB1'
    while (-not $Control.Stop) {
        Start-Sleep -Milliseconds 100
        foreach ($pair in $pairs) {
            $d = $pair[0]; $name = $pair[1]
            foreach ($f in 'refresh.txt', 'relaunch.txt', 'kill.txt', 'restart.txt') {
                $p = Join-KfwPath $d $f
                if ([IO.File]::Exists($p)) {
                    try { [IO.File]::WriteAllText((Join-KfwPath $d "taken.$f"), [IO.File]::ReadAllText($p)); [IO.File]::Delete($p) } catch { }
                }
            }
            $snap = Join-KfwPath $d 'snapshot.txt'
            if ([IO.File]::Exists($snap)) {
                try {
                    [IO.File]::Delete($snap)
                    [IO.File]::WriteAllBytes((Join-KfwPath $d "Status\$name.png"), $script:DemoPng)
                    Write-KfwDemoJson (Join-KfwPath $d "Status\$name.snapshot.json") ([ordered]@{ TakenUtc = Format-KfwDemoIso ([datetime]::UtcNow); State = 'SHOWING'
                            Url = 'http://station/dashboard'; Title = 'Dashboard'; Image = "$name.png"; Error = '' })
                } catch { }
            }
            $seed = Join-KfwPath $d 'password.seed'
            if ([IO.File]::Exists($seed)) {
                try { [IO.File]::WriteAllText((Join-KfwPath $d 'taken.seed'), [IO.File]::ReadAllText($seed)); [IO.File]::Delete($seed) } catch { }
            }
        }
        $inbox = Join-KfwPath $mweb1 'mwst_inbox'
        if (-not [IO.Directory]::Exists($inbox)) { continue }
        foreach ($m in [IO.DirectoryInfo]::new($inbox).GetFiles('msg_*.json')) {
            try { $msg = ConvertFrom-Json ([IO.File]::ReadAllText($m.FullName)) -AsHashtable } catch { continue }
            try { $m.Delete() } catch { }
            $now = ConvertTo-UtcIso ([datetime]::UtcNow)
            $lines = "$([guid]::NewGuid()),$now,,MWEB1,MESSAGE_SHOWN,INFO,SHOWN,,,,1.00NG,,MessageId=$($msg.Id); shown`r`n" +
            "$([guid]::NewGuid()),$now,,MWEB1,MESSAGE_CLOSED,INFO,ACKNOWLEDGED,,,,1.00NG,,MessageId=$($msg.Id); OK pressed`r`n"
            try { [IO.File]::AppendAllText((Join-KfwPath $mweb1 'mwst_events.csv'), $lines) } catch { }
        }
    }
}

function Start-KfwFakeLauncherThread([string]$Root, $Dirs) {
    $control = [hashtable]::Synchronized(@{ Stop = $false })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript("Import-Module '$($script:ModuleManifest -replace "'", "''")'; Start-KfwFakeLauncher `$args[0] `$args[1] `$args[2]").AddArgument($Root).AddArgument($Dirs).AddArgument($control)
    $control.Handle = $ps.BeginInvoke()
    $control.PS = $ps
    return $control
}

function Stop-KfwFakeLauncherThread($Control) {
    $Control.Stop = $true
    if ($Control.Handle) { [void]$Control.Handle.AsyncWaitHandle.WaitOne(3000) }
    try { $Control.PS.Runspace.Dispose(); $Control.PS.Dispose() } catch { }
}

function New-KfwDemoRow([hashtable]$Values) {
    $r = [ordered]@{}
    foreach ($c in $script:Columns) { $r[$c] = '' }
    foreach ($k in $Values.Keys) { $r[$k] = [string]$Values[$k] }
    return $r
}

function Write-KfwDemoEvents([string]$CsvPath, [int]$HistoryDays = 0) {
    # The events CSV and status file as the collector leaves them; with
    # HistoryDays, the weeks before as well (for the History view).
    $u = [datetime]::UtcNow
    $now = [datetime]::new($u.Year, $u.Month, $u.Day, $u.Hour, $u.Minute, $u.Second, [DateTimeKind]::Utc)
    $kiosks = @(
        @('MWEB1', 'LINE1', 'Mach2', 'OK', 'TRUE', '1.00NG', 1),
        @('MWEB2', 'LINE2', 'Mach2', 'STALE', 'FALSE', '7.0', 1900),
        @('MWEB3', 'LINE3', 'Mach2', 'OK', 'TRUE', '6.1', 2),
        @('PWEB1', 'APU1', 'PBI', 'OK', '', '', $null),
        @('PWEB2', 'APU2', 'PBI - SR', 'WRONG_ACCOUNT', '', '', $null),
        @('PWEB3', 'APU3', 'PBI', 'OFFLINE', '', '', $null),
        @('OWEB1', 'STORE', 'Signage', 'OK', '', '', $null)
    )
    $rows = [Collections.Generic.List[object]]::new()
    $t = $now.AddMinutes(-4)
    foreach ($k in $kiosks) {
        $rows.Add((New-KfwDemoRow @{ EventId = [guid]::NewGuid(); EventTimeUtc = ConvertTo-UtcIso $t; EventTimeLocal = ConvertTo-LocalIso $t; EventDate = ConvertTo-LocalDate $t
                    Host = $k[0]; Location = $k[1]; KioskType = $k[2]; EventCategory = 'HOST'; EventType = 'HOST_STATUS'; Severity = 'INFO'; Outcome = $k[3]
                    Reachable = 'TRUE'; WatchdogRunning = $k[4]; AgentVersion = $k[5]; MinutesSinceLastLog = if ($null -eq $k[6]) { '' } else { [string]$k[6] }
                    BootTimeUtc = ConvertTo-UtcIso $now.AddHours(-9); UptimeHours = '9'; Source = 'Collector'; Detail = "reach=ping share=ok for $($k[0])" }))
    }
    # MWEB2's week: a reboot the watchdog asked for, an update's restart
    # today and another yesterday, each followed by its boot.
    $reboot = {
        param([datetime]$When, $Type, $Trigger, $Script, $Canonical, $Detail = '')
        $rows.Add((New-KfwDemoRow @{ EventId = [guid]::NewGuid(); EventTimeUtc = ConvertTo-UtcIso $When; EventTimeLocal = ConvertTo-LocalIso $When; EventDate = ConvertTo-LocalDate $When
                    Host = 'MWEB2'; Location = 'LINE2'; KioskType = 'Mach2'; EventCategory = 'REBOOT'; EventType = $Type
                    Severity = if ($Script) { 'CRITICAL' } else { 'WARNING' }; Outcome = if ($Type -eq 'BOOT') { 'BOOT' } else { 'REBOOT' }
                    IsCanonicalReboot = if ($Canonical) { 'TRUE' } else { 'FALSE' }; IsScriptReboot = if ($Script) { 'TRUE' } else { 'FALSE' }
                    RebootTrigger = $Trigger; Source = if ($Type -eq 'RESTART_TRIGGERED') { 'Agent' } else { 'EventLog' }; Detail = $Detail }))
    }
    $y = $now.AddDays(-1)
    & $reboot $y 'REBOOT_EXTERNAL' 'EXTERNAL' $false $true 'Process=TrustedInstaller.exe; Reason=Operating System: Upgrade'
    & $reboot $y.AddMinutes(2) 'BOOT' '' $false $false
    & $reboot $now.AddHours(-5) 'RESTART_TRIGGERED' 'WATCHDOG_WHITE' $true $true 'Kind=WHITE white for 300s'
    & $reboot $now.AddHours(-3) 'REBOOT_EXTERNAL' 'EXTERNAL' $false $true 'Process=explorer.exe; Reason=Other (Unplanned)'
    & $reboot $now.AddHours(-3).AddMinutes(2) 'BOOT' '' $false $false
    $rows.Add((New-KfwDemoRow @{ EventId = [guid]::NewGuid(); EventTimeUtc = ConvertTo-UtcIso $t; EventTimeLocal = ConvertTo-LocalIso $t; EventDate = ConvertTo-LocalDate $t
                EventCategory = 'COLLECTOR'; EventType = 'COLLECTOR_RUN'; Severity = 'INFO'; Outcome = 'OK'; Source = 'Collector' }))
    if ($HistoryDays) { foreach ($r in (Get-KfwDemoPast $kiosks $now $HistoryDays)) { $rows.Add($r) } }
    $text = [KioskFleetWeb.Csv]::Write($rows, $script:Columns, $true)
    [IO.File]::WriteAllText($CsvPath, $text, [Text.UTF8Encoding]::new($true))
    $iso = ConvertTo-UtcIso $now
    $sidecar = [ordered]@{
        LastRunUtc = ConvertTo-UtcIso $t; DurationSeconds = 42; Hosts = 7; Reachable = 6; NewEvents = 0; CollectorVersion = '6.2'; Runner = 'test@here'
        PbiLaunchers = [ordered]@{
            PWEB1 = [ordered]@{ Installed = $true; LegacyLauncher = $false; Status = 'OK'; Error = ''; Screens = @('S1'); Instances = @([ordered]@{
                        Instance = 'PWEB1'; Screen = 'S1'; State = 'SHOWING'; HostStatus = 'OK'; UpdatedUtc = $iso; StateMinutes = 30
                        Version = '2.0.0'; Edge = '153.0'; SignedInAs = 'kiosk@contoso.test'; SignIns = 1; Reloads = 3; BrowserStarts = 1; LastError = '' })
            }
            PWEB2 = [ordered]@{ Installed = $true; LegacyLauncher = $false; Status = 'WRONG_ACCOUNT'; Error = ''; Instances = @([ordered]@{
                        Instance = 'PWEB2'; Screen = 'S1'; State = 'SHOWING'; HostStatus = 'WRONG_ACCOUNT'; UpdatedUtc = $iso; StateMinutes = 12
                        Version = '2.0.0'; Edge = '153.0'; SignedInAs = 'someone@contoso.test'; SignIns = 1; Reloads = 1; BrowserStarts = 1; LastError = '' })
            }
        }
        Mach2Launchers = [ordered]@{
            MWEB1 = [ordered]@{ Installed = $true; OldLauncher = $false; Status = 'OK'; Error = ''; Screens = @('S1'); Instances = @([ordered]@{
                        Instance = 'S1'; Screen = 'S1'; State = 'SHOWING'; HostStatus = 'OK'; UpdatedUtc = $iso; StateMinutes = 55
                        Version = '1.00NG'; Edge = '153.0'; Watchdog = $true; LoopGuard = 'OFF'; PageWhitePercent = 63; ScreenWhitePercent = 72
                        SignIns = 1; Reloads = 2; BrowserStarts = 1; PcRestarts = 0; LastError = '' })
            }
        }
    }
    [IO.File]::WriteAllText((Get-KfwSidecarPath $CsvPath), (ConvertTo-Json -InputObject $sidecar -Depth 10 -Compress))
}

function Get-KfwStableSeed([string]$Text) {
    # A seed that is the same in every run (String.GetHashCode is not).
    $h = 17
    foreach ($c in $Text.ToCharArray()) { $h = ($h * 31 + [int]$c) % 2147483647 }
    return [int]$h
}

function Get-KfwDemoPast($Kiosks, [datetime]$Now, [int]$Days) {
    # Weeks of a made-up past, the same every time for the same kiosk: a
    # status row a day, now and then trouble for a few hours, reboots, white
    # screens, and a weekend with no scans at all. It stops short of the
    # scan's own rows above, which stay the newest, and of the last 24 hours.
    $rows = [Collections.Generic.List[object]]::new()
    $add = {
        param([datetime]$When, $HostName, $Loc, $Typ, [hashtable]$V)
        $base = @{ EventId = [guid]::NewGuid(); EventTimeUtc = ConvertTo-UtcIso $When; EventTimeLocal = ConvertTo-LocalIso $When; EventDate = ConvertTo-LocalDate $When
            Host = $HostName; Location = $Loc; KioskType = $Typ; Source = 'Collector' }
        foreach ($k in $V.Keys) { $base[$k] = $V[$k] }
        $rows.Add((New-KfwDemoRow $base))
    }
    $end = $Now.AddHours(-3)
    $recent = $Now.AddHours(-25)
    $gapFrom = $Now.AddDays(-17)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    foreach ($k in $Kiosks) {
        $hostName = $k[0]; $loc = $k[1]; $typ = $k[2]
        $rnd = [Random]::new((Get-KfwStableSeed $hostName))
        $mach2 = $typ -eq 'Mach2'
        $t = $Now.AddDays(-$Days).AddHours(-3)
        $boot = $t.AddHours(-$rnd.Next(5, 61))
        while ($t -lt $end) {
            if ($t -ge $gapFrom -and $t -lt $gapFrom.AddDays(2)) { $t = $t.AddDays(2); continue }
            $status = 'OK'
            if ($rnd.NextDouble() -lt 0.12) {
                $choices = if ($mach2) { @('OFFLINE', 'STALE', 'LOOP_GUARD') } else { @('OFFLINE', 'NOT_SHOWING') }
                $status = $choices[$rnd.Next($choices.Count)]
            }
            & $add $t $hostName $loc $typ @{ EventCategory = 'STATUS'; EventType = 'HOST_STATUS'; Severity = $(if ($status -eq 'OK') { 'INFO' } else { 'WARNING' })
                Outcome = $status; Reachable = $(if ($status -eq 'OFFLINE') { 'FALSE' } else { 'TRUE' }); WatchdogRunning = $(if ($mach2) { 'TRUE' } else { '' })
                BootTimeUtc = ConvertTo-UtcIso $boot; UptimeHours = ($t - $boot).TotalHours.ToString('F1', $inv); Detail = "history for $hostName" }
            if ($status -ne 'OK' -and $t -lt $recent) {
                $back = $t.AddHours($rnd.Next(1, 10))
                & $add $back $hostName $loc $typ @{ EventCategory = 'STATUS'; EventType = 'HOST_STATUS'; Severity = 'INFO'; Outcome = 'OK'; Reachable = 'TRUE'
                    WatchdogRunning = $(if ($mach2) { 'TRUE' } else { '' }); BootTimeUtc = ConvertTo-UtcIso $boot; UptimeHours = ($back - $boot).TotalHours.ToString('F1', $inv); Detail = 'back' }
            }
            $w = $t.AddHours($rnd.Next(1, 21))
            if ($mach2 -and $rnd.NextDouble() -lt 0.25 -and $w -lt $recent) {
                $secs = $rnd.Next(60, 401)
                & $add $w $hostName $loc $typ @{ EventCategory = 'SCREEN'; EventType = 'WHITE_EPISODE_START'; Severity = 'WARNING'; Outcome = 'WHITE'; WhitePercent = '97'; Source = 'Agent' }
                & $add $w.AddSeconds($secs) $hostName $loc $typ @{ EventCategory = 'SCREEN'; EventType = 'WHITE_EPISODE_END'; Severity = 'INFO'; Outcome = 'CLEARED'; DurationSeconds = [string]$secs; Source = 'Agent' }
            }
            $r = $t.AddHours($rnd.Next(1, 21))
            if ($rnd.NextDouble() -lt $(if ($mach2) { 0.22 } else { 0.08 }) -and $r -lt $recent) {
                $byWatchdog = $mach2 -and $rnd.NextDouble() -lt 0.5
                if ($byWatchdog) {
                    & $add $r $hostName $loc $typ @{ EventCategory = 'REBOOT'; EventType = 'RESTART_TRIGGERED'; Severity = 'CRITICAL'; Outcome = 'REBOOT'
                        IsCanonicalReboot = 'TRUE'; IsScriptReboot = 'TRUE'; RebootTrigger = 'WATCHDOG_WHITE'; Source = 'Agent'; Detail = 'Kind=WHITE white for 300s' }
                } else {
                    & $add $r $hostName $loc $typ @{ EventCategory = 'REBOOT'; EventType = 'REBOOT_EXTERNAL'; Severity = 'WARNING'; Outcome = 'REBOOT'
                        IsCanonicalReboot = 'TRUE'; IsScriptReboot = 'FALSE'; RebootTrigger = 'EXTERNAL'; Source = 'EventLog'; Detail = 'Process=TrustedInstaller.exe; Reason=Operating System: Upgrade' }
                    & $add $r.AddMinutes(2) $hostName $loc $typ @{ EventCategory = 'REBOOT'; EventType = 'BOOT'; Severity = 'INFO'; Outcome = 'BOOT'
                        IsCanonicalReboot = 'FALSE'; IsScriptReboot = 'FALSE'; Source = 'EventLog' }
                }
                $boot = $r.AddMinutes(2)
            }
            $t = $t.AddDays(1)
        }
    }
    return , $rows
}

$script:DemoList = @'
Host,Location,Type,HasMwst,Active,RestartGroup
MWEB1,LINE1,Mach2,Y,,A
MWEB2,LINE2,Mach2,Y,,A
MWEB3,LINE3,Mach2,Y,,B
PWEB1,APU1,PBI,,,
PWEB2,APU2,PBI - SR,,,
PWEB3,APU3,PBI,,,
OWEB1,STORE,Signage,,,
NEWWEB1,LAB,Web board,,N,
'@

function Initialize-KfwDemo([string]$DataDir) {
    # Kiosks under <data>\demo-kiosks, a kiosk list and a scan's worth of
    # events - once. Returns @{ Root; Dirs }.
    $root = Join-Path $DataDir 'demo-kiosks'
    [void][IO.Directory]::CreateDirectory($DataDir)
    if (-not [IO.Directory]::Exists($root)) {
        [void](New-KfwDemoKiosks $root)
        foreach ($h in 'MWEB2', 'MWEB3', 'PWEB2', 'OWEB1') { [void][IO.Directory]::CreateDirectory((Get-KfwDemoDocs $root $h)) }
    }
    $dirs = @{ ng = Join-KfwPath (Get-KfwDemoDocs $root 'MWEB1') 'Mach2LauncherNG\S1'; pbi = Join-KfwPath (Get-KfwDemoDocs $root 'PWEB1') 'PbiLauncher' }
    if (-not [IO.File]::Exists((Join-Path $DataDir 'MWST_FleetEvents.csv'))) { Write-KfwDemoEvents (Join-Path $DataDir 'MWST_FleetEvents.csv') 63 }
    if (-not @([IO.DirectoryInfo]::new($DataDir).GetFiles('kiosk-list.*')).Count) {
        [IO.File]::WriteAllText((Join-Path $DataDir 'kiosk-list.csv'), ($script:DemoList -replace "`r?`n", "`n"))
    }
    return @{ Root = $root; Dirs = $dirs }
}

function Start-KfwDemo($App) {
    $d = Initialize-KfwDemo $App.Settings.DataDir
    $App.Settings.ShareTemplate = Join-KfwPath $d.Root '{0}\Users\Public\Documents'
    $App.Demo = Start-KfwFakeLauncherThread $d.Root $d.Dirs
    Write-KfwLog "DEMO: a pretend fleet in $($d.Root); nothing here touches a real kiosk."
}
