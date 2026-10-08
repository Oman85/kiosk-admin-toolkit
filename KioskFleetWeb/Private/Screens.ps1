# The screenshots taken from the kiosks, as the Screens page shows them: the
# newest picture of every kiosk screen, and what the launcher said about the
# page when it took it.
#
# Each picture is logs\snapshots\<HOST>_<S1>_<yyyyMMdd-HHmmss>.png, with a
# .json next to it (state, URL, title, who asked). Old ones are pruned: the
# newest few of each screen are kept for KeepDays, and the newest one always.

$script:ScreenNameRx = [regex]'^(?<host>.+)_(?<screen>S\d{1,2})_(?<stamp>\d{8}-\d{6})\.png$'
$script:KeepPerScreen = 10
$script:KeepDays = 14

function Get-KfwPictures([string]$Folder) {
    # "HOST|S1" -> list of @(stamp, path), newest first.
    $out = [ordered]@{}
    if (-not [IO.Directory]::Exists($Folder)) { return $out }
    foreach ($f in [IO.DirectoryInfo]::new($Folder).GetFiles()) {
        $m = $script:ScreenNameRx.Match($f.Name)
        if (-not $m.Success) { continue }
        $key = $m.Groups['host'].Value.ToUpperInvariant() + '|' + $m.Groups['screen'].Value.ToUpperInvariant()
        if (-not $out.Contains($key)) { $out[$key] = [Collections.Generic.List[object]]::new() }
        $out[$key].Add(@($m.Groups['stamp'].Value, $f.FullName))
    }
    foreach ($k in @($out.Keys)) { $out[$k] = Get-KfwSorted $out[$k] { param($x) $x[0] } -Descending }
    return $out
}

function Write-KfwScreenInfo([string]$Png, $Info) {
    try { [IO.File]::WriteAllText([IO.Path]::ChangeExtension($Png, '.json'), (ConvertTo-Json -InputObject $Info -Compress)) } catch { }
}

function ConvertFrom-KfwStamp([string]$Stamp) {
    [datetime]::ParseExact($Stamp, 'yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-KfwLatestScreens([string]$Folder, $Now = $null) {
    # The newest picture of each kiosk screen.
    $now = if ($Now) { [datetime]$Now } else { [datetime]::Now }
    $out = [Collections.Generic.List[object]]::new()
    $pics = Get-KfwPictures $Folder
    foreach ($key in $pics.Keys) {
        $list = $pics[$key]
        $stamp = $list[0][0]; $path = $list[0][1]
        $taken = ConvertFrom-KfwStamp $stamp
        $info = @{}
        try { $info = ConvertFrom-Json ([IO.File]::ReadAllText([IO.Path]::ChangeExtension($path, '.json'))) -AsHashtable } catch { }
        if ($info -isnot [Collections.IDictionary]) { $info = @{} }
        $hostName, $screen = $key.Split('|')
        $out.Add([ordered]@{
                host = $hostName; screen = $screen; file = [IO.Path]::GetFileName($path)
                taken = $taken.ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
                ageMinutes = [int][Math]::Max(0, [Math]::Floor(($now - $taken).TotalSeconds / 60))
                state = [string]$info['State']; url = [string]$info['Url']; title = [string]$info['Title']; by = [string]$info['By']; count = $list.Count
            })
    }
    return , (Get-KfwSorted $out { param($x) $x.host + "`0" + $x.screen })
}

function Remove-KfwOldScreens([string]$Folder, $Now = $null) {
    # Old pictures go: beyond the newest KeepPerScreen of a screen, or older
    # than KeepDays - but never a screen's newest. Returns how many.
    $now = if ($Now) { [datetime]$Now } else { [datetime]::Now }
    $gone = 0
    $pics = Get-KfwPictures $Folder
    foreach ($list in $pics.Values) {
        for ($i = 1; $i -lt $list.Count; $i++) {
            $stamp = $list[$i][0]; $path = $list[$i][1]
            $old = ($now - (ConvertFrom-KfwStamp $stamp)).Days -ge $script:KeepDays
            if ($i -ge $script:KeepPerScreen -or $old) {
                foreach ($p in $path, [IO.Path]::ChangeExtension($path, '.json')) { try { [IO.File]::Delete($p) } catch { } }
                $gone++
            }
        }
    }
    return $gone
}

function Get-KfwSnapshotPath($S, [string]$Name) {
    if ($Name -cnotmatch '^[A-Za-z0-9._-]{1,120}\.png$') { return $null }
    $p = Join-Path (Get-KfwSnapshotDir $S) $Name
    if ([IO.File]::Exists($p)) { return $p }
    return $null
}
