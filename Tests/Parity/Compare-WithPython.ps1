#Requires -Version 7.4
<#
.SYNOPSIS
    Runs this collector and the Python one (kiosk-fleet-web, kfw/collector.py)
    on the same fake fleet at the same moment, and compares what they write.

.DESCRIPTION
    The events CSV must come out byte for byte the same, but for the run's
    own row (COLLECTOR_RUN: its duration, the collector version, who ran it);
    the status file the same in content, but for those and the time it was
    written in local time. Two scans each, so merging into an existing file
    is compared too.

    A development tool: it needs python3 and a checkout of kiosk-fleet-web.

.EXAMPLE
    ./Tests/Parity/Compare-WithPython.ps1 -PythonRepo ../kiosk-fleet-web
#>
param(
    [Parameter(Mandatory)][string]$PythonRepo,
    [string]$WorkDir = (Join-Path ([IO.Path]::GetTempPath()) "kfw-parity-$PID")
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../KioskFleetWeb/KioskFleetWeb.psd1') -Force -DisableNameChecking
$PythonRepo = (Resolve-Path $PythonRepo).ProviderPath

$root = Join-Path $WorkDir 'kiosks'
$dataPy = Join-Path $WorkDir 'data-py'
$dataPs = Join-Path $WorkDir 'data-ps'
foreach ($d in $dataPy, $dataPs) { [void][IO.Directory]::CreateDirectory($d) }
$dirs = New-KfwDemoKiosks $root
$now = [datetime]::UtcNow
$now = [datetime]::new($now.Year, $now.Month, $now.Day, $now.Hour, $now.Minute, $now.Second, [DateTimeKind]::Utc)
$iso = { param([datetime]$t) ConvertTo-UtcIso $t }
$f = { param([string[]]$v) (($v | ForEach-Object { [KioskFleetWeb.Csv]::Field($_, $false) }) -join ',') + "`r`n" }
$header = 'EventId,EventTimeUtc,EventTimeLocal,Host,EventType,Severity,Outcome,WhitePercent,StreakChecks,DurationSeconds,AgentVersion,BootTimeUtc,Detail' + "`r`n"
$g = { [guid]::NewGuid().ToString() }

# --- MWEB1: the demo kiosk, with a ledger that has everything ------------------------------
$m1 = Get-KfwDemoDocs $root 'MWEB1'
$trig = & $g; $trig2 = & $g; $failedTrig = & $g
$win = {
    param([datetime]$t, [hashtable]$payload)
    & $f @('w', (& $iso $t), '', 'MWEB1', 'WINEVENT', '', '', '', '', '', '', '', (ConvertTo-Json -InputObject $payload -Compress))
}
$boot0 = $now.AddDays(-3)
$older = $header +
(& $f @((& $g), (& $iso $now.AddDays(-5)), '', 'MWEB1', 'AGENT_START', 'INFO', 'STARTED', '', '', '', '6.0', (& $iso $now.AddDays(-6)), 'old agent')) +
(& $f @((& $g), (& $iso $now.AddDays(-4)), '', 'MWEB1', 'AGENT_START', 'INFO', 'STARTED', '', '', '', '6.1', (& $iso $now.AddDays(-4)), 'upgraded')) +
(& $win $boot0 @{ Id = 6005; Provider = 'EventLog'; RecordId = 100; Props = @() })
[IO.File]::WriteAllText((Join-Path $m1 'mwst_events_20260901-000000.csv'), $older)
$live = (& $f @($trig, (& $iso $now.AddHours(-30)), '', 'MWEB1', 'RESTART_TRIGGERED', 'critical', 'triggered', '97.456', '12.5', '', '1.00NG', (& $iso $boot0), 'Kind=WHITE white for 60s')) +
(& $win $now.AddHours(-30).AddSeconds(4) @{ Id = 1074; Provider = 'User32'; RecordId = 4711; Props = @('C:\Windows\system32\shutdown.exe', 'MWEB1', 'No title', '0x80000000', 'restart', "MWST-WATCHDOG WHITE id=$($trig.Substring(0, 8))", 'NT AUTHORITY\SYSTEM') }) +
(& $win $now.AddHours(-30).AddMinutes(2) @{ Id = 6005; Provider = 'EventLog'; RecordId = 4712; Props = @() }) +
(& $f @((& $g), (& $iso $now.AddHours(-29)), '', 'MWEB1', 'RESTART_CONFIRMED', 'INFO', 'CONFIRMED', '', '', '', '1.00NG', (& $iso $now.AddHours(-30)), 'WHITE confirmed')) +
(& $f @($failedTrig, (& $iso $now.AddHours(-20)), '', 'MWEB1', 'RESTART_TRIGGERED', 'CRITICAL', 'TRIGGERED', '88', '3', '', '1.00NG', (& $iso $now.AddHours(-30)), 'Kind=BROWSER browser hung')) +
(& $f @((& $g), (& $iso $now.AddHours(-19)), '', 'MWEB1', 'RESTART_FAILED', 'WARNING', 'FAILED', '', '', '', '1.00NG', (& $iso $now.AddHours(-30)), "TriggerEventId=$failedTrig; shutdown refused")) +
(& $win $now.AddHours(-12) @{ Id = 1074; Provider = 'User32'; RecordId = 5000; Props = @('C:\Windows\servicing\TrustedInstaller.exe', 'MWEB1', 'Operating System: Upgrade (Planned)', '0x80020003', 'restart', '', 'NT AUTHORITY\SYSTEM') }) +
(& $win $now.AddHours(-12).AddSeconds(30) @{ Id = 1074; Provider = 'User32'; RecordId = 5001; Props = @('C:\Windows\system32\winlogon.exe', 'MWEB1', 'No title', '0x500ff', 'restart', '', 'MWEB1\kiosk') }) +
(& $win $now.AddHours(-12).AddMinutes(3) @{ Id = 6005; Provider = 'EventLog'; RecordId = 5002; Props = @() }) +
(& $win $now.AddHours(-8) @{ Id = 6005; Provider = 'EventLog'; RecordId = 5100; Props = @() }) +
(& $win $now.AddHours(-8).AddSeconds(20) @{ Id = 6008; Provider = 'EventLog'; RecordId = 5101; Props = @('10:31:00', '9/30/2026'); Msg = "The previous system shutdown at 10:31:00 on`r`n9/30/2026 was unexpected." }) +
(& $win $now.AddHours(-6) @{ Id = 1074; Provider = 'User32'; RecordId = 5200; Props = @('C:\x.exe', 'MWEB1', 'KPI screen has been white for 5 minutes', '', 'restart', '', 'SYSTEM') }) +
(& $win $now.AddHours(-6).AddMinutes(2) @{ Id = 6005; Provider = 'EventLog'; RecordId = 5201; Props = @() }) +
(& $win $now.AddHours(-5) @{ Id = 7036; Provider = 'Service Control Manager'; RecordId = 5300; Props = @('x') }) +
(& $f @($trig2, (& $iso $now.AddHours(-4)), '', 'MWEB1', 'RESTART_TRIGGERED', 'CRITICAL', 'TRIGGERED', '', '', '', '1.00NG', (& $iso $now.AddHours(-6)), 'LOWWHITE below 30% for 600s')) +
(& $f @((& $g), (& $iso $now.AddHours(-3)), '', 'MWEB1', 'WHITE_EPISODE_START', 'WARNING', 'WHITE', '99.999', '', '', '1.00NG', (& $iso $now.AddHours(-6)), "page`twhite")) +
(& $f @((& $g), (& $iso $now.AddHours(-3).AddMinutes(4)), '', 'MWEB1', 'WHITE_EPISODE_END', 'INFO', 'CLEARED', '', '', '240.5', '1.00NG', (& $iso $now.AddHours(-6)), 'cleared')) +
(& $f @((& $g), (& $iso $now.AddHours(-2)), '', 'MWEB1', 'LOOP_GUARD_ENGAGED', 'CRITICAL', 'HOLD', '', '', '', '1.00NG', (& $iso $now.AddHours(-6)), 'three restarts in an hour')) +
(& $f @((& $g), (& $iso $now.AddHours(-1)), '', 'MWEB1', 'LOOP_GUARD_RELEASED', 'INFO', 'RELEASED', '', '', '', '1.00NG', (& $iso $now.AddHours(-6)), 'released')) +
(& $f @('not-a-guid', (& $iso $now.AddMinutes(-50)), '', 'MWEB1', 'AGENT_ERROR', 'WARNING', 'ERROR', '', '', '', '1.00NG', '', 'skipped: no GUID')) +
(& $f @((& $g), 'yesterday', '', 'MWEB1', 'AGENT_ERROR', 'WARNING', 'ERROR', '', '', '', '1.00NG', '', 'skipped: no time')) +
(& $f @((& $g), (& $iso $now.AddMinutes(-40)), '', 'MWEB1', 'MESSAGE_SHOWN', 'INFO', 'SHOWN', '', '', '', '1.00NG', '', 'MessageId=abc; shown, with "quotes", and a comma')) +
"$(& $g),$(& $iso $now),,MWEB1,AGENT_STOP,INFO,STOPPED,,,,1.00NG,"
[IO.File]::AppendAllText((Join-Path $m1 'mwst_events.csv'), $live)

# --- MWEB2: NG on two screens, S2 stale; a log a while old ------------------------------------
$m2 = Get-KfwDemoDocs $root 'MWEB2'
foreach ($s in 'S1', 'S2') {
    $d = Join-KfwPath $m2 "Mach2LauncherNG/$s"
    [void][IO.Directory]::CreateDirectory((Join-KfwPath $d 'Status'))
    [IO.File]::WriteAllText((Join-KfwPath $d 'MWEB2.json'), '{"DisplayURL":"http://station/x"}')
}
[IO.File]::WriteAllText((Join-KfwPath $m2 'Mach2LauncherNG/Mach2LauncherNG.ps1'), '# fake')
$st = { param([datetime]$u, [datetime]$since, [string]$state, $white) [ordered]@{ Instance = 'S1'; State = $state; LauncherVersion = '1.01NG'; EdgeVersion = 'Edg/154.1'; UpdatedUtc = (Format-KfwDemoIso $u); StateSinceUtc = (Format-KfwDemoIso $since); Watchdog = $true; LoopGuard = 'OFF'; ScreenWhitePercent = $white; SignIns = 2; Reloads = 7; BrowserStarts = 1; PcRestarts = 3; LastError = 'x' } }
Write-KfwDemoJson (Join-KfwPath $m2 'Mach2LauncherNG/S1/Status/S1.status.json') (& $st $now.AddSeconds(-20) $now.AddMinutes(-20) 'LOADING' 12.5)
$s2 = & $st $now.AddMinutes(-9.25) $now.AddHours(-2) 'SHOWING' $null; $s2.Instance = 'S2'; $s2.Remove('ScreenWhitePercent'); $s2.PageWhitePercent = 40
Write-KfwDemoJson (Join-KfwPath $m2 'Mach2LauncherNG/S2/Status/S2.status.json') $s2
[IO.File]::WriteAllText((Join-KfwPath $m2 'mwst.log'), 'x')
[IO.File]::SetLastWriteTimeUtc((Join-KfwPath $m2 'mwst.log'), $now.AddMinutes(-7.37))
[IO.File]::WriteAllText((Join-KfwPath $m2 'mwst_events.csv'), $header + (& $f @((& $g), (& $iso $now.AddDays(-1)), '', 'MWEB2', 'AGENT_START', 'INFO', 'STARTED', '', '', '', '1.01NG', (& $iso $now.AddDays(-1)), 'started')))

# --- MWEB3: an old watchdog, a log and no ledger ------------------------------------------------
$m3 = Get-KfwDemoDocs $root 'MWEB3'
[void][IO.Directory]::CreateDirectory($m3)
[IO.File]::WriteAllText((Join-KfwPath $m3 'mwst.log'), 'x')
[IO.File]::SetLastWriteTimeUtc((Join-KfwPath $m3 'mwst.log'), $now.AddMinutes(-2))

# --- WWEB1: Web Launcher; PWEB2: signed in as someone else -------------------------------------
$w1 = Join-KfwPath (Get-KfwDemoDocs $root 'WWEB1') 'WebLauncher/S2'
[void][IO.Directory]::CreateDirectory((Join-KfwPath $w1 'Status'))
[IO.File]::WriteAllText((Join-KfwPath (Get-KfwDemoDocs $root 'WWEB1') 'WebLauncher/WebLauncher.ps1'), '# fake')
[IO.File]::WriteAllText((Join-KfwPath $w1 'WWEB1.json'), '{"DisplayURL":"https://intranet"}')
Write-KfwDemoJson (Join-KfwPath $w1 'Status/S2.status.json') ([ordered]@{ Instance = 'S2'; State = 'BROWSING'; LauncherVersion = '1.0.3'; EdgeVersion = 'Edg/154.0'; UpdatedUtc = (Format-KfwDemoIso $now.AddSeconds(-5)); StateSinceUtc = (Format-KfwDemoIso $now.AddMinutes(-3)); Reloads = 1; BrowserStarts = 1; LastError = ''; PcBootUtc = (Format-KfwDemoIso $now.AddHours(-30)) })
$p2 = Join-KfwPath (Get-KfwDemoDocs $root 'PWEB2') 'PbiLauncher/S1'
[void][IO.Directory]::CreateDirectory((Join-KfwPath $p2 'Status'))
[IO.File]::WriteAllText((Join-KfwPath (Get-KfwDemoDocs $root 'PWEB2') 'PbiLauncher/PbiLauncher.ps1'), '# fake')
[IO.File]::WriteAllText((Join-KfwPath $p2 'PWEB2.json'), '{}')
Write-KfwDemoJson (Join-KfwPath $p2 'Status/S1.status.json') ([ordered]@{ Instance = 'S1'; State = 'SHOWING'; LauncherVersion = '2.0.1'; UpdatedUtc = (Format-KfwDemoIso $now.AddSeconds(-50)); StateSinceUtc = (Format-KfwDemoIso $now.AddMinutes(-90)); UserName = 'kiosk@contoso.test'; SignedInAs = 'other@contoso.test'; SignIns = 4; Reloads = 0; BrowserStarts = 2; LastError = 'MFA'; PcBootUtc = (Format-KfwDemoIso $now.AddDays(-2)) })

# --- the same kiosk list and history in both data folders ---------------------------------------
$list = "Host,Location,Type,HasMwst,Active,RestartGroup,Info,Version`nMWEB1,LINE 1,Mach2,Y,,A,first,7`nMWEB2,LINE2,Mach2,Y,,A,,`nMWEB3,LINE3,Mach2,Y,yes,B,,`nWWEB1,HALL,Web board,,,,,`nPWEB1,APU1,PBI,,,,,`nPWEB2,APU2,PBI - SR,,,,,`nGHOST1,NOWHERE,PBI,,,,,`nGONE1,OLD,Mach2,Y,N,,,`nSPARE1,DESK,Desk,,,,,`n"
Write-KfwDemoEvents (Join-Path $dataPs 'MWST_FleetEvents.csv') 40
foreach ($d in $dataPy, $dataPs) {
    [IO.File]::WriteAllText((Join-Path $d 'kiosk-list.csv'), $list)
    if ($d -ne $dataPs) {
        Copy-Item (Join-Path $dataPs 'MWST_FleetEvents.csv') $d
        Copy-Item (Join-Path $dataPs 'MWST_FleetEvents.status.json') $d
    }
}

# --- scan, twice each ------------------------------------------------------------------------------
$template = Join-KfwPath $root '{0}/Users/Public/Documents'
$py = @"
import sys, datetime
sys.path.insert(0, sys.argv[1])
from pathlib import Path
import kfw.collector as c
from kfw.config import Settings
now = datetime.datetime.fromisoformat(sys.argv[4]).replace(tzinfo=datetime.timezone.utc)
c.utcnow = lambda: now
s = Settings(data_dir=Path(sys.argv[2]), share_template=sys.argv[3], parallel_hosts=4, host_timeout_seconds=30, offline_ok=True)
sys.exit(c.run_scan(s))
"@
$pyFile = Join-Path $WorkDir 'scan.py'
[IO.File]::WriteAllText($pyFile, $py)
$settings = New-KfwSettings
$settings.DataDir = $dataPs; $settings.ShareTemplate = $template; $settings.ParallelHosts = 4; $settings.HostTimeoutSeconds = 30; $settings.OfflineOk = $true
foreach ($i in 1, 2) {
    $at = $now.AddMinutes(($i - 1) * 61)
    & python3 -I $pyFile $PythonRepo $dataPy $template $at.ToString('yyyy-MM-ddTHH:mm:ss') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "the Python scan failed ($LASTEXITCODE)" }
    $code = Invoke-KfwScan -Settings $settings -Now $at -Quiet
    if ($code -ne 0) { throw "this scan failed ($code)" }
}

# --- compare ----------------------------------------------------------------------------------------
function Get-Normalised([string]$Path) {
    # The rows, with the run's own row reduced to what must agree.
    $text = [IO.File]::ReadAllText($Path)
    $rows = [KioskFleetWeb.Csv]::Rows($text.TrimStart([char]0xFEFF))
    foreach ($r in $rows) {
        if ($r['EventType'] -eq 'COLLECTOR_RUN') {
            $r['DurationSeconds'] = '-'
            $r['Detail'] = ($r['Detail'] -replace '^v[^;]+;', 'v-;' -replace 'runner=.*$', 'runner=-' -replace 'list=[^;]*', 'list=-')
        }
    }
    return [KioskFleetWeb.Csv]::Write($rows, (& (Get-Module KioskFleetWeb) { $script:Columns }), $true)
}
$a = Get-Normalised (Join-Path $dataPy 'MWST_FleetEvents.csv')
$b = Get-Normalised (Join-Path $dataPs 'MWST_FleetEvents.csv')
$bomA = [IO.File]::ReadAllBytes((Join-Path $dataPy 'MWST_FleetEvents.csv'))[0..2] -join ','
$bomB = [IO.File]::ReadAllBytes((Join-Path $dataPs 'MWST_FleetEvents.csv'))[0..2] -join ','
$la = $a -split "`r`n"; $lb = $b -split "`r`n"
$diffs = 0
for ($i = 0; $i -lt [Math]::Max($la.Count, $lb.Count); $i++) {
    if ($la[$i] -cne $lb[$i]) {
        $diffs++
        if ($diffs -le 10) { Write-Host "line $($i + 1):`n  py: $($la[$i])`n  ps: $($lb[$i])" }
    }
}
$rawA = [IO.File]::ReadAllText((Join-Path $dataPy 'MWST_FleetEvents.csv'))
$rawB = [IO.File]::ReadAllText((Join-Path $dataPs 'MWST_FleetEvents.csv'))
Write-Host "events CSV: $($la.Count - 1) rows (Python) / $($lb.Count - 1) (PowerShell), $diffs line(s) differ; BOM $bomA / $bomB; line endings $(([regex]::Matches($rawA, "`r`n")).Count) / $(([regex]::Matches($rawB, "`r`n")).Count)"

$sa = ConvertFrom-Json (Read-KfwFileText (Join-Path $dataPy 'MWST_FleetEvents.status.json')) -AsHashtable -Depth 30
$sb = ConvertFrom-Json (Read-KfwFileText (Join-Path $dataPs 'MWST_FleetEvents.status.json')) -AsHashtable -Depth 30
foreach ($k in 'CollectorVersion', 'Runner', 'DurationSeconds', 'LastRunLocal') { $sa.Remove($k); $sb.Remove($k) }
$ja = ConvertTo-Json $sa -Depth 30 -Compress; $jb = ConvertTo-Json $sb -Depth 30 -Compress
$sidecarSame = $ja -ceq $jb
Write-Host "status file: $(if ($sidecarSame) { 'the same' } else { "DIFFERENT`n  py: $ja`n  ps: $jb" })"
if ($diffs -or -not $sidecarSame -or $bomA -ne $bomB) { exit 1 }

# --- what the page is sent: the fleet, each kiosk's history, the kiosk list ------------------------
$csv = Join-Path $dataPs 'MWST_FleetEvents.csv'
$hosts = @('MWEB1', 'MWEB2', 'MWEB3', 'PWEB1', 'PWEB2', 'WWEB1', 'GHOST1', 'GONE1', 'OWEB1', 'NOPE1')
$viewPy = @"
import sys, json, datetime
sys.path.insert(0, sys.argv[1])
from pathlib import Path
from kfw.fleetstate import fleet_view, read_fleet_state
from kfw.history import kiosk_history
from kfw.listeditor import ListEditor
from kfw.config import Settings
now = datetime.datetime.fromisoformat(sys.argv[4]).replace(tzinfo=datetime.timezone.utc)
out = {'fleet': fleet_view(read_fleet_state(Path(sys.argv[2]))), 'history': {}}
for h in sys.argv[5].split(','):
    for days in (7, 28, 90):
        out['history'][h + '/' + str(days)] = kiosk_history(Path(sys.argv[2]), h, days, 24, now)
out['list'] = ListEditor(Settings(data_dir=Path(sys.argv[3]))).view()
print(json.dumps(out, default=str))
"@
$viewFile = Join-Path $WorkDir 'views.py'
[IO.File]::WriteAllText($viewFile, $viewPy)
$at = $now.AddMinutes(61)
$pyJson = & python3 -I $viewFile $PythonRepo $csv $dataPs $at.ToString('yyyy-MM-ddTHH:mm:ss') ($hosts -join ',')
$rows = Read-KfwCsvRows $csv
$psOut = [ordered]@{ fleet = Get-KfwFleetView (Read-KfwFleetState $csv $rows); history = [ordered]@{} }
foreach ($h in $hosts) { foreach ($days in 7, 28, 90) { $psOut.history["$h/$days"] = Get-KfwKioskHistory $rows $h $days 24 $at } }
$psOut.list = Get-KfwListView $settings
[IO.File]::WriteAllText((Join-Path $WorkDir 'views-py.json'), $pyJson)
[IO.File]::WriteAllText((Join-Path $WorkDir 'views-ps.json'), (ConvertTo-Json $psOut -Depth 40 -Compress))
$cmp = @"
import json, sys
a = json.load(open(sys.argv[1])); b = json.load(open(sys.argv[2]))
diffs = []
def walk(x, y, path):
    if isinstance(x, bool) or isinstance(y, bool):
        if x is not y: diffs.append((path, x, y))
    elif isinstance(x, (int, float)) and isinstance(y, (int, float)):
        if x != y: diffs.append((path, x, y))
    elif isinstance(x, dict) and isinstance(y, dict):
        for k in sorted(set(x) | set(y)):
            if k not in x or k not in y: diffs.append((path + '.' + k, x.get(k, '<missing>'), y.get(k, '<missing>')))
            else: walk(x[k], y[k], path + '.' + k)
    elif isinstance(x, list) and isinstance(y, list):
        if len(x) != len(y): diffs.append((path + '[len]', len(x), len(y)))
        for i, (p, q) in enumerate(zip(x, y)): walk(p, q, f'{path}[{i}]')
    elif x != y:
        diffs.append((path, x, y))
walk(a, b, '')
for d in diffs[:25]: print('  %s\n    py: %r\n    ps: %r' % d)
print(f'page JSON: {len(diffs)} difference(s)')
sys.exit(1 if diffs else 0)
"@
$cmpFile = Join-Path $WorkDir 'cmp.py'
[IO.File]::WriteAllText($cmpFile, $cmp)
& python3 -I $cmpFile (Join-Path $WorkDir 'views-py.json') (Join-Path $WorkDir 'views-ps.json')
if ($LASTEXITCODE) { exit 1 }
Write-Host 'The same.'
