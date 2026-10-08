# The collector: reboot counting, host statuses, a whole scan of fake
# kiosks, the kiosk list readers, and a scan started from the page.

$script:T0 = [datetime]::new(2026, 9, 1, 8, 0, 0, [DateTimeKind]::Utc)

function New-FlagRow([string]$Type, [double]$Minutes, [string]$Detail = '', [string]$EventId = '', [hashtable]$More = @{}) {
    $v = @{ EventId = $(if ($EventId) { $EventId } else { [guid]::NewGuid().ToString() }); EventTimeUtc = ConvertTo-UtcIso $script:T0.AddMinutes($Minutes)
        Host = 'K1'; EventType = $Type; Detail = $Detail }
    foreach ($k in $More.Keys) { $v[$k] = $More[$k] }
    New-KfwRow $v
}

function Get-Flags($Rows) {
    [void](Update-KfwRebootFlags $Rows $script:T0.AddDays(-30) @())
    , @($Rows | ForEach-Object { , @($_['EventType'], $_['IsCanonicalReboot'], $_['IsScriptReboot'], $_['RebootTrigger']) })
}

# --- one boot is one reboot, however many records describe it -------------------------------
function Test-WatchdogRebootWithThreeWitnessesCountsOnce {
    $trig = [guid]::NewGuid().ToString()
    $rows = @(
        (New-FlagRow 'BOOT' 0),
        (New-FlagRow 'RESTART_TRIGGERED' 60 'Kind=WHITE' $trig),
        (New-FlagRow 'REBOOT_SCRIPT' 61 "id=$($trig.Substring(0, 8)); Process=shutdown.exe" -More @{ RebootTrigger = 'WATCHDOG_WHITE' }),
        (New-FlagRow 'BOOT' 63),
        (New-FlagRow 'RESTART_CONFIRMED' 65 'Kind=WHITE'))
    $canonical = @((Get-Flags $rows) | Where-Object { $_[1] -eq 'TRUE' })
    Assert-That ($canonical.Count -eq 1 -and $canonical[0][0] -eq 'REBOOT_SCRIPT' -and $canonical[0][2] -eq 'TRUE') (ConvertTo-Json $canonical -Compress)
}

function Test-Two1074sForOneRestartCountOnce {
    $rows = @((New-FlagRow 'BOOT' 0), (New-FlagRow 'REBOOT_EXTERNAL' 30 -More @{ RebootTrigger = 'EXTERNAL' }),
        (New-FlagRow 'REBOOT_EXTERNAL' 30.5 -More @{ RebootTrigger = 'EXTERNAL' }), (New-FlagRow 'BOOT' 32))
    $canonical = @((Get-Flags $rows) | Where-Object { $_[1] -eq 'TRUE' })
    Assert-That ($canonical.Count -eq 1 -and $canonical[0][2] -eq 'FALSE') (ConvertTo-Json $canonical -Compress)
}

function Test-TriggerWithoutEventLogStillCounts {
    $rows = @((New-FlagRow 'BOOT' 0), (New-FlagRow 'RESTART_TRIGGERED' 60 'Kind=LOWWHITE' -More @{ RebootTrigger = 'WATCHDOG_LOWWHITE' }), (New-FlagRow 'BOOT' 62))
    $f = Get-Flags $rows
    Assert-Equal @('RESTART_TRIGGERED', 'TRUE', 'TRUE', 'WATCHDOG_LOWWHITE') $f[1]
    Assert-Equal 'FALSE' $f[2][1] 'the boot after it is explained'
}

function Test-FailedTriggerDoesNotCount {
    $trig = [guid]::NewGuid().ToString()
    $rows = @((New-FlagRow 'BOOT' 0), (New-FlagRow 'RESTART_TRIGGERED' 60 'Kind=WHITE' $trig), (New-FlagRow 'RESTART_FAILED' 70 "TriggerEventId=$trig"))
    Assert-That (-not @((Get-Flags $rows) | Where-Object { $_[1] -eq 'TRUE' }).Count) 'no reboot happened'
}

function Test-UnexplainedBootCountsOnlyWithHistory {
    $rows = @((New-FlagRow 'BOOT' 0), (New-FlagRow 'BOOT' 600))
    $f = Get-Flags $rows
    Assert-Equal 'FALSE' $f[0][1] 'the first boot''s interval began before the data does'
    Assert-Equal @('BOOT', 'TRUE', 'FALSE', 'UNEXPLAINED') $f[1]
}

function Test-UnexpectedShutdownBelongsToTheBootItWasWrittenAt {
    $rows = @((New-FlagRow 'BOOT' 0), (New-FlagRow 'BOOT' 600), (New-FlagRow 'REBOOT_UNEXPECTED' 600.2 -More @{ RebootTrigger = 'UNEXPECTED' }))
    Assert-Equal @('REBOOT_UNEXPECTED') @((Get-Flags $rows) | Where-Object { $_[1] -eq 'TRUE' } | ForEach-Object { $_[0] })
}

# --- a whole scan --------------------------------------------------------------------------------
function Set-TestKioskList($Work, [string]$Text) {
    $p = Join-Path $Work.Data 'kiosk-list.csv'
    Set-TestText $p $Text
    return $p
}

function Invoke-TestScan($Work) {
    # A scan id is to the second: never two in the same one.
    $ms = 1050 - [datetime]::UtcNow.Millisecond
    if ($ms -gt 0) { Start-Sleep -Milliseconds $ms }
    $code = Invoke-KfwScan -Settings $Work.Settings -Quiet
    Assert-Equal 0 $code 'the scan succeeds'
    return , (Read-KfwFleetCsv (Get-KfwLocalCsv $Work.Settings)).Rows
}

function Test-ScanEndToEnd {
    $w = New-TestWork
    $now = [datetime]::UtcNow
    # The agent's ledger: a reboot it asked for, and Windows' own records of it.
    $trig = [guid]::NewGuid().ToString()
    $p1074 = ConvertTo-Json -Compress @{ Id = 1074; Provider = 'User32'; RecordId = 4711
        Props = @('C:\Windows\system32\shutdown.exe', 'MWEB1', 'No title', '0x80000000', 'restart', "MWST-WATCHDOG WHITE id=$($trig.Substring(0, 8))", 'NT AUTHORITY\SYSTEM') }
    $p6005 = ConvertTo-Json -Compress @{ Id = 6005; Provider = 'EventLog'; RecordId = 4712; Props = @() }
    $tTrig = $now.AddHours(-2); $t1074 = $tTrig.AddSeconds(5); $tBoot = $tTrig.AddMinutes(2)
    $line = { param([string[]]$f) (($f | ForEach-Object { [KioskFleetWeb.Csv]::Field($_, $false) }) -join ',') + "`r`n" }
    $ledger = Join-Path (Get-TestDocs $w 'MWEB1') 'mwst_events.csv'
    $text = (& $line @($trig, (ConvertTo-UtcIso $tTrig), '', 'MWEB1', 'RESTART_TRIGGERED', 'CRITICAL', 'TRIGGERED', '97.5', '12', '', '1.00NG', (ConvertTo-UtcIso $now.AddHours(-9)), 'Kind=WHITE white for 60s')) +
    (& $line @('x', (ConvertTo-UtcIso $t1074), '', 'MWEB1', 'WINEVENT', '', '', '', '', '', '', '', $p1074)) +
    (& $line @('y', (ConvertTo-UtcIso $tBoot), '', 'MWEB1', 'WINEVENT', '', '', '', '', '', '', '', $p6005)) +
    (& $line @([guid]::NewGuid().ToString(), (ConvertTo-UtcIso $now.AddHours(-1)), '', 'MWEB1', 'WHITE_EPISODE_START', 'WARNING', 'WHITE', '99', '', '', '1.00NG', (ConvertTo-UtcIso $tBoot), 'page white')) +
    "$([guid]::NewGuid()),$(ConvertTo-UtcIso $now),,MWEB1,AGENT_STOP,INFO,STOPPED,,,,1.00NG,"   # mid-append: no newline yet
    [IO.File]::AppendAllText($ledger, $text)

    [void][IO.Directory]::CreateDirectory((Get-TestDocs $w 'NEWWEB1'))
    [void](Set-TestKioskList $w "Host,Location,Type,HasMwst,Active`nMWEB1,LINE1,Mach2,Y,`nPWEB1,APU1,PBI,,`nNEWWEB1,LAB,Mach2,Y,`nGONE1,OLD,Mach2,Y,N`nGHOST1,NOWHERE,PBI,,`n")
    $rows = Invoke-TestScan $w
    $log = Get-Content -Raw (Join-Path (Get-KfwLogDir $w.Settings) 'collector.log')
    Assert-That ($log.Contains('Scan') -and $log.Contains('done')) 'the collector log'

    $status = @{}
    foreach ($r in $rows) { if ($r['EventType'] -eq 'HOST_STATUS') { $status[$r['Host']] = $r } }
    Assert-Equal 'OK' $status.MWEB1['Outcome'] $status.MWEB1['Detail']
    Assert-That ($status.MWEB1['WatchdogRunning'] -eq 'TRUE' -and $status.MWEB1['AgentVersion'] -eq '1.00NG') 'the watchdog'
    Assert-That ($status.MWEB1['Detail'].Contains('launcher=S1:SHOWING') -and $status.MWEB1['Detail'].Contains('ledger=ok(1)')) $status.MWEB1['Detail']
    Assert-That ($status.PWEB1['Outcome'] -eq 'OK' -and $status.PWEB1['AgentVersion'] -eq 'pbi-2.0.0') $status.PWEB1['Detail']
    Assert-Equal 'NO_AGENT' $status.NEWWEB1['Outcome'] 'watchdog expected, no trace of it'
    Assert-Equal 'INACTIVE' $status.GONE1['Outcome']
    Assert-Equal 'NO_ACCESS' $status.GHOST1['Outcome'] 'a kiosk whose share cannot be opened'

    $reboots = @($rows | Where-Object { $_['IsCanonicalReboot'] -eq 'TRUE' })
    Assert-That ($reboots.Count -eq 1 -and $reboots[0]['EventType'] -eq 'REBOOT_SCRIPT' -and $reboots[0]['IsScriptReboot'] -eq 'TRUE') 'one reboot, the watchdog''s'
    Assert-That $reboots[0]['EventId'].StartsWith('EVT-MWEB1-4711-') $reboots[0]['EventId']
    Assert-That (-not @($rows | Where-Object { $_['EventType'] -eq 'AGENT_STOP' }).Count) 'a row mid-append is not taken'
    Assert-Equal 'OK' @($rows | Where-Object { $_['EventType'] -eq 'COLLECTOR_RUN' })[0]['Outcome']
    Assert-That (-not @($rows | Where-Object { $_['Host'] -eq 'MWEB1' -and $_['Location'] -ne 'LINE1' }).Count) 'kiosk attributes follow the list'

    $sidecar = ConvertFrom-Json (Read-KfwFileText (Get-KfwSidecarPath (Get-KfwLocalCsv $w.Settings))) -AsHashtable
    Assert-That ($sidecar.Hosts -eq 4 -and $sidecar.SkippedInactive -eq 1 -and $sidecar.Mach2Launchers.MWEB1.Instances[0].State -eq 'SHOWING') 'the status file'
    Assert-Equal 'kiosk@contoso.test' $sidecar.PbiLaunchers.PWEB1.Instances[0].SignedInAs

    # The file the Power BI report binds to: the same columns, quoted, with a BOM.
    $raw = [IO.File]::ReadAllBytes((Get-KfwLocalCsv $w.Settings))
    Assert-That ($raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF) 'a BOM'
    Assert-That ([Text.Encoding]::UTF8.GetString($raw, 3, 25).StartsWith('"EventId","EventTimeUtc"')) 'quoted header'

    # A second scan right after adds nothing: the same EventIds, no new status rows.
    $count = $rows.Count
    $rows2 = Invoke-TestScan $w
    Assert-Equal $count $rows2.Count 'nothing new is a no-op'
    Assert-Equal $rows2.Count @($rows2 | ForEach-Object { $_['EventId'] } | Sort-Object -Unique).Count 'no EventId twice'

    # A kiosk going quiet is a status change, and gets a row.
    Remove-Item (Join-Path (Get-TestDocs $w 'MWEB1') 'mwst.log')
    $rows3 = Invoke-TestScan $w
    $latest = @($rows3 | Where-Object { $_['Host'] -eq 'MWEB1' -and $_['EventType'] -eq 'HOST_STATUS' } | Sort-Object { $_['EventTimeUtc'] + $_['EventId'] })[-1]
    Assert-Equal 'STALE' $latest['Outcome']
}

function Test-ScanFillsTheDashboard {
    $w = New-TestWork
    [void](Set-TestKioskList $w "Host,Location,Type,HasMwst`nMWEB1,LINE1,Mach2,Y`nPWEB1,APU1,PBI,`n")
    [void](Invoke-TestScan $w)
    $v = Get-KfwFleetView (Read-KfwFleetState (Get-KfwLocalCsv $w.Settings) $null)
    $hosts = @{}; foreach ($k in $v.Kiosks) { $hosts[$k.Host] = $k }
    Assert-That ($v.Ok -and $v.Total -eq 2 -and $v.Attention -eq 0) "total $($v.Total) attention $($v.Attention)"
    Assert-Equal 'SHOWING' $hosts.MWEB1.Launchers.Mach2.State
    Assert-Equal 'PBI' $hosts.PWEB1.Screens[0].Kind
}

function Test-ExcelSavedCsvIsLeftAlone {
    $w = New-TestWork
    [void](Set-TestKioskList $w "Host,Type,HasMwst`nMWEB1,Mach2,Y`n")
    Set-TestText (Get-KfwLocalCsv $w.Settings) "EventId;EventTimeUtc;EventType`n1;2;3`n"
    Assert-Equal 1 (Invoke-KfwScan -Settings $w.Settings -Quiet)
    Assert-That ((Get-Content -Raw (Get-KfwLocalCsv $w.Settings)).StartsWith('EventId;')) 'never overwritten with a copy missing its history'
}

function Test-PublishedCopyIsRestoredFromTheLocalOne {
    $w = New-TestWork
    [void](Set-TestKioskList $w "Host,Type,HasMwst`nMWEB1,Mach2,Y`n")
    $pub = Join-Path $w.Dir 'sharepoint/MWST_FleetEvents.csv'
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($pub))
    $w.Settings.PublishCsv = $pub
    [void](Invoke-TestScan $w)
    $n = (Read-KfwFleetCsv $pub).Rows.Count
    Remove-Item $pub
    [void](Invoke-TestScan $w)
    Assert-That ((Read-KfwFleetCsv $pub).Rows.Count -ge $n) 'restored'
}

# --- kiosk lists -------------------------------------------------------------------------------------
function New-TestXlsx([string]$Path, $Rows) {
    $shared = [Collections.Generic.List[string]]::new()
    $col = { param([int]$i) $s = ''; $i++; while ($i) { $r = ($i - 1) % 26; $i = [Math]::Floor(($i - 1) / 26); $s = [char](65 + $r) + $s }; $s }
    $sheetRows = [Text.StringBuilder]::new()
    $rn = 2   # a title row above the table
    foreach ($r in $Rows) {
        [void]$sheetRows.Append("<row r=`"$rn`">")
        for ($ci = 0; $ci -lt $r.Count; $ci++) {
            $v = $r[$ci]
            if (-not $v) { continue }
            if (-not $shared.Contains($v)) { $shared.Add($v) }
            [void]$sheetRows.Append("<c r=`"$(& $col $ci)$rn`" t=`"s`"><v>$($shared.IndexOf($v))</v></c>")
        }
        [void]$sheetRows.Append('</row>')
        $rn++
    }
    $ns = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
    Add-Type -AssemblyName System.IO.Compression
    $fs = [IO.File]::Create($Path)
    $z = [IO.Compression.ZipArchive]::new($fs, [IO.Compression.ZipArchiveMode]::Create)
    $put = { param($name, $text) $e = $z.CreateEntry($name); $s = [IO.StreamWriter]::new($e.Open()); $s.Write($text); $s.Dispose() }
    & $put 'xl/workbook.xml' "<workbook $ns xmlns:r=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships`"><sheets><sheet name=`"KIOSKS`" sheetId=`"1`" r:id=`"rId1`"/></sheets></workbook>"
    & $put 'xl/_rels/workbook.xml.rels' '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="worksheet" Target="worksheets/sheet1.xml"/></Relationships>'
    & $put 'xl/sharedStrings.xml' ("<sst $ns>" + (($shared | ForEach-Object { "<si><t>$_</t></si>" }) -join '') + '</sst>')
    & $put 'xl/worksheets/sheet1.xml' "<worksheet $ns><sheetData><row r=`"1`"><c r=`"A1`" t=`"inlineStr`"><is><t>Kiosks</t></is></c></row>$($sheetRows.ToString())</sheetData></worksheet>"
    $z.Dispose(); $fs.Dispose()
}

function Test-XlsxKioskList {
    $p = Join-Path (New-TestWork).Dir 'MASTER_KIOSK LIST.xlsx'
    New-TestXlsx $p @(
        @('NAME', 'LOCATION', 'TYPE', 'HAS MWST', 'ACTIVE', 'RESTART GROUP'),
        @('MWEB1', 'LINE1', 'Mach2', 'Y', '', 'A'),
        @('PWEB1', 'APU1', 'PBI - SR', '', '', ''),
        @('WWEB1', 'HALL', 'Web board', '', '', ''),
        @('OLD1', 'X', 'Mach2', 'Y', 'N', ''),
        @('MISC1', 'Y', 'Signage', '', '', ''),
        @('mweb1', 'dup', 'Mach2', 'Y', '', ''))
    $r = Import-KfwKioskList $p
    Assert-Equal @('MWEB1', 'PWEB1', 'WWEB1') @($r.Kiosks | ForEach-Object { $_.Host })
    Assert-That ($r.Kiosks[0].RunsWatchdog -and $r.Kiosks[0].RestartGroup -eq 'A') 'the watchdog kiosk'
    Assert-That ($r.Kiosks[1].PingOnly -and -not $r.Kiosks[1].RunsWatchdog) 'Power BI is ping-only'
    Assert-That ($r.Stats.Inactive -eq 1 -and $r.Stats.NotFlagged -eq 1 -and $r.Stats.InactiveRows[0].Host -eq 'OLD1') 'the stats'
}

function Test-TxtKioskList {
    $p = Join-Path (New-TestWork).Dir 'kiosks.txt'
    Set-TestText $p "# the line`nMWEB1`n`nMWEB2`n"
    $r = Import-KfwKioskList $p
    Assert-Equal @('MWEB1', 'MWEB2') @($r.Kiosks | ForEach-Object { $_.Host })
    Assert-That (-not @($r.Kiosks | Where-Object { -not $_.RunsWatchdog }).Count) 'everything in a .txt runs the watchdog'
}

# --- a scan from the page ------------------------------------------------------------------------------
function Test-ScanFromThePage {
    $w = New-TestWork
    [void](Set-TestKioskList $w "Host,Location,Type,HasMwst`nMWEB1,LINE1,Mach2,Y`nPWEB1,APU1,PBI,`n")
    $srv = Start-TestServer $w -Fleet
    $admin = New-TestAdmin $srv
    $r = Send-Test $admin '/api/scan'
    Assert-Equal 202 $r.Status $r.Text
    Assert-Equal 409 (Send-Test $admin '/api/scan').Status 'one run at a time'
    $deadline = [datetime]::UtcNow.AddSeconds(90)
    do { Start-Sleep -Milliseconds 300; $run = (Get-Test $admin '/api/run' @{ from = 0 }).Json } while ($run.running -and [datetime]::UtcNow -lt $deadline)
    Assert-That ($run.last -and $run.last.Code -eq 0) "the scan: $($run.text)"
    Assert-That ($run.text.Contains('Fleet scan') -and $run.text.Contains('finished with code 0') -and $run.text.Contains('MWEB1')) $run.text
    $reports = (Get-Test $admin '/api/reports').Json.reports
    Assert-That ($reports.Count -and (Get-Test $admin "/api/reports/$($reports[0].name)").Status -eq 200) 'the scan output is kept'
    $deadline = [datetime]::UtcNow.AddSeconds(10)
    do { Start-Sleep -Milliseconds 300; $f = (Get-Test $admin '/api/state').Json.fleet } while ($f.Collector.Hosts -ne 2 -and [datetime]::UtcNow -lt $deadline)
    Assert-That ($f.Collector.Hosts -eq 2 -and $f.Collector.Version -eq '6.2-ps') 'the dashboard reads the new scan'
    $acts = @(Get-TestAudit $admin | ForEach-Object { $_.Action })
    Assert-That ($acts -contains 'scan' -and $acts -contains 'scan-finished') 'audited'
}

function Test-StopARun {
    $w = New-TestWork
    $app = New-KfwApp $w.Settings
    Set-KfwContext $app
    $why = Start-KfwRun $app 'Slow thing' 'scan' @('-NoProfile', '-Command', "Write-Host working; Start-Sleep 30") -Session @{ user = 'webadmin'; role = 'admin' }
    Assert-Equal $null $why
    Start-Sleep -Milliseconds 1500
    Assert-Equal $null (Stop-KfwRun $app @{ user = 'webadmin'; role = 'admin' })
    $deadline = [datetime]::UtcNow.AddSeconds(10)
    while ($app.Runner.Run -and [datetime]::UtcNow -lt $deadline) { Update-KfwRunner $app; Start-Sleep -Milliseconds 100 }
    Assert-That ($null -eq $app.Runner.Run -and $app.Runner.Last.Code -ne 0) "stopped: $(ConvertTo-Json $app.Runner.Last -Compress)"
    Assert-That ((Read-KfwRunLog $app 0).text.Contains('stopped by webadmin')) 'the log says who stopped it'
}
