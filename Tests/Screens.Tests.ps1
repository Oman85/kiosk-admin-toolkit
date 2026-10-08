# The Screens page: the newest screenshot of every kiosk screen, taken one
# kiosk at a time or for many at once, and old ones pruned.

function New-TestPicture([string]$Folder, [string]$HostName, [string]$Screen, [datetime]$When, [hashtable]$Info = @{}) {
    $p = Join-Path $Folder "$($HostName)_$($Screen)_$($When.ToString('yyyyMMdd-HHmmss')).png"
    [IO.File]::WriteAllText($p, 'png')
    if ($Info.Count) { Write-KfwScreenInfo $p $Info }
    return $p
}

function Test-LatestAndPrune {
    $dir = Join-Path (New-TestWork).Dir 'shots'
    [void][IO.Directory]::CreateDirectory($dir)
    $now = [datetime]::new(2026, 10, 5, 12, 0, 0)
    $keep = & (Get-Module KioskFleetWeb) { $script:KeepPerScreen }
    for ($i = 0; $i -lt $keep + 3; $i++) { [void](New-TestPicture $dir 'MWEB1' 'S1' $now.AddMinutes(-$i) @{ State = 'SHOWING'; Url = "http://x/$i" }) }
    [void](New-TestPicture $dir 'MWEB1' 'S2' $now.AddHours(-2))
    [void](New-TestPicture $dir 'OLD_ONE' 'S1' $now.AddDays(-40))      # the only one: kept however old
    [void](New-TestPicture $dir 'OLD_ONE' 'S1' $now.AddDays(-41))
    Set-TestText (Join-Path $dir 'notes.txt') 'not a picture'

    $shots = @{}; foreach ($x in (Get-KfwLatestScreens $dir $now)) { $shots["$($x.host)|$($x.screen)"] = $x }
    Assert-Equal @('MWEB1|S1', 'MWEB1|S2', 'OLD_ONE|S1') @($shots.Keys | Sort-Object) 'a host name may have underscores'
    $s1 = $shots['MWEB1|S1']
    Assert-That ($s1.ageMinutes -eq 0 -and $s1.state -eq 'SHOWING' -and $s1.url -eq 'http://x/0' -and $s1.count -eq $keep + 3) (ConvertTo-Json $s1 -Compress)
    Assert-That ($shots['MWEB1|S2'].ageMinutes -eq 120 -and $shots['MWEB1|S2'].state -eq '') 'no .json: no state'

    Assert-Equal 4 (Remove-KfwOldScreens $dir $now)
    Assert-Equal $keep @(Get-ChildItem $dir -Filter 'MWEB1_S1_*.png').Count
    Assert-Equal $keep @(Get-ChildItem $dir -Filter 'MWEB1_S1_*.json').Count 'the .json goes with its picture'
    Assert-Equal 1 @(Get-ChildItem $dir -Filter 'OLD_ONE_S1_*.png').Count 'a screen''s newest picture is always kept'
    Assert-That (Test-Path (Join-Path $dir 'notes.txt')) 'other files are left'
}

function Test-ScreensApi {
    $srv = Start-TestServer (New-TestWork) -Fleet
    $admin = New-TestAdmin $srv; $op = New-TestOperator $srv
    Assert-Equal @() @((Get-Test $op '/api/screens').Json.screens)
    $r, $j = Invoke-TestJob $admin 'MWEB1' 'snapshot' @{ screen = 'S1'; kind = 'NG' } 60
    Assert-That ($j -and $j.ok) (ConvertTo-Json $j -Compress -Depth 5)
    $shots = @((Get-Test $op '/api/screens').Json.screens)
    Assert-Equal @('MWEB1|S1') @($shots | ForEach-Object { "$($_.host)|$($_.screen)" })
    Assert-That ($shots[0].by -eq 'webadmin (admin)' -and $shots[0].ageMinutes -eq 0) (ConvertTo-Json $shots -Compress)
    $pic = Get-Test $op "/api/snapshots/$($shots[0].file)"
    Assert-That ($pic.Status -eq 200 -and $pic.Headers['cache-control'].Contains('immutable')) 'the grid does not fetch a picture twice'
}

function Test-TakeManyAtOnce {
    $srv = Start-TestServer (New-TestWork) -Fleet
    $op = New-TestOperator $srv
    $r = Send-Test $op '/api/group/snapshot' @{ hosts = @('MWEB1', 'PWEB1', 'MWEB3') }
    Assert-Equal 202 $r.Status $r.Text
    $g = $r.Json
    Assert-Equal @('MWEB1', 'PWEB1') @($g.jobs | ForEach-Object { $_.host } | Sort-Object)
    Assert-Equal @(@{ host = 'MWEB3'; why = 'not on the new launcher yet' }) @($g.skipped)
    $done = Wait-TestJobs $op $g.jobs 60
    Assert-That ($done.Count -eq 2 -and -not @($done.Values | Where-Object { -not $_.ok }).Count) (ConvertTo-Json $done -Compress -Depth 5)
    Assert-Equal @('MWEB1', 'PWEB1') @((Get-Test $op '/api/screens').Json.screens | ForEach-Object { $_.host } | Sort-Object -Unique)
}

function Test-EveryScreenOfAKiosk {
    # A kiosk with two screens gives two pictures from one Screenshot.
    $srv = Start-TestServer (New-TestWork) -Fleet
    $admin = New-TestAdmin $srv
    $ng = $srv.Work.Dirs.ng
    $s2 = Join-Path ([IO.Path]::GetDirectoryName($ng)) 'S2'
    [void][IO.Directory]::CreateDirectory((Join-Path $s2 'Status'))
    Copy-Item (Join-Path $ng 'MWEB1.json') (Join-Path $s2 'MWEB1.json')
    # The fixture's fake launcher plays S1 only.
    $png = & (Get-Module KioskFleetWeb) { $script:DemoPng }
    $player = Start-ThreadJob -ArgumentList $s2, $png -ScriptBlock {
        param($s2, $png)
        $end = [datetime]::UtcNow.AddSeconds(80)
        while ([datetime]::UtcNow -lt $end) {
            Start-Sleep -Milliseconds 100
            $t = Join-Path $s2 'snapshot.txt'
            if (Test-Path $t) {
                Remove-Item $t
                [IO.File]::WriteAllBytes((Join-Path $s2 'Status/S2.png'), $png)
                [IO.File]::WriteAllText((Join-Path $s2 'Status/S2.snapshot.json'), '{"State":"SHOWING","Url":"http://station/other","Image":"S2.png","Error":""}')
            }
        }
    }
    try {
        $r, $j = Invoke-TestJob $admin 'MWEB1' 'snapshot' @{} 90
    } finally {
        Stop-Job $player; Remove-Job $player -Force
    }
    Assert-That ($j -and $j.ok -and $j.detail -eq '2 of 2 screens saved') (ConvertTo-Json $j -Compress -Depth 5)
    Assert-Equal @('S1', 'S2') @((Get-Test $admin '/api/screens').Json.screens | Where-Object { $_.host -eq 'MWEB1' } | ForEach-Object { $_.screen } | Sort-Object)
}
