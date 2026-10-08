# Which settings a launcher reads from its config, and their defaults - read
# from the launcher script itself, so the config editor offers exactly what
# the version installed on a kiosk understands, not only the keys a config
# file happens to have.
#
# The launchers read every setting the same way, in Read-LauncherConfig:
#
#     Get-ConfigValue $raw @('Key', 'OldName') 'default'
#     ConvertTo-Flag (Get-ConfigValue $raw @('Key')) $true
#     ConvertTo-Number (Get-ConfigValue $raw @('Key')) 120 0 3600
#
# The first name is the key; the others are older names it still accepts.
# A default the script works out at run time (a log name, a profile folder)
# is not known here, and is left empty ($null).

$script:OptCall = [regex]'Get-ConfigValue\s+\$raw\s+@\(([^)]*)\)'
$script:OptName = [regex]"'([^']+)'"
$script:OptInline = [regex]"\G\s*'((?:[^']|'')*)'\s*\)"
$script:OptFlag = [regex]'\G\s*\)\s*\$(true|false)\b'
$script:OptNumber = [regex]'\G\s*\)\s*(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)'
$script:OptFunction = [regex]::new('^function\s+Read-LauncherConfig\b.*?^}', 'Multiline, Singleline, IgnoreCase')
# Never offered in the editor: a password in plain text (the editor hands
# passwords over as password.seed), and a switch only the tests use.
$script:HiddenOptions = @('password', 'testallowhttplogin')

function Get-KfwOptionNames($Opt) { , @(@($Opt.Key) + @($Opt.Aliases)) }

function Get-KfwOptionHint($Opt) {
    $bits = [Collections.Generic.List[string]]::new()
    if ($null -eq $Opt.Default) { $bits.Add('default worked out by the launcher') }
    elseif ($Opt.Kind -eq 'bool') { $bits.Add("default $(if ($Opt.Default -eq '1') { 'on' } else { 'off' })") }
    elseif ($Opt.Default -eq '') { $bits.Add('default empty') }
    else { $bits.Add("default $($Opt.Default)") }
    if ($Opt.Kind -eq 'number' -and $Opt.Minimum -and $Opt.Maximum) { $bits.Add("$($Opt.Minimum) to $($Opt.Maximum)") }
    if ($Opt.Aliases.Count) { $bits.Add('also read as ' + ($Opt.Aliases -join ', ')) }
    return $bits -join '; '
}

function ConvertTo-KfwOptNumber([string]$Text) {
    if ($Text.EndsWith('.0')) { return $Text.Substring(0, $Text.Length - 2) }
    return $Text
}

function Get-KfwLauncherOptions([string]$Script) {
    # The settings in a launcher script's Read-LauncherConfig, in the order it reads them.
    $m = $script:OptFunction.Match($Script)
    $body = if ($m.Success) { $m.Value } else { $Script }
    $found = [ordered]@{}
    foreach ($call in $script:OptCall.Matches($body)) {
        $names = @($script:OptName.Matches($call.Groups[1].Value) | ForEach-Object { $_.Groups[1].Value })
        if (-not $names.Count) { continue }
        $bs = [Math]::Max(0, $call.Index - 40)
        $before = $body.Substring($bs, $call.Index - $bs)
        $end = $call.Index + $call.Length
        $rest = $body.Substring($end, [Math]::Min(80, $body.Length - $end))
        $opt = [ordered]@{ Key = $names[0]; Aliases = [Collections.Generic.List[string]]::new([string[]]@($names | Select-Object -Skip 1)); Kind = 'text'; Default = $null; Minimum = ''; Maximum = '' }
        $flagBefore = $before -match 'ConvertTo-Flag\s*\(\s*$'
        $mi = $script:OptInline.Match($rest)
        $mf = $script:OptFlag.Match($rest)
        $mn = $script:OptNumber.Match($rest)
        if ($mi.Success) {
            $opt.Default = $mi.Groups[1].Value.Replace("''", "'")
        } elseif ($flagBefore -and $mf.Success) {
            $opt.Kind = 'bool'; $opt.Default = if ($mf.Groups[1].Value.ToLowerInvariant() -eq 'true') { '1' } else { '0' }
        } elseif ($before -match 'ConvertTo-Number\s*\(\s*$' -and $mn.Success) {
            $opt.Kind = 'number'
            $opt.Default = ConvertTo-KfwOptNumber $mn.Groups[1].Value
            $opt.Minimum = ConvertTo-KfwOptNumber $mn.Groups[2].Value
            $opt.Maximum = ConvertTo-KfwOptNumber $mn.Groups[3].Value
        } elseif ($flagBefore) {
            $opt.Kind = 'bool'
        }
        $k = $opt.Key.ToLowerInvariant()
        if (-not $found.Contains($k)) {
            $found[$k] = $opt
        } else {
            # Read twice (EnableRefresh, then its delay): keep what each says.
            $known = $found[$k]
            if ($null -eq $known.Default -and $null -ne $opt.Default) {
                $known.Kind = $opt.Kind; $known.Default = $opt.Default; $known.Minimum = $opt.Minimum; $known.Maximum = $opt.Maximum
            }
            foreach ($a in $opt.Aliases) { if (-not $known.Aliases.Contains($a)) { $known.Aliases.Add($a) } }
        }
    }
    return , @($found.Values)
}
