# Times, the way every file here writes them: ISO 8601, culture-invariant.
# Inside the module a time is a [datetime] of Kind Utc; local time is the
# server's own time zone.

$script:Invariant = [Globalization.CultureInfo]::InvariantCulture

$script:IsoRx = [regex]'^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d+))?)?)?\s*(Z|z|[+-]\d{2}:?\d{2})?$'
$script:UsRx = [regex]'^(\d{1,2})/(\d{1,2})/(\d{4}) (\d{1,2}):(\d{2}):(\d{2})$'

function Get-UtcNow { [datetime]::UtcNow }

function ConvertTo-UtcIso([datetime]$Time) {
    $Time.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $script:Invariant)
}

function ConvertTo-LocalIso([datetime]$Time) {
    $Time.ToUniversalTime().ToLocalTime().ToString('yyyy-MM-ddTHH:mm:ss', $script:Invariant)
}

function ConvertTo-LocalDate([datetime]$Time) {
    $Time.ToUniversalTime().ToLocalTime().ToString('yyyy-MM-dd', $script:Invariant)
}

function Format-Local([datetime]$Time, [string]$Format) {
    $Time.ToUniversalTime().ToLocalTime().ToString($Format, $script:Invariant)
}

function ConvertFrom-UtcText($Text) {
    # "2026-09-18T14:33:33Z", with or without a fraction or an offset, as a
    # UTC [datetime] - or $null. A time with no zone at all is taken as UTC.
    # Never throws: a half-written file must not stop anything.
    if ($null -eq $Text) { return $null }
    $s = ([string]$Text).Trim()
    if (-not $s) { return $null }
    try {
        $m = $script:IsoRx.Match($s)
        if ($m.Success) {
            $g = $m.Groups
            $hour = if ($g[4].Success) { [int]$g[4].Value } else { 0 }
            $min = if ($g[5].Success) { [int]$g[5].Value } else { 0 }
            $sec = if ($g[6].Success) { [int]$g[6].Value } else { 0 }
            $t = [datetime]::new([int]$g[1].Value, [int]$g[2].Value, [int]$g[3].Value, $hour, $min, $sec, [DateTimeKind]::Utc)
            if ($g[7].Success) {
                $frac = ($g[7].Value + '0000000').Substring(0, 7)
                $t = $t.AddTicks([long]$frac)
            }
            if ($g[8].Success -and $g[8].Value -notin 'Z', 'z') {
                $z = $g[8].Value -replace ':', ''
                $offset = [timespan]::new([int]$z.Substring(1, 2), [int]$z.Substring(3, 2), 0)
                if ($z[0] -eq '-') { $t = $t + $offset } else { $t = $t - $offset }
            }
            return $t
        }
        $m = $script:UsRx.Match($s)
        if ($m.Success) {
            $g = $m.Groups
            return [datetime]::new([int]$g[3].Value, [int]$g[1].Value, [int]$g[2].Value, [int]$g[4].Value, [int]$g[5].Value, [int]$g[6].Value, [DateTimeKind]::Utc)
        }
    } catch {
        return $null
    }
    return $null
}

function ConvertFrom-LocalText($Text) {
    # The CSV's EventTimeLocal ("2026-09-18T16:33:33"), as a UTC [datetime].
    if (-not $Text) { return $null }
    $t = [datetime]::MinValue
    if ([datetime]::TryParseExact(([string]$Text).Trim(), 'yyyy-MM-ddTHH:mm:ss', $script:Invariant, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$t)) {
        return $t.ToUniversalTime()
    }
    return $null
}

function Get-LocalMidnightUtc([datetime]$LocalDate) {
    # Midnight of a local calendar day, as UTC.
    [datetime]::SpecifyKind($LocalDate.Date, [DateTimeKind]::Local).ToUniversalTime()
}

function Format-Minutes($Minutes) {
    # 7m, 5h, 3d
    if ($null -eq $Minutes -or ($Minutes -is [string] -and $Minutes -eq '')) { return '' }
    $m = 0.0
    if (-not [double]::TryParse([string]$Minutes, [Globalization.NumberStyles]::Float, $script:Invariant, [ref]$m)) { return '' }
    $m = [Math]::Max(0.0, $m)
    if ($m -lt 60) { return "$([int][Math]::Floor($m))m" }
    if ($m -lt 2880) { return "$([int][Math]::Floor($m / 60))h" }
    return "$([int][Math]::Floor($m / 1440))d"
}

function Get-MinutesBetween([datetime]$Later, [datetime]$Earlier) {
    ($Later - $Earlier).TotalMinutes
}

function Get-KfwRound([double]$Value, [int]$Decimals) {
    # Python's round(): the double's own value, half to even - not .NET's
    # Math.Round, which rounds 2.675 up although the double is 2.67499...
    $d = [decimal]::Parse($Value.ToString('G17', $script:Invariant), [Globalization.NumberStyles]::Float, $script:Invariant)
    [double][Math]::Round($d, $Decimals, [MidpointRounding]::ToEven)
}

function Format-Float([double]$Value) {
    # Python's repr() of a float, as far as these files need it.
    $Value.ToString('R', $script:Invariant)
}
