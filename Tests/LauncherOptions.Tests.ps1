# The config editor offers every setting the installed launcher reads, read
# from the launcher script itself, and saves one only when it was changed.

# Lines as they are in WebLauncher.ps1's Read-LauncherConfig.
$script:OptionScript = @'
function Get-ConfigValue { param($Object, [string[]]$Names, $Default = $null) }

function Read-LauncherConfig {
    param([Parameter(Mandatory)][string]$Path)
    $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $url = [string](Get-ConfigValue $raw @('DisplayURL', 'URL'))
    $match = ([string](Get-ConfigValue $raw @('TargetMatch') 'path')).ToLowerInvariant()
    $refreshMinutes = Get-ConfigValue $raw @('RefreshMinutes')
    elseif (ConvertTo-Flag (Get-ConfigValue $raw @('EnableRefresh')) $false) { $refreshMinutes = ConvertTo-Number (Get-ConfigValue $raw @('BrowserRefreshDelay')) 15 1 10080 }
    $refreshTimes = @(ConvertTo-TimesOfDay -Values (ConvertTo-StringList (Get-ConfigValue $raw @('RefreshTimes', 'ForcedRefreshTime'))) -What 'refresh' -Problems $problems)
    $password = [string](Get-ConfigValue $raw @('Password') '')
    return [pscustomobject]@{
        KioskMode                = ConvertTo-Flag (Get-ConfigValue $raw @('KioskMode', 'FullScreenWindow')) $true
        ScreenNumber             = [int](ConvertTo-Number (Get-ConfigValue $raw @('ScreenSelect', 'ScreenNumber')) 1 1 16)
        HealthCheckSeconds       = ConvertTo-Number (Get-ConfigValue $raw @('HealthCheckSeconds')) 20 1 600
        BackButtonText           = [string](Get-ConfigValue $raw @('BackButtonText') 'It''s back')
        ParkMouse                = ConvertTo-Flag (Get-ConfigValue $raw @('ParkMouse')) $true
        AllowHttpLogin           = ConvertTo-Flag (Get-ConfigValue $raw @('TestAllowHttpLogin')) $false
    }
}

function Somewhere-Else { $x = Get-ConfigValue $raw @('NotASetting') 'nope' }
'@

function Test-ParseOptions {
    $opts = [ordered]@{}; foreach ($o in (Get-KfwLauncherOptions $script:OptionScript)) { $opts[$o.Key] = $o }
    Assert-That (-not $opts.Contains('NotASetting')) 'only what Read-LauncherConfig reads'
    Assert-That ($opts.TargetMatch.Default -eq 'path' -and $opts.TargetMatch.Kind -eq 'text') 'an inline default'
    Assert-That ($opts.EnableRefresh.Kind -eq 'bool' -and $opts.EnableRefresh.Default -eq '0') 'a flag'
    Assert-That ($opts.BrowserRefreshDelay.Kind -eq 'number' -and $opts.BrowserRefreshDelay.Minimum -eq '1' -and $opts.BrowserRefreshDelay.Maximum -eq '10080') 'a number'
    Assert-That ($opts.HealthCheckSeconds.Default -eq '20' -and (Get-KfwOptionHint $opts.HealthCheckSeconds).Contains('1 to 600')) (Get-KfwOptionHint $opts.HealthCheckSeconds)
    Assert-That ((@($opts.KioskMode.Aliases) -join ',') -eq 'FullScreenWindow' -and $opts.KioskMode.Default -eq '1') 'an old name'
    Assert-That ($null -eq $opts.RefreshTimes.Default -and (Get-KfwOptionHint $opts.RefreshTimes).Contains('worked out by the launcher')) 'a default worked out at run time'
    Assert-Equal "It's back" $opts.BackButtonText.Default
    Assert-Equal @('DisplayURL', 'TargetMatch', 'RefreshMinutes') @(@($opts.Keys)[0..2]) 'in the order the launcher reads them'
}

function Test-EditorOffersEverySettingOfTheInstalledLauncher {
    $srv = Start-TestServer (New-TestWork) -Fleet
    $admin = New-TestAdmin $srv
    $folder = Join-Path (Get-TestDocs $srv.Work 'NEWWEB1') 'WebLauncher'
    $r, $j = Invoke-TestJob $admin 'NEWWEB1' 'config-write' @{ kind = 'WEB'; instance = 'S1'; values = @{ DisplayURL = 'https://intranet.test/board' } }
    Assert-That $j.ok (ConvertTo-Json $j -Compress -Depth 5)
    $path = Join-Path $folder 'S1/NEWWEB1.json'
    $cfg = Get-Content -Raw $path | ConvertFrom-Json -AsHashtable
    $cfg.Remove('KioskMode')
    $cfg.FullScreenWindow = '1'          # set under its old name
    $cfg.Remove('BackButtonText')
    Set-TestText $path (ConvertTo-Json $cfg)

    # Not installed yet: only the file's own keys.
    $r, $j = Invoke-TestJob $admin 'NEWWEB1' 'config-read' @{ kind = 'WEB'; instance = 'S1' }
    Assert-That ($j.ok -and $j.result.launcherOptions -eq 0) (ConvertTo-Json $j -Compress -Depth 5)
    Assert-That (-not @($j.result.fields | Where-Object { $_.Unset }).Count) 'nothing unset'

    Set-TestText (Join-Path $folder 'WebLauncher.ps1') $script:OptionScript
    $r, $j = Invoke-TestJob $admin 'NEWWEB1' 'config-read' @{ kind = 'WEB'; instance = 'S1' }
    Assert-That ($j.ok -and $j.result.launcherOptions -gt 0) (ConvertTo-Json $j -Compress -Depth 5)
    $fields = @{}; foreach ($f in $j.result.fields) { $fields[$f.Key] = $f }
    $unset = @($j.result.fields | Where-Object { $_.Unset } | ForEach-Object { $_.Key })
    Assert-Equal @('RefreshMinutes', 'HealthCheckSeconds', 'BackButtonText', 'ParkMouse') $unset
    Assert-That ($fields.HealthCheckSeconds.Value -eq '20' -and $fields.HealthCheckSeconds.Kind -eq 'number') 'a number at its default'
    Assert-That ($fields.ParkMouse.Kind -eq 'bool' -and $fields.ParkMouse.Value -eq '1') 'a flag at its default'
    Assert-That ($unset -notcontains 'KioskMode' -and $unset -notcontains 'RefreshTimes') 'set under another name counts as set'
    Assert-That (-not $fields.ContainsKey('Password') -and -not $fields.ContainsKey('TestAllowHttpLogin')) 'never offered'
    Assert-That $fields.HealthCheckSeconds.Hint.Contains('1 to 600') $fields.HealthCheckSeconds.Hint
    Assert-That $fields.EnableRefresh.Hint.StartsWith('default off') 'the file''s own keys get the launcher''s hint too'
    Assert-That (@($j.result.fields | Where-Object { $_.Kind -eq 'note' }).Count) 'a note before the defaults'

    $values = @{}
    foreach ($f in $j.result.fields) { if ($f.Kind -notin 'note', 'password') { $values[$f.Key] = $f.Value } }
    $values.HealthCheckSeconds = '45'; $values.Password = 'hunter2'; $values.TestAllowHttpLogin = '1'; $values.Sneaky = 'x'
    $r, $j = Invoke-TestJob $admin 'NEWWEB1' 'config-write' @{ kind = 'WEB'; instance = 'S1'; values = $values }
    Assert-That $j.ok (ConvertTo-Json $j -Compress -Depth 5)
    $saved = Get-Content -Raw $path | ConvertFrom-Json -AsHashtable
    Assert-Equal '45' $saved.HealthCheckSeconds 'a changed default is saved'
    foreach ($k in 'ParkMouse', 'BackButtonText', 'RefreshMinutes', 'KioskMode') { Assert-That (-not $saved.Contains($k)) "$k was left at the default, so it is not written" }
    foreach ($k in 'Password', 'TestAllowHttpLogin', 'Sneaky') { Assert-That (-not $saved.Contains($k)) $k }
    Assert-That ($saved.FullScreenWindow -eq '1' -and $saved.DisplayURL -eq 'https://intranet.test/board') 'the rest as it was'
    Assert-Equal 'HealthCheckSeconds' @($saved.Keys)[-1] 'added after the file''s own keys'
}
