# Editing the kiosk list in the app: add a kiosk, change one, take one out
# of the scan, or remove it.
#
# The list stays a file, so the collector, the download button and anyone
# used to keeping it in Excel see the same thing. The first edit of an
# uploaded .xlsx or .txt turns it into kiosk-list.csv in the data folder
# (every row kept, scanned or not) and puts the original aside as
# kiosk-list-before-edit.xlsx; uploading a list afterwards replaces the edited
# one as before.

$script:EditedName = 'kiosk-list.csv'
$script:ListFields = [ordered]@{ location = 'Location'; type = 'Type'; restartGroup = 'Restart group'; info = 'Info'; version = 'Version' }
$script:ListAttrs = @{ location = 'Location'; type = 'Type'; restartGroup = 'RestartGroup'; info = 'Info'; version = 'ListedVersion' }

function New-KfwListError([string]$Message, [switch]$Conflict) {
    # Conflict: the list changed under the edit, or the edit clashes with it.
    $e = [InvalidOperationException]::new($Message)
    if ($Conflict) { $e.Data['KfwConflict'] = $true } else { $e.Data['KfwInvalid'] = $true }
    return $e
}

function Get-KfwListFile($S) {
    $p = Resolve-KfwKioskList $S
    if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Leaf)) { return @{ Path = $null; Rows = [Collections.Generic.List[object]]::new() } }
    return @{ Path = $p; Rows = (Read-KfwListRows $p $S.KioskListSheet) }
}

function Get-KfwListView($S) {
    $l = Get-KfwListFile $S
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $out = [Collections.Generic.List[object]]::new()
    $i = 0
    foreach ($r in $l.Rows) {
        $why = Get-KfwSkipReason $r $S.IncludeAllHosts
        $key = $r.Host.ToUpperInvariant()
        if (-not $why -and $seen.Contains($key)) { $why = 'listed twice' }
        if (-not $why) { [void]$seen.Add($key) }
        $act = ([string]$r.Active).Trim().ToUpperInvariant()
        $out.Add([ordered]@{
            row = $i; host = $r.Host; location = $r.Location; type = $r.Type; watchdog = ([string]$r.HasMwst).Trim().ToUpperInvariant().StartsWith('Y')
            active = if ($act) { $act.Substring(0, 1) } else { '' }; restartGroup = $r.RestartGroup; info = $r.Info; version = $r.ListedVersion
            sheet = $r.Sheet; scanned = -not $why; why = $why
            kind = if (Test-KfwPowerBi $r.Type) { 'Power BI' } elseif (Test-KfwWeb $r.Type) { 'Web page' } else { 'Mach2/other' }
        })
        $i++
    }
    $fixed = [bool]$S.KioskList
    [ordered]@{
        path = if ($l.Path) { [string]$l.Path } else { '' }; fixed = $fixed; editable = -not $fixed
        converts = [bool]$l.Path -and [IO.Path]::GetFileName($l.Path) -ne $script:EditedName
        rows = @($out); scanned = @($out | Where-Object { $_.scanned }).Count; total = $out.Count
    }
}

function Save-KfwList($S, $Path, $Rows) {
    $d = $S.DataDir
    $target = Join-Path $d $script:EditedName
    $tmp = Join-Path $d ($script:EditedName + '.tmp')
    [IO.File]::WriteAllBytes($tmp, (ConvertTo-KfwListCsv $Rows))
    [IO.File]::Move($tmp, $target, $true)
    if ($Path) {
        $full = [IO.Path]::GetFullPath($Path)
        $inData = [IO.Path]::GetDirectoryName($full) -eq [IO.Path]::GetFullPath($d).TrimEnd([IO.Path]::DirectorySeparatorChar)
        $name = [IO.Path]::GetFileName($full)
        if ($full -ne [IO.Path]::GetFullPath($target) -and $inData -and $name.StartsWith('kiosk-list.')) {
            # The upload this came from is kept, out of the way of
            # Resolve-KfwKioskList, which would otherwise still prefer it.
            [IO.File]::Move($full, (Join-Path $d "kiosk-list-before-edit$([IO.Path]::GetExtension($name).ToLowerInvariant())"), $true)
        }
    }
}

function Get-KfwCleanListValues($Values) {
    $out = @{}
    foreach ($key in $script:ListFields.Keys) {
        $v = if ($null -eq $Values[$key]) { '' } else { ([string]$Values[$key]).Trim() }
        if ($v.Length -gt 200) { throw (New-KfwListError "$($script:ListFields[$key]) is too long (200 characters at most).") }
        if ($v -match '[\x00-\x1f\x7f]') { throw (New-KfwListError "$($script:ListFields[$key]) has a line break or a control character in it.") }
        $out[$key] = $v
    }
    $a = ([string]$Values['active']).Trim().ToUpperInvariant()
    $active = if ($a) { $a.Substring(0, 1) } else { '' }
    if ($active -notin '', 'Y', 'N') { throw (New-KfwListError 'Active is Y, N or empty.') }
    $out['active'] = $active
    $out['watchdog'] = ($Values['watchdog'] -is [bool]) -and $Values['watchdog']
    return $out
}

function Assert-KfwListRow($Rows, $Index, [string]$Was) {
    $ok = ($Index -is [int] -or $Index -is [long]) -and $Index -ge 0 -and $Index -lt $Rows.Count -and
        $Rows[[int]$Index].Host.ToLowerInvariant() -eq ([string]$Was).ToLowerInvariant()
    if (-not $ok) { throw (New-KfwListError 'The kiosk list changed since the page read it. Reload it and try again.' -Conflict) }
    return [int]$Index
}

function Assert-KfwListEditable($S) {
    if ($S.KioskList) { throw (New-KfwListError 'The kiosk list is set by KFW_KIOSK_LIST on the server; change it there.' -Conflict) }
}

function Set-KfwListRow($S, $Lock, $Index, [string]$Was, $Values) {
    # Add ($Index $null) or change one row: @{ Row; Change }.
    Assert-KfwListEditable $S
    $hostName = Get-KfwCleanHost ([string]$Values['host'])
    if (-not $hostName) { throw (New-KfwListError 'That is not a kiosk name: letters, digits, dots, dashes and underscores, as the kiosk answers on the network.') }
    $v = Get-KfwCleanListValues $Values
    [Threading.Monitor]::Enter($Lock)
    try {
        $l = Get-KfwListFile $S
        $rows = $l.Rows
        if ($null -ne $Index) { $Index = Assert-KfwListRow $rows $Index $Was }
        for ($i = 0; $i -lt $rows.Count; $i++) {
            if ($i -ne $Index -and $rows[$i].Host.ToLowerInvariant() -eq $hostName.ToLowerInvariant()) { throw (New-KfwListError "$hostName is in the list already." -Conflict) }
        }
        $new = New-KfwRawRow $hostName $v.location $v.type ($(if ($v.watchdog) { 'Y' } else { 'N' })) $v.active $v.restartGroup $v.info $v.version 'csv'
        if ($null -eq $Index) {
            $rows.Add($new)
            $bits = [Collections.Generic.List[string]]::new()
            foreach ($k in $script:ListFields.Keys) { if ($new[$script:ListAttrs[$k]]) { $bits.Add("$k=$($new[$script:ListAttrs[$k]])") } }
            $bits.Add("watchdog=$($new.HasMwst)")
            $bits.Add("active=$(if ($new.Active) { $new.Active } else { '-' })")
            $change = 'added: ' + ($bits -join ', ')
        } else {
            $old = $rows[$Index]
            $diffs = [Collections.Generic.List[string]]::new()
            if ($old.Host -cne $new.Host) { $diffs.Add("name $($old.Host) -> $($new.Host)") }
            foreach ($k in $script:ListFields.Keys) {
                $a = [string]$old[$script:ListAttrs[$k]]; $b = [string]$new[$script:ListAttrs[$k]]
                if ($a -cne $b) { $diffs.Add("$k '$a' -> '$b'") }
            }
            if (([string]$old.HasMwst).Trim().ToUpperInvariant().StartsWith('Y') -ne $v.watchdog) { $diffs.Add("watchdog -> $($new.HasMwst)") }
            $oa = ([string]$old.Active).Trim().ToUpperInvariant()
            if ($(if ($oa) { $oa.Substring(0, 1) } else { '' }) -ne $new.Active) { $diffs.Add("active '$($old.Active)' -> '$($new.Active)'") }
            else { $new.Active = $old.Active }
            $rows[$Index] = $new
            $change = if ($diffs.Count) { $diffs -join '; ' } else { 'nothing changed' }
        }
        Save-KfwList $S $l.Path $rows
    } finally { [Threading.Monitor]::Exit($Lock) }
    return @{ Row = $new; Change = $change }
}

function Set-KfwListRowActive($S, $Lock, $Index, [string]$Was, [bool]$Active) {
    Assert-KfwListEditable $S
    [Threading.Monitor]::Enter($Lock)
    try {
        $l = Get-KfwListFile $S
        $Index = Assert-KfwListRow $l.Rows $Index $Was
        $l.Rows[$Index].Active = if ($Active) { 'Y' } else { 'N' }
        Save-KfwList $S $l.Path $l.Rows
        return $l.Rows[$Index].Host
    } finally { [Threading.Monitor]::Exit($Lock) }
}

function Remove-KfwListRow($S, $Lock, $Index, [string]$Was) {
    Assert-KfwListEditable $S
    [Threading.Monitor]::Enter($Lock)
    try {
        $l = Get-KfwListFile $S
        $Index = Assert-KfwListRow $l.Rows $Index $Was
        $gone = $l.Rows[$Index]
        $l.Rows.RemoveAt($Index)
        Save-KfwList $S $l.Path $l.Rows
        return $gone
    } finally { [Threading.Monitor]::Exit($Lock) }
}
