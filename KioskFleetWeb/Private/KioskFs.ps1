# A kiosk's Public Documents - the only part of a kiosk this app reads or
# writes - as a path: \\KIOSK\C$\Users\Public\Documents (or the kiosk's own
# share) opened by Windows, or a local folder per kiosk for tests and demos.
#
# On a UNC path Windows signs in as the account the server runs under (a gMSA
# or a domain account with change rights on the share), or - with a share
# account set - with that account, connected once per kiosk the way
# New-PSDrive connected the PowerShell tools. Reads open each file with
# share mode read/write/delete, so a launcher can keep appending to or
# rolling over a file while it is read.

$script:HostPattern = [regex]'^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$'
$script:Connected = [hashtable]::Synchronized(@{})
$script:ReadShare = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete

function New-KfwKioskError([string]$Message) {
    # Something a person can read: offline, no access, not found.
    $e = [IO.IOException]::new($Message)
    $e.Data['KfwKiosk'] = $true
    return $e
}

function Test-KfwKioskError($Exception) { [bool]($Exception -and $Exception.Data.Contains('KfwKiosk')) }

function Join-KfwPath([string]$Base, [string[]]$Parts) {
    # Paths are written the Windows way (Mach2LauncherNG\S1); each part is
    # split and joined with this system's separator.
    $p = $Base
    foreach ($part in $Parts) {
        foreach ($bit in ($part -split '[\\/]+')) { if ($bit) { $p = [IO.Path]::Combine($p, $bit) } }
    }
    return $p
}

function Get-KfwDocs($S, [string]$HostName) {
    # The kiosk's Public Documents: the root of its share.
    ([string]$S.ShareTemplate).Replace('{0}', $HostName)
}

function Get-KfwShareRoot([string]$Unc) {
    # \\SERVER\SHARE of a UNC path.
    $bits = $Unc.TrimStart('\').Split('\')
    if ($bits.Count -lt 2) { return $Unc }
    return "\\$($bits[0])\$($bits[1])"
}

$script:MprLoaded = $false

function Connect-KfwShareAccount([string]$ShareRoot, [string]$User, [string]$Password) {
    if (-not $script:MprLoaded) {
        Add-Type -Namespace KioskFleetWeb -Name Mpr -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public class NetResource {
    public int Scope; public int Type; public int DisplayType; public int Usage;
    public string LocalName; public string RemoteName; public string Comment; public string Provider;
}
[DllImport("mpr.dll", CharSet = CharSet.Unicode)]
public static extern int WNetAddConnection2(NetResource netResource, string password, string username, int flags);
'@
        $script:MprLoaded = $true
    }
    $nr = [KioskFleetWeb.Mpr+NetResource]::new()
    $nr.Type = 1   # RESOURCETYPE_DISK
    $nr.RemoteName = $ShareRoot
    $rc = [KioskFleetWeb.Mpr]::WNetAddConnection2($nr, $Password, $User, 0)
    # 1219: this logon already has a connection to the server - usable, if it
    # is with the same account, which for this server it is.
    if ($rc -ne 0 -and $rc -ne 1219) {
        throw (New-KfwKioskError "cannot open ${ShareRoot}: $([ComponentModel.Win32Exception]::new($rc).Message) ($rc)")
    }
}

function Connect-KfwKiosk($S, [string]$HostName) {
    # The kiosk's Public Documents, opened. Throws a kiosk error if it cannot be.
    $docs = Get-KfwDocs $S $HostName
    if (Test-KfwUsesUnc $S) {
        $problem = Get-KfwShareProblem $S
        if ($problem) { throw (New-KfwKioskError $problem) }
        if (Test-KfwHasCredential $S) {
            $root = Get-KfwShareRoot $docs
            $key = $root.ToLowerInvariant()
            $last = $script:Connected[$key]
            if (-not $last -or ([datetime]::UtcNow - $last).TotalMinutes -gt 10 -or -not [IO.Directory]::Exists($docs)) {
                Connect-KfwShareAccount $root $S.ShareUser $S.SharePassword
                $script:Connected[$key] = [datetime]::UtcNow
            }
        }
    }
    if (-not [IO.Directory]::Exists($docs)) { throw (New-KfwKioskError "cannot read $docs") }
    return $docs
}

function Get-KfwEntries([string]$Dir) {
    # Its entries, or none when it is not there or not readable.
    $out = [Collections.Generic.List[object]]::new()
    try {
        foreach ($i in [IO.DirectoryInfo]::new($Dir).EnumerateFileSystemInfos()) {
            try {
                $isDir = ($i.Attributes -band [IO.FileAttributes]::Directory) -ne 0
                $out.Add([pscustomobject]@{ Name = $i.Name; Path = $i.FullName; IsDir = $isDir; MTime = $i.LastWriteTimeUtc; Size = $(if ($isDir) { 0 } else { $i.Length }) })
            } catch { }
        }
    } catch { }
    return , $out
}

function Get-KfwDirs([string]$Dir) {
    , @((Get-KfwEntries $Dir) | Where-Object IsDir)
}

function Get-KfwFiles([string]$Dir, [string]$Pattern = '') {
    # A glob as Windows has it: * and ?, any case.
    $rx = $null
    if ($Pattern) { $rx = [regex]::new('^' + ([regex]::Escape($Pattern) -replace '\\\*', '.*' -replace '\\\?', '.') + '$', 'IgnoreCase') }
    , @((Get-KfwEntries $Dir) | Where-Object { -not $_.IsDir -and (-not $rx -or $rx.IsMatch($_.Name)) })
}

function Test-KfwFile([string]$Path) { [IO.File]::Exists($Path) }
function Test-KfwDir([string]$Path) { [IO.Directory]::Exists($Path) }

function Get-KfwMTime([string]$Path) {
    $i = [IO.FileInfo]::new($Path)
    if ($i.Exists) { return $i.LastWriteTimeUtc }
    return $null
}

function Read-KfwBytes([string]$Path, [long]$Tail = 0, [long]$Head = 0) {
    # The whole file, or only its last Tail / first Head bytes.
    $fs = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $script:ReadShare)
    try {
        if ($Head -gt 0) {
            $n = [Math]::Min($Head, $fs.Length)
        } else {
            if ($Tail -gt 0 -and $fs.Length -gt $Tail) { [void]$fs.Seek(-$Tail, [IO.SeekOrigin]::End) }
            $n = $fs.Length - $fs.Position
        }
        $buf = [byte[]]::new($n)
        $got = 0
        while ($got -lt $n) {
            $r = $fs.Read($buf, $got, $n - $got)
            if ($r -le 0) { break }
            $got += $r
        }
        if ($got -lt $n) { [Array]::Resize([ref]$buf, $got) }
        return , $buf
    } finally { $fs.Dispose() }
}

function Read-KfwText([string]$Path, [long]$Tail = 0, [long]$Head = 0) {
    $b = Read-KfwBytes $Path $Tail $Head
    $start = 0
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $start = 3 }
    return [Text.Encoding]::UTF8.GetString($b, $start, $b.Length - $start)
}

function Read-KfwJsonFile([string]$Path) {
    # A JSON file's object (the first, if it is a list), or $null.
    try {
        $v = ConvertFrom-Json (Read-KfwText $Path) -AsHashtable -Depth 20
        if ($v -is [Collections.IList]) { if ($v.Count) { return $v[0] } else { return $null } }
        return $v
    } catch { return $null }
}

function Write-KfwKioskText([string]$Path, [string]$Text, [switch]$Bom) {
    # Written whole under a temporary name, then moved into place, so nobody
    # on the kiosk ever reads half of it.
    $enc = [Text.UTF8Encoding]::new($false)
    $data = $enc.GetBytes($Text)
    if ($Bom) { $data = [byte[]](@(0xEF, 0xBB, 0xBF) + $data) }
    $dir = [IO.Path]::GetDirectoryName($Path)
    $tmp = [IO.Path]::Combine($dir, '~' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp')
    [IO.File]::WriteAllBytes($tmp, $data)
    try {
        try {
            [IO.File]::Move($tmp, $Path, $true)
        } catch {
            # Some servers refuse to replace a file they would let us delete.
            # Delete, then move: a moment without the file, but never half of one.
            if (-not [IO.File]::Exists($Path)) { throw }
            [IO.File]::Delete($Path)
            [IO.File]::Move($tmp, $Path)
        }
    } catch {
        try { [IO.File]::Delete($tmp) } catch { }
        throw
    }
}

function Remove-KfwKioskFile([string]$Path) {
    try { [IO.File]::Delete($Path) } catch { if ([IO.File]::Exists($Path)) { throw } }
}

function Copy-KfwToLocal([string]$Source, [string]$Dest) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Dest))
    [IO.File]::WriteAllBytes($Dest, (Read-KfwBytes $Source))
}
