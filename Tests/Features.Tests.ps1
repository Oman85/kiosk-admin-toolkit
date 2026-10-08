# A kiosk's history, the kiosk list edited in the app, and actions on many
# kiosks at once.

# --- history -------------------------------------------------------------------------------------
function Write-HistoryEvents([string]$Path, $Rows) {
    $cols = & (Get-Module KioskFleetWeb) { $script:Columns }
    $out = [Collections.Generic.List[object]]::new()
    foreach ($pair in $Rows) {
        $when = $pair[0]; $v = $pair[1]
        $r = [ordered]@{}
        foreach ($c in $cols) { $r[$c] = '' }
        $r.EventId = "id-$($v.Count)-$($when.Ticks)-$($v.EventType)"
        $r.EventTimeUtc = ConvertTo-UtcIso $when; $r.EventTimeLocal = ConvertTo-LocalIso $when; $r.EventDate = ConvertTo-LocalDate $when
        $r.Host = 'K1'; $r.Location = 'LINE9'; $r.KioskType = 'Mach2'
        foreach ($k in $v.Keys) { $r[$k] = $v[$k] }
        $out.Add($r)
    }
    [IO.File]::WriteAllText($Path, [KioskFleetWeb.Csv]::Write($out, $cols, $true), [Text.UTF8Encoding]::new($true))
}

function Test-HistoryTimeline {
    $now = [datetime]::new(2026, 9, 30, 12, 0, 0, [DateTimeKind]::Utc)
    $start = Get-LocalMidnightUtc ([datetime]::new(2026, 9, 24))   # 7 days: midnight local, six days ago
    $st = { param($s, [hashtable]$v = @{}) $h = @{ EventType = 'HOST_STATUS'; Outcome = $s }; foreach ($k in $v.Keys) { $h[$k] = $v[$k] }; $h }
    $p = Join-Path (New-TestWork).Dir 'e.csv'
    Write-HistoryEvents $p @(
        @($start.AddHours(-6), (& $st 'OK')),                      # before the window: in effect at its start
        @($start.AddHours(10), (& $st 'OFFLINE')),
        @($start.AddHours(12), (& $st 'OK' @{ UptimeHours = '1' })),
        @($start.AddHours(14), @{ EventType = 'RESTART_TRIGGERED'; IsCanonicalReboot = 'TRUE'; IsScriptReboot = 'TRUE'; RebootTrigger = 'WATCHDOG_WHITE' }),
        @($start.AddHours(20), @{ EventType = 'WHITE_EPISODE_START' }),
        @($start.AddDays(1), (& $st 'OK')),
        # nothing for three days: the collector was off
        @($start.AddDays(4), (& $st 'STALE')),
        @($start.AddDays(4).AddHours(6), @{ EventType = 'REBOOT_EXTERNAL'; IsCanonicalReboot = 'TRUE'; RebootTrigger = 'EXTERNAL' }),
        @($start.AddDays(6), (& $st 'OK' @{ UptimeHours = '18' })))
    $rows = Read-KfwCsvRows $p
    $h = Get-KfwKioskHistory $rows 'k1' 7 24 $now
    Assert-That ($h.Found -and $h.Location -eq 'LINE9') 'found'
    $kinds = @($h.Timeline | ForEach-Object { $_.Status })
    Assert-Equal @('OK', 'OFFLINE', 'OK', 'NO_DATA') @($kinds[0..3])
    Assert-That ($kinds -contains 'STALE' -and $kinds[-1] -eq 'OK') ($kinds -join ',')
    $w = 0.0; foreach ($t in $h.Timeline) { $w += $t.Width }
    Assert-That ([Math]::Abs($w - 100) -lt 0.1) "the blocks fill the bar ($w)"
    Assert-That ($h.Reboots -eq 2 -and $h.ScriptReboots -eq 1 -and $h.Episodes -eq 1) 'reboots and episodes'
    Assert-That ($h.PerDay.Count -eq 7 -and $h.PerDay[0].Script -eq 1) 'per day'
    Assert-That ($h.PerDay[0].OkPct -lt 100 -and $null -eq $h.PerDay[3].OkPct) 'a day nobody scanned has no figure'
    Assert-That ($h.Availability -gt 0 -and $h.Availability -lt 100 -and $h.Coverage -lt 100) "availability $($h.Availability) coverage $($h.Coverage)"
    Assert-That ($h.Runs[0].Running -and $h.Runs[-1].Open) 'newest run first; the oldest began before the window'
    Assert-That ($h.Runs[1].EndedBy -eq 'external' -and $h.Runs[2].EndedBy -eq 'the watchdog') "$($h.Runs[1].EndedBy) / $($h.Runs[2].EndedBy)"
    Assert-That ($h.UptimeHours -and $h.UptimeHours -gt 18) "uptime $($h.UptimeHours)"
    Assert-Equal 'REBOOT_EXTERNAL' $h.Events[0].Type 'newest first'
    Assert-Equal $false (Get-KfwKioskHistory $rows 'nobody' 7 24 $now).Found
}

function Test-HistoryApi {
    $w = New-TestWork
    Write-KfwDemoEvents (Get-KfwLocalCsv $w.Settings) 63
    $srv = Start-TestServer $w -Fleet
    $admin = New-TestAdmin $srv; $op = New-TestOperator $srv
    $r = Get-Test $op '/api/kiosks/MWEB2/history' @{ days = 28 }
    Assert-Equal 200 $r.Status $r.Text
    $h = $r.Json
    Assert-That ($h.Host -eq 'MWEB2' -and $h.PerDay.Count -eq 28 -and $h.Timeline.Count -and $h.Status -eq 'STALE') 'the history'
    Assert-That ($h.Reboots -ge 2 -and @($h.Events | Where-Object { $_.Type -eq 'RESTART_TRIGGERED' }).Count) 'its reboots'
    Assert-Equal 90 (Get-Test $admin '/api/kiosks/MWEB2/history' @{ days = 90 }).Json.Days
    Assert-Equal 400 (Get-Test $admin '/api/kiosks/MWEB2/history' @{ days = 0 }).Status
    Assert-Equal 404 (Get-Test $admin '/api/kiosks/NOPE1/history').Status
    Assert-Equal 400 (Get-Test $admin '/api/kiosks/bad name/history').Status
}

# --- the kiosk list ------------------------------------------------------------------------------
function Test-KioskListEditing {
    $w = New-TestWork
    $srv = Start-TestServer $w -Fleet
    $admin = New-TestAdmin $srv; $op = New-TestOperator $srv
    $data = $w.Data
    Set-TestText (Join-Path $data 'kiosk-list.txt') "MWEB1`nMWEB2`n"
    Assert-Equal 403 (Get-Test $op '/api/kiosklist').Status
    $v = (Get-Test $admin '/api/kiosklist').Json
    Assert-That ($v.editable -and $v.converts) 'a .txt converts'
    Assert-Equal @('MWEB1', 'MWEB2') @($v.rows | ForEach-Object { $_.host })

    $r = Send-Test $admin '/api/kiosklist' @{ host = 'PWEB1'; location = 'APU1'; type = 'PBI'; watchdog = $false }
    Assert-Equal 200 $r.Status $r.Text
    Assert-That ((Test-Path (Join-Path $data 'kiosk-list.csv')) -and -not (Test-Path (Join-Path $data 'kiosk-list.txt'))) 'now a .csv'
    Assert-That (Test-Path (Join-Path $data 'kiosk-list-before-edit.txt')) 'the upload is kept aside'
    $v = (Get-Test $admin '/api/kiosklist').Json
    Assert-That (-not $v.converts -and $v.total -eq 3 -and $v.scanned -eq 3) 'three, all scanned'

    Assert-Equal 409 (Send-Test $admin '/api/kiosklist' @{ host = 'mweb1' }).Status 'no kiosk twice'
    Assert-Equal 400 (Send-Test $admin '/api/kiosklist' @{ host = 'bad name!' }).Status
    Assert-Equal 400 (Send-Test $admin '/api/kiosklist' @{ host = 'X1'; location = "two`nlines" }).Status
    $stale = Send-Test $admin '/api/kiosklist' @{ row = 0; was = 'SOMEONE'; host = 'MWEB1' }
    Assert-That ($stale.Status -eq 409 -and $stale.Json.error.Contains('changed')) $stale.Text

    $r = Send-Test $admin '/api/kiosklist' @{ row = 1; was = 'MWEB2'; host = 'MWEB2'; location = 'LINE2'; type = 'Mach2'; watchdog = $true; restartGroup = 'A' }
    Assert-That ($r.Status -eq 200 -and $r.Json.change.Contains("location '' -> 'LINE2'")) $r.Text
    Assert-Equal 200 (Send-Test $admin '/api/kiosklist/active' @{ row = 1; was = 'MWEB2'; active = $false }).Status
    $imp = Import-KfwKioskList (Join-Path $data 'kiosk-list.csv')
    Assert-That ((@($imp.Kiosks | ForEach-Object { $_.Host }) -join ',') -eq 'MWEB1,PWEB1' -and $imp.Stats.Inactive -eq 1) 'not active: kept, not scanned'
    $row = (Get-Test $admin '/api/kiosklist').Json.rows | Where-Object { $_.host -eq 'MWEB2' }
    Assert-That (-not $row.scanned -and $row.why -eq 'inactive' -and $row.location -eq 'LINE2' -and $row.restartGroup -eq 'A') (ConvertTo-Json $row -Compress)

    Assert-Equal 200 (Send-Test $admin '/api/kiosklist/remove' @{ row = 0; was = 'MWEB1' }).Status
    Assert-Equal @('MWEB2', 'PWEB1') @((Get-Test $admin '/api/kiosklist').Json.rows | ForEach-Object { $_.host })
    Assert-That ((Get-Test $admin '/api/settings/kiosk-list').Text.TrimStart([char]0xFEFF).StartsWith('Host,Location,Type,HasMwst,Active')) 'the download'
    $acts = @(Get-TestAudit $admin 'kiosk-list' | ForEach-Object { $_.Action })
    foreach ($a in 'kiosk-list-add', 'kiosk-list-edit', 'kiosk-list-remove') { Assert-That ($acts -contains $a) "audited: $a" }

    # An upload replaces the edited list, as before.
    $up = Send-TestUpload $admin 'kiosks.csv' ([Text.Encoding]::UTF8.GetBytes("Host,Location,Type,HasMwst`nMWEB3,LINE3,Mach2,Y`n"))
    Assert-That ($up.Status -eq 200 -and -not (Test-Path (Join-Path $data 'kiosk-list-before-edit.txt'))) $up.Text
    Assert-Equal @('MWEB3') @((Get-Test $admin '/api/kiosklist').Json.rows | ForEach-Object { $_.host })
}

function Test-KioskListFromXlsxKeepsEveryRow {
    $w = New-TestWork
    $srv = Start-TestServer $w -Fleet
    $admin = New-TestAdmin $srv
    New-TestXlsx (Join-Path $w.Data 'kiosk-list.xlsx') @(@('NAME', 'TYPE', 'HAS MWST', 'ACTIVE', 'LOCATION'),
        @('MWEB1', 'Mach2', 'Y', '', 'LINE1'), @('OLD1', 'Mach2', 'Y', 'N', 'GONE'), @('SPARE1', 'Desk', '', '', ''))
    $v = (Get-Test $admin '/api/kiosklist').Json
    Assert-Equal @('MWEB1|', 'OLD1|inactive', 'SPARE1|not flagged') @($v.rows | ForEach-Object { "$($_.host)|$($_.why)" })
    Assert-Equal 200 (Send-Test $admin '/api/kiosklist/active' @{ row = 1; was = 'OLD1'; active = $true }).Status
    Assert-That ((Test-Path (Join-Path $w.Data 'kiosk-list-before-edit.xlsx')) -and -not (Test-Path (Join-Path $w.Data 'kiosk-list.xlsx'))) 'the .xlsx is kept aside'
    $rows = (Get-Test $admin '/api/kiosklist').Json.rows
    Assert-That ((@($rows | ForEach-Object { $_.host }) -join ',') -eq 'MWEB1,OLD1,SPARE1' -and $rows[1].scanned -and -not $rows[2].scanned) 'every row kept'
}

function Test-KioskListFixedByEnvironment {
    $w = New-TestWork
    $p = Join-Path $w.Data 'fixed.csv'
    Set-TestText $p "Host`nMWEB1`n"
    $srv = Start-TestServer $w -Fleet -Env @{ KFW_KIOSK_LIST = $p }
    $a = New-TestAdmin $srv
    $v = (Get-Test $a '/api/kiosklist').Json
    Assert-That ($v.fixed -and -not $v.editable -and $v.rows[0].host -eq 'MWEB1') (ConvertTo-Json $v -Compress)
    Assert-Equal 409 (Send-Test $a '/api/kiosklist' @{ host = 'MWEB2' }).Status
    Assert-Equal "Host`nMWEB1`n" (Get-Content -Raw $p)
}

# --- many kiosks at once --------------------------------------------------------------------------
function Test-GroupReload {
    $srv = Start-TestServer (New-TestWork) -Fleet
    $op = New-TestOperator $srv
    $r = Send-Test $op '/api/group/reload' @{ hosts = @('MWEB1', 'PWEB1', 'MWEB3', 'NOPE1', 'mweb1') }
    Assert-Equal 202 $r.Status $r.Text
    $g = $r.Json
    Assert-Equal @('MWEB1', 'PWEB1') @($g.jobs | ForEach-Object { $_.host } | Sort-Object) 'each kiosk once'
    $why = @{}; foreach ($x in $g.skipped) { $why[$x.host] = $x.why }
    Assert-Equal @{ MWEB3 = 'not on the new launcher yet'; NOPE1 = 'not in the last scan' } $why
    $done = Wait-TestJobs $op $g.jobs
    Assert-That (-not @($done.Values | Where-Object { -not $_.ok }).Count) (ConvertTo-Json $done -Compress -Depth 5)
    Assert-That ((Get-Content -Raw (Join-Path $srv.Work.Dirs.ng 'taken.refresh.txt')).Contains('webop (operator)')) 'who asked'
}

function Test-GroupMessageAndRules {
    $srv = Start-TestServer (New-TestWork) -Fleet
    $admin = New-TestAdmin $srv; $op = New-TestOperator $srv
    $r = Send-Test $op '/api/group/message' @{ hosts = @('MWEB1', 'PWEB1', 'MWEB3'); text = 'Line stops at 2'; seconds = 30 }
    Assert-Equal 202 $r.Status $r.Text
    $g = $r.Json
    Assert-Equal @('MWEB1') @($g.jobs | ForEach-Object { $_.host })
    Assert-Equal @('MWEB3', 'PWEB1') @($g.skipped | ForEach-Object { $_.host } | Sort-Object)
    $done = Wait-TestJobs $op $g.jobs
    Assert-That $done.MWEB1.ok (ConvertTo-Json $done -Compress -Depth 5)

    Assert-Equal 400 (Send-Test $op '/api/group/message' @{ hosts = @('MWEB1') }).Status 'no text'
    Assert-Equal 404 (Send-Test $op '/api/group/restart' @{ hosts = @('MWEB1') }).Status 'no restarting a whole line'
    Assert-Equal 400 (Send-Test $op '/api/group/reload' @{ hosts = @() }).Status
    Assert-Equal 400 (Send-Test $op '/api/group/reload' @{ hosts = @(1..501 | ForEach-Object { 'X' }) }).Status
    $nothing = Send-Test $op '/api/group/reload' @{ hosts = @('MWEB3') }
    Assert-That ($nothing.Status -eq 409 -and $nothing.Json.error.Contains('MWEB3')) $nothing.Text
    Assert-Equal 403 (Send-Test $op '/api/group/reload' @{ hosts = @('MWEB1') } -NoCsrf).Status
    $acts = Get-TestAudit $admin 'group-'
    Assert-That (@($acts | Where-Object { $_.Action -eq 'group-message' -and $_.User -eq 'webop' -and $_.Detail.Contains('Line stops at 2') }).Count) 'the message is audited'
    Assert-That (@($acts | Where-Object { $_.Action -eq 'group-reload' -and $_.Result -eq 'refused' }).Count) 'a refusal is audited'
}

function Test-GroupSkipsBusy {
    $srv = Start-TestServer (New-TestWork) -Fleet
    $admin = New-TestAdmin $srv
    $r1 = Send-Test $admin '/api/kiosks/MWEB1/message' @{ text = 'one'; seconds = 30 }
    Assert-Equal 202 $r1.Status
    $r = Send-Test $admin '/api/group/live' @{ hosts = @('MWEB1', 'PWEB1') }
    Assert-Equal 202 $r.Status $r.Text
    $g = $r.Json
    Assert-That ((@($g.jobs | ForEach-Object { $_.host }) -join ',') -eq 'PWEB1' -and $g.skipped[0].why.StartsWith('busy')) (ConvertTo-Json $g -Compress)
    [void](Wait-TestJobs $admin (@($g.jobs) + @(@{ host = 'MWEB1'; job = $r1.Json.job })))
}
