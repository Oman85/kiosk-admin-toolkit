# CSV, through the small compiled reader in Csv.cs: rows are
# Dictionary[string,string] keyed by the header's names, case as written.

if (-not ('KioskFleetWeb.Csv' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'Csv.cs')
}

function ConvertFrom-KfwCsvText([string]$Text) {
    , [KioskFleetWeb.Csv]::Rows($Text)
}

function Read-KfwFileText([string]$Path) {
    # The file as text: UTF-8, its BOM dropped, bad bytes replaced.
    $b = [IO.File]::ReadAllBytes($Path)
    $start = 0
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $start = 3 }
    return [Text.Encoding]::UTF8.GetString($b, $start, $b.Length - $start)
}

function Read-KfwCsvRows([string]$Path) {
    # Every row of a CSV file, or none when it is not there.
    if (-not $Path -or -not [IO.File]::Exists($Path)) { return , [Collections.Generic.List[Collections.Generic.Dictionary[string, string]]]::new() }
    return , [KioskFleetWeb.Csv]::Rows((Read-KfwFileText $Path))
}

function ConvertTo-KfwCsvText($Rows, [string[]]$Columns, [switch]$QuoteAll) {
    [KioskFleetWeb.Csv]::Write($Rows, $Columns, [bool]$QuoteAll)
}

function Get-KfwSorted($Items, [scriptblock]$Key, [switch]$Descending) {
    # A stable sort by a string key, compared character by character - as
    # Python sorts - and not by the culture's rules, as Sort-Object does.
    $list = [Collections.Generic.List[object]]::new()
    foreach ($i in $Items) { $list.Add($i) }
    $keys = [string[]]::new($list.Count)
    for ($i = 0; $i -lt $list.Count; $i++) { $keys[$i] = [string](& $Key $list[$i]) }
    $idx = [KioskFleetWeb.Csv]::Order($keys, [bool]$Descending)
    $out = [object[]]::new($list.Count)
    for ($i = 0; $i -lt $idx.Length; $i++) { $out[$i] = $list[$idx[$i]] }
    return , $out
}
