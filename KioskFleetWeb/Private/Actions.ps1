# What can be done to a kiosk, without any front end.
#
# Each action takes an action context and returns a hashtable with Ok and
# Detail at least; progress lines go to the context's Lines. The server runs
# them on worker threads and the page follows them by job id.
#
# Launchers are driven through files in their screen folders, as they always
# were: refresh.txt, relaunch.txt, restart.txt, hold.txt, kill.txt,
# snapshot.txt, and password.seed (which the launcher encrypts for the kiosk
# account and deletes).

$script:LiveStaleMinutes = 5

function Write-KfwSay($Ctx, [string]$Text) { if ($null -ne $Ctx.Lines) { [void]$Ctx.Lines.Add($Text) } }

function New-KfwFail([string]$Detail) { @{ Ok = $false; Detail = $Detail } }

function Get-KfwParam($Ctx, [string]$Name, $Default) {
    if ($Ctx.Params.ContainsKey($Name) -and $null -ne $Ctx.Params[$Name]) { return $Ctx.Params[$Name] }
    return $Default
}

function Open-KfwShare($Ctx) {
    # The kiosk's Public Documents share, or a kiosk error.
    if (Test-KfwUsesUnc $script:S) {
        $reach = Test-KfwReachable $Ctx.Target $script:S
        if (-not $reach.Ok) { throw (New-KfwKioskError "offline: $($reach.Error)") }
    }
    return Connect-KfwKiosk $script:S $Ctx.Target
}

function Get-KfwLauncherDirs([string]$Docs, [string]$Kind, [string]$HostName, [string]$Screen = '') {
    # Where a kiosk's launchers keep their control files: each screen folder
    # holding <HOST>.json - and PBI Launcher's own folder, from before the
    # screen folders, as its S1.
    $kinds = if ($Kind -in 'ALL', '', $null) { @($script:LauncherFolders.Keys) } else { @($Kind) }
    $out = [Collections.Generic.List[object]]::new()
    foreach ($k in $kinds) {
        $base = Join-KfwPath $Docs $script:LauncherFolders[$k]
        $entries = Get-KfwEntries $base
        if (-not $entries.Count) { continue }
        $mine = [Collections.Generic.List[object]]::new()
        foreach ($d in $entries) {
            if ($d.IsDir -and $d.Name -match '^S\d+$' -and (Test-KfwFile (Join-KfwPath $d.Path "$HostName.json"))) {
                $mine.Add(@{ Kind = $k; Instance = $d.Name.ToUpperInvariant(); Dir = $d.Path })
            }
        }
        if ($k -eq 'PBI' -and -not @($mine | Where-Object { $_.Instance -eq 'S1' }).Count -and @($entries | Where-Object { $_.Name.ToLowerInvariant() -eq "$($HostName.ToLowerInvariant()).json" }).Count) {
            $mine.Add(@{ Kind = $k; Instance = 'S1'; Dir = $base })
        }
        foreach ($m in $mine) { $out.Add($m) }
    }
    if ($Screen) { $out = @($out | Where-Object { $_.Instance -eq $Screen.ToUpperInvariant() }) }
    return , (Get-KfwSorted $out { param($d) $d.Instance + "`0" + $d.Kind })
}

function Get-KfwScreenDir([string]$Docs, [string]$Kind, [string]$Instance, [string]$HostName) {
    $base = Join-KfwPath $Docs $script:LauncherFolders[$Kind]
    if ($Kind -eq 'PBI' -and $Instance -eq 'S1' -and -not (Test-KfwFile (Join-KfwPath $base "S1\$HostName.json")) -and (Test-KfwFile (Join-KfwPath $base "$HostName.json"))) {
        return $base
    }
    return Join-KfwPath $base $Instance
}

function Wait-KfwTaken([string]$Path, [double]$Seconds = 20, [int]$PollMs = 400) {
    # The launcher deletes a control file when it acts on it; hold.txt is
    # meant to stay, so it is never waited for.
    if ([IO.Path]::GetFileName($Path).ToLowerInvariant() -eq 'hold.txt') { return $true }
    $deadline = (Get-KfwMono) + $Seconds
    while ((Get-KfwMono) -lt $deadline) {
        if (-not (Test-KfwFile $Path)) { return $true }
        Start-Sleep -Milliseconds $PollMs
    }
    return $false
}

function Write-KfwPasswordSeed([string]$Dir, [string]$Plain) {
    $seed = Join-KfwPath $Dir 'password.seed'
    Write-KfwKioskText $seed $Plain
    return $seed
}

function Get-KfwStampText($Ctx) {
    "$([datetime]::Now.ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)) by $($Ctx.Who) from Kiosk Fleet Web"
}

function Get-KfwPasswordState($Dirs) {
    $signsIn = @($Dirs | Where-Object { $_.Kind -ne 'WEB' })
    if (-not $signsIn.Count) { return 'none needed (a web page)' }
    $state = 'none stored - signing in needs a person'
    foreach ($d in $signsIn) {
        if (Test-KfwFile (Join-KfwPath $d.Dir 'password.seed')) { return 'a new one is waiting for the launcher' }
        if ((Get-KfwFiles $d.Dir '*.cred').Count) { $state = 'stored, encrypted for the kiosk account' }
    }
    return $state
}

# --- the actions ---------------------------------------------------------------------------
function Invoke-KfwLiveRead($Ctx) {
    $docs = Open-KfwShare $Ctx
    $now = [datetime]::UtcNow
    $parts = [Collections.Generic.List[object]]::new()
    if ($Ctx.Kind -in 'ALL', 'NG') { $parts.Add((Get-KfwNgObservation $docs $now $script:LiveStaleMinutes)) }
    if ($Ctx.Kind -in 'ALL', 'PBI') { $parts.Add((Get-KfwPbiObservation $docs $now $script:LiveStaleMinutes $Ctx.Target)) }
    if ($Ctx.Kind -in 'ALL', 'WEB') { $parts.Add((Get-KfwWebObservation $docs $now $script:LiveStaleMinutes $Ctx.Target)) }
    $installed = [bool]@($parts | Where-Object { $_.Installed }).Count
    $instances = @(foreach ($p in $parts) { foreach ($i in $p.Instances) { if (-not $Ctx.Screen -or $i.Screen -eq $Ctx.Screen) { $i } } })
    $errText = (@($parts | Where-Object { $_.Error } | ForEach-Object { $_.Error })) -join '; '

    $dirs = Get-KfwLauncherDirs $docs $Ctx.Kind $Ctx.Target $Ctx.Screen
    $lines = [Collections.Generic.List[object]]::new()
    $hold = $false
    $config = $null
    if (-not $installed) { $lines.Add((New-KfwDetailRow 'Installed' 'no' 'WARNING')) }
    foreach ($d in $dirs) {
        if ($null -eq $config) { $config = Read-KfwJsonFile (Join-KfwPath $d.Dir "$($Ctx.Target).json") }
        if (Test-KfwFile (Join-KfwPath $d.Dir 'hold.txt')) {
            $hold = $true
            $lines.Add((New-KfwDetailRow "$($d.Instance) $($d.Kind)" 'on hold (hold.txt) - no checks, no reloads' 'WARNING' $true))
        }
        if (Test-KfwFile (Join-KfwPath $d.Dir 'kill.txt')) {
            $lines.Add((New-KfwDetailRow $d.Instance 'kill.txt is waiting - the launcher stops when it sees it' 'WARNING' $true))
        }
    }
    foreach ($i in $instances) {
        $as = if ($i.SignedInAs) { " as $($i.SignedInAs)" } else { '' }
        $label = if ($i.Screen) { "$($i.Screen) $($i.Launcher)" } else { $i.Instance }
        $lines.Add((New-KfwDetailRow $label "$($i.State)$as, $(Format-Minutes $i.AgeMinutes) old" $(if ($i.Severity -eq 'CRITICAL') { 'CRITICAL' } else { 'DIM' }) $true))
        if ($i.Detail) { $lines.Add((New-KfwDetailRow '' $i.Detail 'DIM' $true)) }
    }
    if ($config -is [Collections.IDictionary]) {
        $url = if ($config['DisplayURL']) { $config['DisplayURL'] } elseif ($config['URL']) { $config['URL'] } else { '' }
        if ($url) { $lines.Add((New-KfwDetailRow 'Shows' $url 'DIM' $true)) }
        if ($config['UserName']) { $lines.Add((New-KfwDetailRow 'Signs in as' $config['UserName'] 'DIM')) }
    }
    $lines.Add((New-KfwDetailRow 'Password' (Get-KfwPasswordState $dirs) 'DIM'))
    if ($errText) { $lines.Add((New-KfwDetailRow 'Error' $errText 'WARNING' $true)) }
    return @{ Ok = $true; Detail = 'read just now'; Hold = $hold; Lines = $lines.ToArray(); Instances = @($dirs | ForEach-Object { $_.Instance }); Installed = $installed }
}

function Invoke-KfwSendControl($Ctx) {
    # Drops a control file in each of the kiosk's launcher folders (or removes
    # it, for remove) and waits for the launcher to take it.
    $docs = Open-KfwShare $Ctx
    $dirs = Get-KfwLauncherDirs $docs $Ctx.Kind $Ctx.Target $Ctx.Screen
    if (-not $dirs.Count) { return New-KfwFail 'the launcher is not installed here' }
    $name = $Ctx.Params.file
    $sent = 0; $taken = 0
    foreach ($d in $dirs) {
        $p = Join-KfwPath $d.Dir $name
        if ($Ctx.Params['remove']) {
            Remove-KfwKioskFile $p
            $sent++; $taken++
            continue
        }
        Write-KfwKioskText $p (Get-KfwStampText $Ctx)
        $sent++
        Write-KfwSay $Ctx "$($d.Instance) $($d.Kind): $name written"
        if (Wait-KfwTaken $p (Get-KfwParam $Ctx 'wait' 20)) { $taken++ }
    }
    $detail = if ($taken -ge $sent) { 'the launcher has taken it' } else { 'not taken within 20 s - it stays, and the launcher acts on it when it next looks' }
    return @{ Ok = $true; Detail = $detail; Sent = $sent; Taken = $taken; Waiting = $taken -lt $sent; Instances = @($dirs | ForEach-Object { $_.Instance }) }
}

function Invoke-KfwSnapshot($Ctx) {
    $docs = Open-KfwShare $Ctx
    $dirs = Get-KfwLauncherDirs $docs $Ctx.Kind $Ctx.Target $Ctx.Screen
    if (-not $dirs.Count) { return New-KfwFail 'the launcher is not installed here' }
    $before = @{}
    foreach ($d in $dirs) {
        foreach ($f in (Get-KfwFiles (Join-KfwPath $d.Dir 'Status') '*.snapshot.json')) { $before[$f.Path] = $f.MTime }
        Write-KfwKioskText (Join-KfwPath $d.Dir 'snapshot.txt') (Get-KfwStampText $Ctx)
    }
    Write-KfwSay $Ctx 'asked the launcher for a picture'

    # Every screen asked answers with its own picture; a screen that does not
    # answer in time (no DevTools connection, say) is left out.
    $deadline = (Get-KfwMono) + (Get-KfwParam $Ctx 'wait' 45)
    $answers = [ordered]@{}
    while ($answers.Count -lt $dirs.Count -and (Get-KfwMono) -lt $deadline) {
        foreach ($d in $dirs) {
            $key = "$($d.Instance)|$($d.Kind)"
            if ($answers.Contains($key)) { continue }
            foreach ($f in (Get-KfwFiles (Join-KfwPath $d.Dir 'Status') '*.snapshot.json')) {
                $was = $before[$f.Path]
                if ($null -ne $was -and $null -ne $f.MTime -and $f.MTime -le $was) { continue }
                $j = Read-KfwJsonFile $f.Path
                if ($j -is [Collections.IDictionary]) { $answers[$key] = @($j, $d); break }
            }
        }
        if ($answers.Count -lt $dirs.Count) { Start-Sleep -Milliseconds 500 }
    }
    if (-not $answers.Count) { return New-KfwFail 'no screenshot came back within 45 s' }

    $stamp = [datetime]::Now.ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
    $pictures = [Collections.Generic.List[object]]::new()
    foreach ($a in (Get-KfwSorted @($answers.Values) { param($x) $x[1].Instance })) {
        $info = $a[0]; $where = $a[1]
        $pic = [ordered]@{ Instance = $where.Instance; Kind = $where.Kind; File = ''; State = [string]$info['State']
            Url = [string]$info['Url']; Title = [string]$info['Title']; Error = '' }
        if ($info['Error'] -or -not $info['Image']) {
            $pic.Error = if ($info['Error']) { [string]$info['Error'] } else { 'the launcher saved no picture' }
        } else {
            # Only a file name the launcher wrote into its own Status folder.
            $leaf = @(([string]$info['Image']) -split '[\\/]')[-1]
            $src = Join-KfwPath (Join-KfwPath $where.Dir 'Status') $leaf
            if (-not (Test-KfwFile $src)) {
                $pic.Error = "the picture is missing: $src"
            } else {
                $name = "$($Ctx.Target)_$($where.Instance)_$stamp.png"
                $dest = Join-Path (Get-KfwSnapshotDir $script:S) $name
                Copy-KfwToLocal $src $dest
                Write-KfwScreenInfo $dest ([ordered]@{ State = $pic.State; Url = $pic.Url; Title = $pic.Title; Kind = $where.Kind; By = $Ctx.Who; Taken = $stamp })
                $pic.File = $name
            }
        }
        if ($pic.Error) { Write-KfwSay $Ctx "$($where.Instance): $($pic.Error)" }
        $pictures.Add($pic)
    }
    $good = @($pictures | Where-Object { $_.File })
    $first = if ($good.Count) { $good[0] } else { $pictures[0] }
    $out = @{ Ok = [bool]$good.Count; File = $first.File; State = $first.State; Url = $first.Url; Title = $first.Title; Instance = $first.Instance; Pictures = $pictures.ToArray() }
    if (-not $good.Count) { $out.Detail = $first.Error }
    elseif ($dirs.Count -gt 1) { $out.Detail = "$($good.Count) of $($dirs.Count) screens saved" }
    else { $out.Detail = 'screenshot saved' }
    return $out
}

$script:LogRx = [regex]::new('<!\[LOG\[(?<m>.*?)\]LOG\]!><time="(?<t>\d\d:\d\d:\d\d)[^"]*" date="(?<d>[^"]*)"[^>]*?type="(?<ty>\d)"', 'Singleline')

function Invoke-KfwReadLog($Ctx) {
    $docs = Open-KfwShare $Ctx
    $dirs = Get-KfwLauncherDirs $docs $Ctx.Kind $Ctx.Target $Ctx.Screen
    if (-not $dirs.Count) { return New-KfwFail 'the launcher is not installed here' }
    $d = $dirs[0]
    $config = Read-KfwJsonFile (Join-KfwPath $d.Dir "$($Ctx.Target).json")
    $logDir = Join-KfwPath $d.Dir 'Logs'
    $name = ''
    if ($config -is [Collections.IDictionary]) {
        $lp = [string]$config['LogPath']
        $m = [regex]::Match($lp.Trim().TrimEnd('\'), '^[Cc]:\\+Users\\+Public\\+Documents(?:\\+(.*))?$')
        if ($m.Success) {
            $logDir = if ($m.Groups[1].Success -and $m.Groups[1].Value) { Join-KfwPath $docs $m.Groups[1].Value } else { $docs }
        } elseif ($lp.Trim()) {
            return New-KfwFail "the log is kept in $lp, outside Public Documents, which is all this server opens"
        }
        if ($config['LogName']) { $name = @(([string]$config['LogName']) -split '[\\/]')[-1] }
    }
    $path = if ($name) { Join-KfwPath $logDir $name } else { $null }
    if (-not $path -or -not (Test-KfwFile $path)) {
        $logs = Get-KfwSorted (Get-KfwFiles $logDir '*.log') { param($e) $e.MTime.Ticks.ToString('D20') } -Descending
        if (-not $logs.Count) { return New-KfwFail "no log in $logDir" }
        $path = $logs[0].Path
    }
    $text = Read-KfwText $path 262144
    $entries = $script:LogRx.Matches($text)
    $count = [int](Get-KfwParam $Ctx 'lines' 60)
    $out = [Collections.Generic.List[string]]::new()
    $from = [Math]::Max(0, $entries.Count - $count)
    for ($i = $from; $i -lt $entries.Count; $i++) {
        $e = $entries[$i]
        $date = $e.Groups['d'].Value
        $dm = [regex]::Match($date, '^(\d\d)-(\d\d)-\d{4}$')
        if ($dm.Success) { $date = "$($dm.Groups[2].Value).$($dm.Groups[1].Value)." }
        $mark = switch ($e.Groups['ty'].Value) { '3' { '!' } '2' { '*' } default { ' ' } }
        $msg = $e.Groups['m'].Value.TrimEnd() -replace '\r?\n', ' '
        $out.Add("$mark $($date.PadRight(7))$($e.Groups['t'].Value)  $msg")
    }
    if (-not $entries.Count) { $out.Add('(no entries)') }
    return @{ Ok = $true; Detail = [string]$path; Path = [string]$path; Lines = $out.ToArray() }
}

function Invoke-KfwSetPassword($Ctx) {
    $docs = Open-KfwShare $Ctx
    try {
        # A web page signs in to nothing.
        $dirs = @((Get-KfwLauncherDirs $docs $Ctx.Kind $Ctx.Target $Ctx.Screen) | Where-Object { $_.Kind -ne 'WEB' })
        if (-not $dirs.Count) { return New-KfwFail 'no launcher that signs in on this screen' }
        $seeds = @(foreach ($d in $dirs) { Write-KfwPasswordSeed $d.Dir ([string]$Ctx.Secret) })
    } finally {
        $Ctx.Secret = $null
    }
    Write-KfwSay $Ctx 'written - waiting for the launcher to store it'
    $deadline = (Get-KfwMono) + (Get-KfwParam $Ctx 'wait' 30)
    while ((Get-KfwMono) -lt $deadline) {
        if (-not @($seeds | Where-Object { Test-KfwFile $_ }).Count) { return @{ Ok = $true; Detail = 'stored; the launcher uses it from the next sign-in on' } }
        Start-Sleep -Milliseconds 500
    }
    return @{ Ok = $true; Detail = 'not taken yet - the launcher stores it when it next starts'; Waiting = $true }
}

# --- the kiosk's own settings ----------------------------------------------------------------
$script:ConfigPrimary = @{
    NG  = @('DisplayURL', 'LoginURL', 'UserName', 'ScreenSelect')
    PBI = @('DisplayURL', 'UserName', 'ScreenSelect')
    WEB = @('DisplayURL', 'TargetMatch', 'ScreenSelect')
}
$script:ConfigRequired = @{ NG = @('DisplayURL', 'UserName'); PBI = @('DisplayURL', 'UserName'); WEB = @('DisplayURL') }
$script:ConfigBools = @('EnableRefresh', 'KioskMode', 'UsePriScreen', 'ScheduledRestartEnabled', 'DisableStartup',
    'DebugLogging', 'Watchdog', 'StopOldLauncher', 'InPrivate', 'StaySignedIn', 'BackButton')
$script:ConfigLabels = @{
    NG  = @{
        DisplayURL = @('Dashboard URL', 'The station page this screen shows.')
        LoginURL = @('Sign-in URL', "Left empty, it becomes the dashboard URL's host plus /prelogin?clear=true.")
        UserName = @('Station user', 'The Niagara account the launcher signs in as.')
        ScreenSelect = @('Screen', '1 is the first screen. A second screen (S2) usually shows 2.')
    }
    PBI = @{
        DisplayURL = @('Report URL', 'The Power BI report this screen shows.')
        UserName = @('Power BI account', 'The account the launcher signs in as.')
        ScreenSelect = @('Screen', '1 is the first screen.')
    }
    WEB = @{
        DisplayURL = @('Page URL', 'The web page this screen shows. No sign-in: the launcher shows the page as it comes.')
        TargetMatch = @('Stays on', 'path (the page and the pages under it), host (anywhere on the site) or exact (only this address).')
        ScreenSelect = @('Screen', '1 is the first screen. A second screen (S2) usually shows 2.')
    }
}

function ConvertTo-KfwConfigValue($V) { if ($null -eq $V) { '' } else { ConvertTo-KfwPyString $V } }

function Get-KfwConfigTemplate($S, [string]$Kind, [string]$HostName, [string]$Instance = 'S1') {
    # EXAMPLE.json as it ships, in file order, with the kiosk's own name where it had one.
    $path = Join-KfwPath $S.TemplatesDir "$($script:LauncherFolders[$Kind])\EXAMPLE.json"
    try { $data = ConvertFrom-Json (Read-KfwFileText $path) -AsHashtable } catch { return , @() }
    $pairs = [Collections.Generic.List[object]]::new()
    foreach ($key in $data.Keys) {
        $value = ConvertTo-KfwConfigValue $data[$key]
        if ($key -ceq 'LogName') {
            $suffix = if ($Instance -and $Instance -ne 'S1') { "_$Instance" } else { '' }
            $value = switch ($Kind) { 'NG' { "$HostName${suffix}_Mach2LauncherNG.log" } 'PBI' { "PbiLauncher_$HostName$suffix.log" } default { "WebLauncher_$HostName$suffix.log" } }
        } elseif ($key -cin 'DisplayURL', 'LoginURL', 'UserName') {
            $value = ''
        }
        $pairs.Add(@($key, $value))
    }
    return , $pairs.ToArray()
}

function Get-KfwInstalledOptions([string]$Docs, [string]$Kind) {
    # Every setting the launcher installed on this kiosk reads, from its own
    # script; none when it is not installed or cannot be read.
    $folder = $script:LauncherFolders[$Kind]
    $script = Join-KfwPath $Docs "$folder\$folder.ps1"
    try {
        if (-not (Test-KfwFile $script)) { return , @() }
        return , @((Get-KfwLauncherOptions (Read-KfwText $script)) | Where-Object { $_.Key.ToLowerInvariant() -notin $script:HiddenOptions })
    } catch { return , @() }
}

function Find-KfwOption($Options, [string]$Key) {
    $k = $Key.ToLowerInvariant()
    foreach ($o in $Options) { foreach ($n in (Get-KfwOptionNames $o)) { if ($n.ToLowerInvariant() -eq $k) { return $o } } }
    return $null
}

function Get-KfwMissingOptions($Options, $Pairs, [string]$Kind) {
    # The launcher's settings this config does not set, under any of their names.
    $have = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($p in $Pairs) { [void]$have.Add(([string]$p[0]).ToLowerInvariant()) }
    foreach ($k in $script:ConfigPrimary[$Kind]) { [void]$have.Add($k.ToLowerInvariant()) }
    return , @($Options | Where-Object { -not @((Get-KfwOptionNames $_) | Where-Object { $have.Contains($_.ToLowerInvariant()) }).Count })
}

function Get-KfwFieldKind([string]$Key, $Opt, [string]$Value = '') {
    # A checkbox only for a value it can show as it is: anything else ("yes",
    # "Y") would be written back as 0 by an untouched box.
    $plain = $Value.Trim().ToLowerInvariant() -in '', '0', '1', 'true', 'false'
    if ($Key -cin $script:ConfigBools -or ($Opt -and $Opt.Kind -eq 'bool' -and $plain)) { return 'bool' }
    if ($Opt -and $Opt.Kind -eq 'number' -and $Value.Trim() -match '^-?\d*\.?\d*$') { return 'number' }
    return 'text'
}

function Get-KfwConfigFields([string]$Kind, $Pairs, [bool]$IsNew, $Options) {
    # The editor: the few that matter first, the password, then everything
    # else in the file as advanced settings - and after those, every other
    # setting the installed launcher reads, at its default.
    $Options = @($Options)
    $values = @{}
    foreach ($p in $Pairs) { $values[$p[0]] = $p[1] }
    $labels = $script:ConfigLabels[$Kind]
    $fields = [Collections.Generic.List[object]]::new()
    foreach ($key in $script:ConfigPrimary[$Kind]) {
        $lh = if ($labels.ContainsKey($key)) { $labels[$key] } else { @($key, '') }
        $fields.Add([ordered]@{ Key = $key; Label = $lh[0]; Value = $(if ($values.ContainsKey($key)) { $values[$key] } else { '' }); Hint = $lh[1]; Kind = 'text'; Advanced = $false })
    }
    if ($Kind -ne 'WEB') {
        $fields.Add([ordered]@{ Key = '__password'; Label = 'Sign-in password'; Value = ''; Kind = 'password'; Advanced = $false
                Hint = if ($IsNew) { 'Handed to the launcher as password.seed; it encrypts it for the kiosk account.' } else { 'Leave both empty to keep the password already stored on the kiosk.' } })
    }
    foreach ($p in $Pairs) {
        $key = $p[0]; $value = $p[1]
        if ($key -cin $script:ConfigPrimary[$Kind]) { continue }
        $opt = Find-KfwOption $Options $key
        $hint = if ($opt) { Get-KfwOptionHint $opt } elseif ($Options.Count) { 'not read by this launcher version' } else { '' }
        $fields.Add([ordered]@{ Key = $key; Label = $key; Value = $value; Hint = $hint; Kind = Get-KfwFieldKind $key $opt $value; Advanced = $true })
    }
    $extra = Get-KfwMissingOptions $Options $Pairs $Kind
    if ($extra.Count) {
        $fields.Add([ordered]@{ Key = '__unset'; Label = "NOT IN THIS CONFIG: THE LAUNCHER'S DEFAULTS. ONE IS SAVED ONLY IF YOU CHANGE IT."; Kind = 'note'; Advanced = $true })
    }
    foreach ($opt in $extra) {
        $def = if ($null -ne $opt.Default) { $opt.Default } else { '' }
        $fields.Add([ordered]@{ Key = $opt.Key; Label = $opt.Key; Value = $def; Hint = Get-KfwOptionHint $opt; Kind = Get-KfwFieldKind $opt.Key $opt $def; Advanced = $true; Unset = $true })
    }
    return , $fields.ToArray()
}

function Get-KfwPairs($Obj) {
    , @(foreach ($k in $Obj.Keys) { , @([string]$k, (ConvertTo-KfwConfigValue $Obj[$k])) })
}

function Invoke-KfwConfigRead($Ctx) {
    $docs = Open-KfwShare $Ctx
    $kind = $Ctx.Kind
    $dirs = Get-KfwLauncherDirs $docs $kind $Ctx.Target
    $instances = @($dirs | ForEach-Object { $_.Instance })
    $instance = if ($Ctx.Params.instance) { $Ctx.Params.instance } elseif ($instances.Count) { $instances[0] } else { 'S1' }
    # Which launcher has which screen, so a new config does not land on one another launcher shows.
    $taken = [ordered]@{}
    foreach ($d in (Get-KfwLauncherDirs $docs 'ALL' $Ctx.Target)) { if ($d.Kind -ne $kind) { $taken[$d.Instance] = $d.Kind } }

    $pairs = @()
    $exists = $false
    $password = 'none stored'
    $options = Get-KfwInstalledOptions $docs $kind
    $d = @($dirs | Where-Object { $_.Instance -eq $instance }) | Select-Object -First 1
    if ($d) {
        $cfg = Read-KfwJsonFile (Join-KfwPath $d.Dir "$($Ctx.Target).json")
        if ($cfg -is [Collections.IDictionary]) { $exists = $true; $pairs = Get-KfwPairs $cfg }
        if (Test-KfwFile (Join-KfwPath $d.Dir 'password.seed')) { $password = 'a new one is waiting for the launcher' }
        elseif ((Get-KfwFiles $d.Dir '*.cred').Count) { $password = 'stored, encrypted for the kiosk account' }
    }
    if (-not $exists) { $pairs = Get-KfwConfigTemplate $script:S $kind $Ctx.Target $instance }
    return @{ Ok = $true; Detail = ''; Kind = $kind; Exists = $exists; IsNew = -not $exists; Instance = $instance
        Instances = $instances; Password = $password; Taken = $taken; Fields = (Get-KfwConfigFields $kind $pairs (-not $exists) $options)
        LauncherOptions = @($options).Count }
}

function Get-KfwScreenNumber([string]$Instance) {
    $m = [regex]::Match($Instance, '^S(\d+)$', 'IgnoreCase')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return 0
}

function Invoke-KfwConfigWrite($Ctx) {
    # Saves one screen's config. The file is read again here rather than
    # trusting what came back from the editor: its keys and their order are
    # the file's (or EXAMPLE.json's), and only those - plus the few every
    # config needs - can be set. The old file is kept as <HOST>.json.bak-<time>.
    try {
        $docs = Open-KfwShare $Ctx
        $kind = $Ctx.Kind; $instance = $Ctx.Params.instance
        $d = Get-KfwScreenDir $docs $kind $instance $Ctx.Target
        $other = @((Get-KfwLauncherDirs $docs 'ALL' $Ctx.Target $instance) | Where-Object { $_.Kind -ne $kind })
        if ($other.Count) { return New-KfwFail "$instance already has a config for $($script:LauncherNames[$other[0].Kind]) - one launcher per screen" }

        $path = Join-KfwPath $d "$($Ctx.Target).json"
        $existing = Read-KfwJsonFile $path
        $isNew = $existing -isnot [Collections.IDictionary]
        $pairs = if (-not $isNew) { Get-KfwPairs $existing } else { Get-KfwConfigTemplate $script:S $kind $Ctx.Target $instance }
        $values = [ordered]@{}
        foreach ($p in $pairs) { $values[$p[0]] = $p[1] }
        foreach ($key in $script:ConfigPrimary[$kind]) { if (-not $values.Contains($key)) { $values[$key] = '' } }
        $typed = if ($Ctx.Params['values']) { $Ctx.Params['values'] } else { @{} }
        foreach ($key in @($values.Keys)) { if ($typed.Contains($key)) { $values[$key] = [string]$typed[$key] } }
        # A setting the config did not have is added only when it was changed
        # from the default the editor showed, so the rest keep following the
        # launcher's own defaults.
        $added = [Collections.Generic.List[string]]::new()
        $current = @(foreach ($k in $values.Keys) { , @($k, $values[$k]) })
        foreach ($opt in (Get-KfwMissingOptions (Get-KfwInstalledOptions $docs $kind) $current $kind)) {
            $def = if ($null -ne $opt.Default) { $opt.Default } else { '' }
            if ($typed.Contains($opt.Key) -and [string]$typed[$opt.Key] -cne $def) {
                $values[$opt.Key] = [string]$typed[$opt.Key]
                $added.Add($opt.Key)
            }
        }
        if ($added.Count) { Write-KfwSay $Ctx ('added: ' + (($added | ForEach-Object { "$_=$($values[$_])" }) -join ', ')) }
        $missing = @($script:ConfigRequired[$kind] | Where-Object { -not $values[$_] })
        if ($missing.Count) { return New-KfwFail ('still empty: ' + ($missing -join ', ')) }

        if (-not (Test-KfwDir $d)) {
            [void][IO.Directory]::CreateDirectory($d)
            Write-KfwSay $Ctx "created $d"
        }
        # Only the kiosk's first Mach2 screen is the watchdog: two on one PC
        # would both want to restart it.
        if ($kind -eq 'NG' -and $isNew -and $values.Contains('Watchdog')) {
            $others = @((Get-KfwLauncherDirs $docs 'NG' $Ctx.Target) | Where-Object { $_.Instance -ne $instance })
            $first = -not @($others | Where-Object { (Get-KfwScreenNumber $_.Instance) -lt (Get-KfwScreenNumber $instance) }).Count
            $values['Watchdog'] = if ($first) { '1' } else { '0' }
            Write-KfwSay $Ctx $(if ($first) { 'the first Mach2 screen here, so it is the watchdog' } else { 'not the first Mach2 screen here, so it is not the watchdog' })
        }
        if ($kind -eq 'NG' -and $values.Contains('LoginURL') -and -not $values['LoginURL'] -and $values['DisplayURL']) {
            $u = $null
            if ([Uri]::TryCreate([string]$values['DisplayURL'], [UriKind]::Absolute, [ref]$u) -and $u.Authority) {
                $values['LoginURL'] = "$($u.Scheme)://$($u.Authority)/prelogin?clear=true"
                Write-KfwSay $Ctx "sign-in URL: $($values['LoginURL'])"
            }
        }
        if (Test-KfwFile $path) {
            $backup = Join-KfwPath $d "$([IO.Path]::GetFileName($path)).bak-$([datetime]::Now.ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture))"
            [IO.File]::WriteAllBytes($backup, (Read-KfwBytes $path))
            Write-KfwSay $Ctx "the old one is kept as $([IO.Path]::GetFileName($backup))"
        }
        Write-KfwKioskText $path (ConvertTo-Json -InputObject $values)
        Write-KfwSay $Ctx "saved $path"

        $out = @{ Ok = $true; IsNew = $isNew; Path = [string]$path; Password = ''
            Detail = if ($isNew) { "Written. $($script:LauncherNames[$kind]) on $instance reads it once it is installed there." } else { 'Saved. The launcher reads it again within seconds.' } }
        if ($Ctx.Secret -and $kind -ne 'WEB') {
            $seed = Write-KfwPasswordSeed $d ([string]$Ctx.Secret)
            $Ctx.Secret = $null
            Write-KfwSay $Ctx 'password.seed written'
            $deadline = (Get-KfwMono) + (Get-KfwParam $Ctx 'wait' 20)
            while ((Get-KfwMono) -lt $deadline -and (Test-KfwFile $seed)) { Start-Sleep -Milliseconds 500 }
            $out.Password = if (Test-KfwFile $seed) { 'waiting for the launcher to store it' } else { 'stored by the launcher' }
            Write-KfwSay $Ctx "password: $($out.Password)"
        }
        return $out
    } finally {
        $Ctx.Secret = $null
    }
}

function Invoke-KfwRestart($Ctx) {
    # restart.txt in one of the kiosk's launcher folders: the launcher closes
    # the browser and has Windows restart the PC after the countdown, with the
    # message on screen. Launchers from before the countdown and message were
    # read restart in 10 seconds with neither. One launcher is asked, not
    # every one: two would both ask Windows. The watchdog's screen (Mach2 S1)
    # first, as the one that knows the restart was asked for.
    $secs = [int](Get-KfwParam $Ctx 'seconds' 0)
    $message = if ($secs -gt 0) { ([string]$Ctx.Params.message).Trim() } else { '' }
    $docs = Open-KfwShare $Ctx
    $dirs = Get-KfwLauncherDirs $docs 'ALL' $Ctx.Target
    if (-not $dirs.Count) { return New-KfwFail "no launcher here to restart it: Restart works through the launcher's restart.txt" }
    $d = (Get-KfwSorted $dirs { param($x) $(if ($x.Kind -ne 'NG') { '1' } else { '0' }) + "`0" + $x.Instance })[0]
    $p = Join-KfwPath $d.Dir 'restart.txt'
    $body = [ordered]@{ Seconds = $secs; Message = $message; By = $Ctx.Who; At = [datetime]::Now.ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture); From = 'Kiosk Fleet Web' }
    Write-KfwKioskText $p (ConvertTo-Json -InputObject $body -Compress)
    Write-KfwSay $Ctx "$($d.Instance) $($d.Kind): restart.txt written (countdown $secs s)"
    if (Wait-KfwTaken $p (Get-KfwParam $Ctx 'wait' 20)) {
        return @{ Ok = $true; Detail = "the launcher has taken it - the kiosk restarts in $secs s (10 s on launchers older than the countdown) and comes back on its own" }
    }
    return @{ Ok = $true; Waiting = $true; Detail = 'not taken within 20 s - it stays, and the launcher restarts the kiosk when it next looks' }
}

# --- a message on the screen, through the kiosk's watchdog (V7.0+ or NG) -------------------------
function Get-KfwMessageRows([string]$Ledger, [string]$Mid) {
    # This message's rows in the kiosk's ledger. Only the tail is read: the
    # rows are seconds old, and the ledger can be 8 MB.
    try {
        $head = Read-KfwText $Ledger 0 4096
        $tail = Read-KfwText $Ledger 262144
    } catch { return , @() }
    $header = ($head -split '\r?\n')[0]
    if (-not $header) { return , @() }
    $hits = @(($tail -split '\r?\n') | Where-Object { $_.Contains("MessageId=$Mid") })
    if (-not $hits.Count) { return , @() }
    return , (ConvertFrom-KfwCsvText ((@($header) + $hits) -join "`n"))
}

function Invoke-KfwSendMessage($Ctx) {
    # Sends one message and follows it. Every outcome is a Status a person can act on:
    #
    #   NOT_SENT       offline, share unreadable, or no inbox (no V7.0+ watchdog)
    #   NOT_DELIVERED  nobody picked it up in time; it was withdrawn
    #   SHOWN          on screen now
    #   ACKNOWLEDGED   OK was pressed;  TIMEOUT  its countdown ran out
    #   EXPIRED, REJECTED  the watchdog dropped it; Detail says why
    #   PICKED_UP      taken from the inbox, but no ledger row yet
    $text = [string]$Ctx.Params.text
    $secs = [int](Get-KfwParam $Ctx 'seconds' 60)
    $wait = [int](Get-KfwParam $Ctx 'wait' 45)
    $status = 'NOT_SENT'; $detail = ''
    try { $folder = Open-KfwShare $Ctx } catch {
        if (Test-KfwKioskError $_.Exception) { return @{ Ok = $false; Status = $status; Detail = "NOT_SENT: $($_.Exception.Message)" } }
        throw
    }
    $inbox = Join-KfwPath $folder 'mwst_inbox'
    if (-not (Test-KfwDir $inbox)) { return @{ Ok = $false; Status = $status; Detail = 'NOT_SENT: no message inbox - this kiosk has never run a V7.0 or later watchdog' } }

    $now = [datetime]::UtcNow
    $mid = [guid]::NewGuid().ToString()
    $title = if ($Ctx.Params.title) { $Ctx.Params.title } else { 'Message from IT' }
    $payload = [ordered]@{ Id = $mid; Title = $title; Text = $text; Seconds = $secs; From = "$($Ctx.Who) via Kiosk Fleet Web"
        SentUtc = ConvertTo-UtcIso $now; ExpiresUtc = ConvertTo-UtcIso $now.AddMinutes(10) }
    $name = "msg_$($now.ToString('yyyyMMddHHmmssfff', [Globalization.CultureInfo]::InvariantCulture))_$($mid.Substring(0, 8)).json"
    $f = Join-KfwPath $inbox $name
    Write-KfwKioskText $f (ConvertTo-Json -InputObject $payload -Compress)
    $status = 'QUEUED'
    Write-KfwSay $Ctx 'queued - waiting for the watchdog to pick it up'

    $ledger = Join-KfwPath $folder 'mwst_events.csv'
    $deadline = (Get-KfwMono) + $wait
    $extended = $false
    while ($true) {
        $rows = Get-KfwMessageRows $ledger $mid
        $final = @($rows | Where-Object { $_['EventType'] -cin 'MESSAGE_CLOSED', 'MESSAGE_EXPIRED', 'MESSAGE_REJECTED' })
        if ($final.Count) {
            $last = $final[$final.Count - 1]
            $status = if ($last['Outcome']) { $last['Outcome'] } else { 'CLOSED' }
            $detail = ([string]$last['Detail']) -replace '^MessageId=[^;]*;\s*', ''
            break
        }
        if (@($rows | Where-Object { $_['EventType'] -ceq 'MESSAGE_SHOWN' }).Count) {
            if ($status -ne 'SHOWN') {
                $status = 'SHOWN'; $detail = "on screen for up to $secs s"
                Write-KfwSay $Ctx 'on screen'
            }
            if (-not $Ctx.Params.wait_for_close) { break }
            if (-not $extended) {
                $deadline = (Get-KfwMono) + $secs + 30
                $extended = $true
                Write-KfwSay $Ctx "waiting for it to be closed (up to $secs s)"
            }
        } elseif ($status -eq 'QUEUED' -and -not (Test-KfwFile $f)) {
            $status = 'PICKED_UP'
            Write-KfwSay $Ctx 'picked up'
        }
        if ((Get-KfwMono) -ge $deadline) {
            if ($status -eq 'QUEUED') {
                try {
                    if (-not (Test-KfwFile $f)) { throw [IO.FileNotFoundException]::new($f) }
                    [IO.File]::Delete($f)
                    $status = 'NOT_DELIVERED'; $detail = "not picked up within $wait s, so withdrawn - is the V7.0 watchdog running there?"
                } catch {
                    if (Test-KfwFile $f) { $status = 'NOT_DELIVERED'; $detail = 'not picked up, and could not be withdrawn: it will be dropped if still unseen in 10 minutes' }
                    else { $status = 'PICKED_UP'; $detail = 'picked up at the last moment; no ledger row seen yet' }
                }
            } elseif ($status -eq 'PICKED_UP') {
                $detail = 'taken from the inbox, but no MESSAGE_SHOWN row appeared - check mwst.log on the kiosk'
            } elseif ($status -eq 'SHOWN') {
                $detail = 'shown, but its closing was not recorded within the wait'
            }
            break
        }
        Start-Sleep -Milliseconds ([int](1000 * (Get-KfwParam $Ctx 'poll' 2)))
    }
    $ok = $status -cin 'SHOWN', 'ACKNOWLEDGED', 'TIMEOUT'
    return @{ Ok = $ok; Status = $status; Detail = "${status}: $detail"; Waiting = $status -ceq 'TIMEOUT' }
}

function Invoke-KfwTestConnection($Ctx) {
    # Can this server reach a kiosk and read its share? For setting up.
    $lines = [Collections.Generic.List[object]]::new()
    $S = $script:S
    if (Test-KfwUsesUnc $S) {
        $reach = Test-KfwReachable $Ctx.Target $S
        $lines.Add((New-KfwDetailRow 'Network' $(if ($reach.Ok) { "reachable ($($reach.Method))" } else { "not reachable: $($reach.Error)" }) $(if ($reach.Ok) { 'OK' } else { 'CRITICAL' })))
        if (-not $reach.Ok) { return @{ Ok = $false; Detail = "$($Ctx.Target) does not answer"; Lines = $lines.ToArray() } }
        $who = if (Test-KfwHasCredential $S) { $S.ShareUser } else { "$([Environment]::UserDomainName)\$([Environment]::UserName) (the account this server runs as)" }
        $lines.Add((New-KfwDetailRow 'Account' $who 'DIM'))
    }
    $docs = Connect-KfwKiosk $S $Ctx.Target
    $lines.Add((New-KfwDetailRow 'Share' "$docs opened" 'OK'))
    $found = [Collections.Generic.List[string]]::new()
    foreach ($kind in $script:LauncherFolders.Keys) {
        if (Test-KfwDir (Join-KfwPath $docs $script:LauncherFolders[$kind])) { $found.Add($script:LauncherNames[$kind]) }
    }
    if (Test-KfwFile (Join-KfwPath $docs 'mwst.log')) { $found.Add('MWST watchdog') }
    $lines.Add((New-KfwDetailRow 'Found' $(if ($found.Count) { $found -join ', ' } else { 'no launcher, no watchdog' }) 'DIM'))
    return @{ Ok = $true; Detail = "$($Ctx.Target): the share opens"; Lines = $lines.ToArray() }
}

$script:ActionTable = @{
    'test' = 'Invoke-KfwTestConnection'; 'live' = 'Invoke-KfwLiveRead'; 'control' = 'Invoke-KfwSendControl'
    'snapshot' = 'Invoke-KfwSnapshot'; 'log' = 'Invoke-KfwReadLog'; 'password' = 'Invoke-KfwSetPassword'
    'config-read' = 'Invoke-KfwConfigRead'; 'config-write' = 'Invoke-KfwConfigWrite'; 'restart' = 'Invoke-KfwRestart'
    'message' = 'Invoke-KfwSendMessage'
}

function Invoke-KfwAction([string]$Name, $Ctx) {
    $fn = $script:ActionTable[$Name]
    if (-not $fn) { return New-KfwFail "unknown action '$Name'" }
    try {
        return (& $fn $Ctx)
    } catch {
        $e = $_.Exception
        if (Test-KfwKioskError $e) { return New-KfwFail $e.Message }
        $io = Get-KfwIoError $e
        if ($io) { return New-KfwFail "$($io.GetType().Name): $($io.Message)" }
        throw
    } finally {
        $Ctx.Secret = $null
    }
}
