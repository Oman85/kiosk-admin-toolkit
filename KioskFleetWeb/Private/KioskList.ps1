# The kiosk list: which kiosks to scan, and what they are.
#
# A .xlsx workbook (the master list), a .csv, or a .txt with one name per
# line. The .xlsx reader is a plain OOXML zip + XML walk: no Excel needed.

$script:XlsxNs = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
$script:RelNs = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
$script:PkgRelNs = 'http://schemas.openxmlformats.org/package/2006/relationships'

function New-KfwRawRow([string]$HostName, [string]$Location = '', [string]$Type = '', [string]$HasMwst = '', [string]$Active = '', [string]$RestartGroup = '', [string]$Info = '', [string]$ListedVersion = '', [string]$Sheet = '') {
    [ordered]@{ Host = $HostName; Location = $Location; Type = $Type; HasMwst = $HasMwst; Active = $Active; RestartGroup = $RestartGroup
        Info = $Info; ListedVersion = $ListedVersion; Sheet = $Sheet }
}

function Test-KfwPowerBi([string]$Kind) { [bool]($Kind -and $Kind.Trim() -match '^(PBI|POWER\s*BI)\b') }
function Test-KfwWeb([string]$Kind) { [bool]($Kind -and $Kind.Trim() -match '^WEB\b') }

# --- .xlsx ---------------------------------------------------------------------------
function Get-KfwColumnIndex([string]$Ref) {
    $n = 0
    foreach ($ch in ($Ref -replace '\d', '').ToUpperInvariant().ToCharArray()) { $n = $n * 26 + ([int]$ch - 64) }
    return $n
}

function Get-KfwSiText($Node) {
    # A shared string is a plain <t>, or <r><t> runs when part of the cell is
    # formatted differently; both are joined or names come back cut short.
    $out = ''
    foreach ($child in $Node.ChildNodes) {
        if ($child.LocalName -eq 't') { $out += $child.InnerText }
        elseif ($child.LocalName -eq 'r') { foreach ($rc in $child.ChildNodes) { if ($rc.LocalName -eq 't') { $out += $rc.InnerText } } }
    }
    return $out
}

function Read-KfwXlsx([string]$Path, [string]$SheetName = '') {
    Add-Type -AssemblyName System.IO.Compression
    $rows = [Collections.Generic.List[object]]::new()
    $fs = [IO.File]::OpenRead($Path)
    try {
        $z = [IO.Compression.ZipArchive]::new($fs, [IO.Compression.ZipArchiveMode]::Read)
        $xml = {
            param($name)
            $e = $z.GetEntry($name)
            if (-not $e) { return $null }
            $d = [xml]::new()
            $d.XmlResolver = $null
            $st = $e.Open()
            try { $d.Load($st) } finally { $st.Dispose() }
            return $d
        }
        $shared = [Collections.Generic.List[string]]::new()
        $ss = & $xml 'xl/sharedStrings.xml'
        if ($ss) { foreach ($si in $ss.DocumentElement.ChildNodes) { if ($si.LocalName -eq 'si') { $shared.Add((Get-KfwSiText $si)) } } }
        $wb = & $xml 'xl/workbook.xml'
        $rels = & $xml 'xl/_rels/workbook.xml.rels'
        if (-not $wb -or -not $rels) { throw "not a readable .xlsx workbook: $Path" }
        $targets = @{}
        foreach ($r in $rels.DocumentElement.ChildNodes) { if ($r.LocalName -eq 'Relationship') { $targets[$r.GetAttribute('Id')] = $r.GetAttribute('Target') } }
        $ns = [Xml.XmlNamespaceManager]::new($wb.NameTable)
        $ns.AddNamespace('m', $script:XlsxNs)
        $sheets = @($wb.SelectNodes('/m:workbook/m:sheets/m:sheet', $ns))
        if ($SheetName) {
            $sheets = @($sheets | Where-Object { $_.GetAttribute('name') -ceq $SheetName })
            if (-not $sheets.Count) { throw "sheet '$SheetName' not found in $Path" }
        }
        foreach ($sheet in $sheets) {
            $target = $targets[$sheet.GetAttribute('id', $script:RelNs)]
            if (-not $target) { continue }
            $target = $target -replace '^/?(xl/)?', ''
            $doc = & $xml ('xl/' + $target)
            if (-not $doc) { continue }
            foreach ($r in (Get-KfwSheetRows $doc $shared $sheet.GetAttribute('name'))) { $rows.Add($r) }
        }
        $z.Dispose()
    } finally { $fs.Dispose() }
    return , $rows
}

function Get-KfwSheetRows($Doc, $Shared, [string]$Sheet) {
    $ns = [Xml.XmlNamespaceManager]::new($Doc.NameTable)
    $ns.AddNamespace('m', $script:XlsxNs)
    $grid = [Collections.Generic.SortedDictionary[int, object]]::new()
    foreach ($row in $Doc.SelectNodes('/m:worksheet/m:sheetData/m:row', $ns)) {
        $rnum = 0
        [void][int]::TryParse($row.GetAttribute('r'), [ref]$rnum)
        $cells = @{}
        foreach ($c in $row.SelectNodes('m:c', $ns)) {
            $ref = $c.GetAttribute('r')
            if (-not $ref) { continue }
            $t = $c.GetAttribute('t')
            $v = $c.SelectSingleNode('m:v', $ns)
            $value = $null
            if ($t -eq 's') {
                $i = 0
                if ($v -and $v.InnerText -match '^\d+$' -and [int]::TryParse($v.InnerText, [ref]$i) -and $i -lt $Shared.Count) { $value = $Shared[$i] }
            } elseif ($t -eq 'inlineStr') {
                $is = $c.SelectSingleNode('m:is', $ns)
                if ($is) { $value = Get-KfwSiText $is }
            } elseif ($v) {
                $value = $v.InnerText
            }
            if ($null -ne $value) { $cells[(Get-KfwColumnIndex $ref)] = ([string]$value).Trim() }
        }
        $grid[$rnum] = $cells
    }
    $numbers = @($grid.Keys)
    $headerRow = $null; $header = @{}
    # The header is the first row, within the first ten, naming the host column.
    foreach ($rnum in ($numbers | Select-Object -First 10)) {
        $m = @{}
        foreach ($ci in $grid[$rnum].Keys) {
            $v = $grid[$rnum][$ci]
            if ($v) {
                $key = ($v -replace '\s+', ' ').Trim().ToUpperInvariant()
                $m[$key] = $ci
            }
        }
        if ($m.ContainsKey('NAME') -or $m.ContainsKey('HOST') -or $m.ContainsKey('HOSTNAME')) { $headerRow = $rnum; $header = $m; break }
    }
    $out = [Collections.Generic.List[object]]::new()
    if ($null -eq $headerRow) { return , $out }
    $col = { foreach ($n in $args) { if ($header.ContainsKey($n)) { return $header[$n] } }; return $null }
    $cHost = & $col 'NAME' 'HOST' 'HOSTNAME'
    $cType = & $col 'TYPE'; $cFlag = & $col 'HAS MWST' 'HASMWST' 'MWST'; $cActive = & $col 'ACTIVE' 'IS ACTIVE'
    $cLoc = & $col 'LOCATION'; $cGroup = & $col 'RESTART GROUP' 'GROUP'; $cInfo = & $col 'INFO'; $cVer = & $col 'VER' 'VERSION'
    foreach ($rnum in $numbers) {
        if ($rnum -le $headerRow) { continue }
        $cells = $grid[$rnum]
        $g = { param($c) if ($null -ne $c -and $cells.ContainsKey($c)) { [string]$cells[$c] } else { '' } }
        $hostName = (& $g $cHost).Trim()
        if (-not $hostName) { continue }
        $out.Add((New-KfwRawRow $hostName (& $g $cLoc) (& $g $cType) (& $g $cFlag) (& $g $cActive) (& $g $cGroup) (& $g $cInfo) (& $g $cVer) $Sheet))
    }
    return , $out
}

# --- flat files --------------------------------------------------------------------------
function Read-KfwFlatList([string]$Path) {
    $text = Read-KfwFileText $Path
    $out = [Collections.Generic.List[object]]::new()
    if ([IO.Path]::GetExtension($Path).ToLowerInvariant() -eq '.csv') {
        $records = [KioskFleetWeb.Csv]::Records($text)
        if (-not $records.Count) { return , $out }
        $header = $records[0]
        for ($i = 1; $i -lt $records.Count; $i++) {
            $f = $records[$i]
            $r = @{}
            for ($j = 0; $j -lt $header.Length; $j++) { $r[$header[$j]] = if ($j -lt $f.Length) { $f[$j] } else { $null } }
            $get = { param($k) if ($r.ContainsKey($k) -and $null -ne $r[$k]) { [string]$r[$k] } else { '' } }
            $hostName = (& $get 'Host')
            if (-not $hostName) { $hostName = (& $get 'Name') }
            $hostName = $hostName.Trim()
            if (-not $hostName) { continue }
            $has = if ($r.ContainsKey('HasMwst')) { [string]$r['HasMwst'] } else { 'Y' }
            $out.Add((New-KfwRawRow $hostName (& $get 'Location') (& $get 'Type') $has (& $get 'Active') (& $get 'RestartGroup') (& $get 'Info') (& $get 'Version') 'csv'))
        }
        return , $out
    }
    # One name per line; everything in such a file runs the watchdog.
    foreach ($line in ($text -split "\r\n|\n|\r")) {
        $l = $line.Trim()
        if (-not $l -or $l.StartsWith('#')) { continue }
        $out.Add((New-KfwRawRow $l '' 'Mach2' 'Y' '' '' '' '' 'txt'))
    }
    return , $out
}

function Read-KfwListRows([string]$Path, [string]$SheetName = '') {
    # Every row of the list, scanned or not, as it is in the file.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "kiosk list not found: $Path" }
    if ([IO.Path]::GetExtension($Path).ToLowerInvariant() -eq '.xlsx') { return , (Read-KfwXlsx $Path $SheetName) }
    return , (Read-KfwFlatList $Path)
}

function Get-KfwSkipReason($Row, [bool]$IncludeAll = $false) {
    # Why a row is not scanned ("inactive", "not flagged"), or "" when it is.
    #
    # ACTIVE is a deliberate yes/no and beats everything else; left blank it
    # says nothing. HAS MWST = Y means the kiosk runs the watchdog. Power BI
    # and web page kiosks are scanned without it, since a dark screen is as
    # visible as a white one.
    if ($IncludeAll) { return '' }
    $active = ([string]$Row.Active).Trim()
    if ($active -and -not $active.ToUpperInvariant().StartsWith('Y')) { return 'inactive' }
    if (-not $active -and -not ([string]$Row.HasMwst).Trim().ToUpperInvariant().StartsWith('Y') -and -not (Test-KfwPowerBi $Row.Type) -and -not (Test-KfwWeb $Row.Type)) { return 'not flagged' }
    return ''
}

function Import-KfwKioskList([string]$Path, [string]$SheetName = '', [bool]$IncludeAll = $false) {
    # The kiosks to scan, and what was kept and skipped: @{ Kiosks; Stats }.
    $raw = Read-KfwListRows $Path $SheetName
    $stats = [ordered]@{ Rows = 0; Included = 0; Inactive = 0; NotFlagged = 0; InactiveRows = [Collections.Generic.List[object]]::new() }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $kiosks = [Collections.Generic.List[object]]::new()
    foreach ($row in $raw) {
        $stats.Rows++
        $why = Get-KfwSkipReason $row $IncludeAll
        if ($why -eq 'inactive') { $stats.Inactive++; $stats.InactiveRows.Add($row); continue }
        if ($why) { $stats.NotFlagged++; continue }
        if (-not $seen.Add($row.Host.ToUpperInvariant())) { continue }
        $stats.Included++
        $pbi = Test-KfwPowerBi $row.Type; $web = Test-KfwWeb $row.Type
        $has = ([string]$row.HasMwst).Trim().ToUpperInvariant().StartsWith('Y')
        $kiosks.Add([ordered]@{
            Host = $row.Host; Location = $row.Location; Type = $row.Type; RestartGroup = $row.RestartGroup; Info = $row.Info
            ListedVersion = $row.ListedVersion; Sheet = $row.Sheet; Active = $row.Active
            RunsWatchdog = $has -and -not $pbi -and -not $web; PingOnly = $pbi -or $web -or -not $has
        })
    }
    return @{ Kiosks = $kiosks; Stats = $stats }
}

# --- editing the list in the app ------------------------------------------------------------
$script:EditColumns = @('Host', 'Location', 'Type', 'HasMwst', 'Active', 'RestartGroup', 'Info', 'Version')

function ConvertTo-KfwListCsv($Rows) {
    # The list as the .csv the app keeps once it has been edited here: the
    # same columns Read-KfwFlatList reads, so it can be downloaded, changed
    # in Excel and uploaded again.
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append([char]0xFEFF).Append(($script:EditColumns -join ',')).Append("`r`n")
    foreach ($r in $Rows) {
        $f = @($r.Host, $r.Location, $r.Type, $r.HasMwst, $r.Active, $r.RestartGroup, $r.Info, $r.ListedVersion)
        [void]$sb.Append((($f | ForEach-Object { [KioskFleetWeb.Csv]::Field([string]$_, $false) }) -join ',')).Append("`r`n")
    }
    return [Text.Encoding]::UTF8.GetBytes($sb.ToString())
}
