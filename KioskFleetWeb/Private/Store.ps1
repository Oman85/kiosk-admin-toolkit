# The app's own state, as files in the data folder:
#
#   users.json     accounts, laid out like the PowerShell server's
#                  web-users.json (Name, Role, Algorithm, Iterations, Salt,
#                  Hash, Disabled, ...). Set-KioskFleetUser.ps1 changes it while
#                  the server runs; the server reads it again when it changes.
#   sessions.json  signed-in sessions: the SHA-256 of each cookie, never the cookie
#   audit.jsonl    the audit log, one JSON object per line, append only
#
# The fleet itself stays in the events CSV, which other things (the Power BI
# report) read too. Wrong-password counts are kept in memory.

function Get-KfwNowText { [datetime]::Now.ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) }
function Get-KfwEpoch { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0 }

function Open-KfwStore([string]$Dir, [switch]$Server) {
    # -Server: the server's own, which keeps the sessions. The command line
    # opens it without: it changes accounts, and leaves sessions to the server.
    [void][IO.Directory]::CreateDirectory($Dir)
    $st = [hashtable]::Synchronized(@{
        Dir           = $Dir
        Server        = [bool]$Server
        UsersPath     = Join-Path $Dir 'users.json'
        SessionsPath  = Join-Path $Dir 'sessions.json'
        AuditPath     = Join-Path $Dir 'audit.jsonl'
        LockPath      = Join-Path $Dir 'users.lock'
        Lock          = [object]::new()
        Users         = $null
        UsersStamp    = ''
        Sessions      = [hashtable]::Synchronized(@{})
        SessionsDirty = $false
        Failures      = @{}
    })
    if ($Server) { Read-KfwSessions $st }
    return $st
}

function Get-KfwFileStamp([string]$Path) {
    try {
        $i = [IO.FileInfo]::new($Path)
        if (-not $i.Exists) { return 'none' }
        return "$($i.LastWriteTimeUtc.Ticks)|$($i.Length)"
    } catch { return 'none' }
}

function Write-KfwFileAtomic([string]$Path, [byte[]]$Data) {
    $tmp = Join-Path ([IO.Path]::GetDirectoryName($Path)) ('~' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp')
    try {
        [IO.File]::WriteAllBytes($tmp, $Data)
        # Windows refuses to replace a file someone is reading at that moment:
        # a few tries, a moment apart.
        for ($i = 1; ; $i++) {
            try { [IO.File]::Move($tmp, $Path, $true); break }
            catch { if ($i -ge 8) { throw }; Start-Sleep -Milliseconds (50 * $i) }
        }
    } finally {
        if ([IO.File]::Exists($tmp)) { try { [IO.File]::Delete($tmp) } catch { } }
    }
}

function Invoke-KfwStoreLocked($St, [scriptblock]$Body) {
    # One writer at a time: threads of this server, and the command line in
    # another process - another logon session, another account - through a
    # lock file in the data folder, which Windows and Linux both honour.
    [Threading.Monitor]::Enter($St.Lock)
    $file = $null
    try {
        $deadline = [datetime]::UtcNow.AddSeconds(15)
        while (-not $file) {
            try { $file = [IO.FileStream]::new($St.LockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
            catch [IO.IOException] {
                if ([datetime]::UtcNow -gt $deadline) { throw "the accounts are locked by another process ($($St.LockPath))" }
                Start-Sleep -Milliseconds 50
            }
        }
        return (& $Body)
    } finally {
        if ($file) { $file.Dispose() }
        [Threading.Monitor]::Exit($St.Lock)
    }
}

# --- accounts ---------------------------------------------------------------------
function Sync-KfwUsers($St) {
    $stamp = Get-KfwFileStamp $St.UsersPath
    if ($null -ne $St.Users -and $stamp -eq $St.UsersStamp) { return }
    $list = [Collections.Generic.List[object]]::new()
    if ($stamp -ne 'none') {
        $doc = ConvertFrom-Json ([IO.File]::ReadAllText($St.UsersPath)) -AsHashtable
        foreach ($u in @($doc.Users)) { if ($u) { $list.Add($u) } }
    }
    $St.Users = $list
    $St.UsersStamp = $stamp
}

function Save-KfwUsers($St) {
    $doc = [ordered]@{ Version = 1; Users = @($St.Users) }
    Write-KfwFileAtomic $St.UsersPath ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $doc -Depth 5)))
    $St.UsersStamp = Get-KfwFileStamp $St.UsersPath
}

function Find-KfwUserRecord($St, [string]$Name) {
    foreach ($u in $St.Users) { if ([string]::Equals([string]$u.Name, $Name, [StringComparison]::OrdinalIgnoreCase)) { return $u } }
    return $null
}

function ConvertTo-KfwUserView($u) {
    if (-not $u) { return $null }
    [ordered]@{
        name = [string]$u.Name; role = [string]$u.Role; disabled = [bool]$u.Disabled; must_change = [bool]$u.MustChange
        created = [string]$u.Created; updated = [string]$u.Updated; last_login = [string]$u.LastLogin
        sessions_after = [double]$u.SessionsAfter
    }
}

function Get-KfwUsers($St) {
    [Threading.Monitor]::Enter($St.Lock)
    try {
        Sync-KfwUsers $St
        $out = [Collections.Generic.List[object]]::new()
        foreach ($u in ($St.Users | Sort-Object { ([string]$_.Name).ToLowerInvariant() })) { $out.Add((ConvertTo-KfwUserView $u)) }
        return , $out
    } finally { [Threading.Monitor]::Exit($St.Lock) }
}

function Get-KfwUser($St, [string]$Name) {
    if (-not $Name) { return $null }
    [Threading.Monitor]::Enter($St.Lock)
    try {
        Sync-KfwUsers $St
        return ConvertTo-KfwUserView (Find-KfwUserRecord $St $Name)
    } finally { [Threading.Monitor]::Exit($St.Lock) }
}

function Get-KfwUserCount($St, [switch]$ActiveAdminsOnly) {
    [Threading.Monitor]::Enter($St.Lock)
    try {
        Sync-KfwUsers $St
        if ($ActiveAdminsOnly) { return @($St.Users | Where-Object { $_.Role -eq 'admin' -and -not $_.Disabled }).Count }
        return $St.Users.Count
    } finally { [Threading.Monitor]::Exit($St.Lock) }
}

function Set-KfwUserRecord($St, [string]$Name, [scriptblock]$Change) {
    Invoke-KfwStoreLocked $St {
        $St.Users = $null
        Sync-KfwUsers $St
        $u = Find-KfwUserRecord $St $Name
        if ($u) {
            & $Change $u
            $u.Updated = Get-KfwNowText
            Save-KfwUsers $St
        }
    } | Out-Null
}

function Add-KfwUser($St, [string]$Name, [string]$Role, [string]$Password, [bool]$MustChange = $false) {
    $h = New-KfwPasswordHash $Password
    Invoke-KfwStoreLocked $St {
        $St.Users = $null
        Sync-KfwUsers $St
        if (Find-KfwUserRecord $St $Name) { throw "There is an account called $Name already." }
        $now = Get-KfwNowText
        $St.Users.Add([ordered]@{
            Name = $Name; Role = $Role; Algorithm = $h.Algorithm; Iterations = $h.Iterations; Salt = $h.Salt; Hash = $h.Hash
            Disabled = $false; MustChange = $MustChange; Created = $now; Updated = $now; LastLogin = ''
        })
        Save-KfwUsers $St
    } | Out-Null
}

function Import-KfwUserRecord($St, [string]$Name, [string]$Role, $Record, [bool]$Disabled) {
    Invoke-KfwStoreLocked $St {
        $St.Users = $null
        Sync-KfwUsers $St
        $old = Find-KfwUserRecord $St $Name
        if ($old) { [void]$St.Users.Remove($old) }
        $now = Get-KfwNowText
        $St.Users.Add([ordered]@{
            Name = $Name; Role = $Role; Algorithm = [string]$Record.Algorithm; Iterations = [int]$Record.Iterations
            Salt = [string]$Record.Salt; Hash = [string]$Record.Hash; Disabled = $Disabled; MustChange = $false
            Created = $now; Updated = $now; LastLogin = ''
        })
        Save-KfwUsers $St
    } | Out-Null
}

function Set-KfwUserPassword($St, [string]$Name, [string]$Password, [bool]$MustChange = $false) {
    $h = New-KfwPasswordHash $Password
    Set-KfwUserRecord $St $Name {
        param($u)
        $u.Algorithm = $h.Algorithm; $u.Iterations = $h.Iterations; $u.Salt = $h.Salt; $u.Hash = $h.Hash; $u.MustChange = $MustChange
    }
}

function Set-KfwUserRole($St, [string]$Name, [string]$Role) {
    Set-KfwUserRecord $St $Name { param($u) $u.Role = $Role }
}

function Set-KfwUserDisabled($St, [string]$Name, [bool]$Disabled) {
    Set-KfwUserRecord $St $Name { param($u) $u.Disabled = $Disabled }
}

function Remove-KfwUser($St, [string]$Name) {
    Invoke-KfwStoreLocked $St {
        $St.Users = $null
        Sync-KfwUsers $St
        $u = Find-KfwUserRecord $St $Name
        if ($u) { [void]$St.Users.Remove($u); Save-KfwUsers $St }
    } | Out-Null
    Stop-KfwSessionsOf $St $Name
}

function Test-KfwLogin($St, [string]$Name, [string]$Password) {
    # The account for a name and password, or $null.
    $rec = $null
    if ($Name) {
        [Threading.Monitor]::Enter($St.Lock)
        try { Sync-KfwUsers $St; $rec = Find-KfwUserRecord $St $Name } finally { [Threading.Monitor]::Exit($St.Lock) }
    }
    if (-not $rec) {
        Invoke-KfwBurnTime $Password
        return $null
    }
    if (-not (Test-KfwPassword $rec $Password) -or $rec.Disabled -or -not $script:RoleRank.ContainsKey([string]$rec.Role)) { return $null }
    $who = [string]$rec.Name
    Set-KfwUserRecord $St $who { param($u) $u.LastLogin = Get-KfwNowText }
    return Get-KfwUser $St $who
}

function Import-KfwWebUsers($St, [string]$Path) {
    # Accounts from the PowerShell server's Config\web-users.json. Their
    # password hashes carry over as they are, so nobody needs a new password.
    $doc = ConvertFrom-Json ([IO.File]::ReadAllText($Path)) -AsHashtable
    $done = [Collections.Generic.List[string]]::new()
    foreach ($u in @($doc.Users)) {
        if (-not $u) { continue }
        $name = [string]$u.Name; $role = [string]$u.Role
        if (-not (Test-KfwUserName $name) -or -not $script:RoleRank.ContainsKey($role)) { continue }
        if ($u.Algorithm -ne 'PBKDF2-SHA256') { continue }
        Import-KfwUserRecord $St $name $role $u ([bool]$u.Disabled)
        $done.Add($name)
    }
    return , $done.ToArray()
}

# --- sessions ---------------------------------------------------------------------
function Read-KfwSessions($St) {
    $St.Sessions = [hashtable]::Synchronized(@{})
    try {
        if (Test-Path -LiteralPath $St.SessionsPath -PathType Leaf) {
            $doc = ConvertFrom-Json ([IO.File]::ReadAllText($St.SessionsPath)) -AsHashtable
            foreach ($s in @($doc.Sessions)) { if ($s -and $s.token_hash) { $St.Sessions[[string]$s.token_hash] = $s } }
        }
    } catch {
        Write-Warning "Sessions could not be read; everyone signs in again: $($_.Exception.Message)"
    }
}

function Save-KfwSessions($St) {
    [Threading.Monitor]::Enter($St.Lock)
    try {
        $doc = [ordered]@{ Sessions = @($St.Sessions.Values) }
        $St.SessionsDirty = $false
        Write-KfwFileAtomic $St.SessionsPath ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $doc -Depth 4 -Compress)))
    } catch {
        Write-Warning "Sessions could not be saved: $($_.Exception.Message)"
    } finally { [Threading.Monitor]::Exit($St.Lock) }
}

function New-KfwSession($St, [string]$User, [string]$Ip, [string]$Agent) {
    $token = New-KfwToken; $csrf = New-KfwToken
    $now = Get-KfwEpoch
    if ($Agent.Length -gt 200) { $Agent = $Agent.Substring(0, 200) }
    $St.Sessions[(Get-KfwTokenHash $token)] = [ordered]@{ token_hash = (Get-KfwTokenHash $token); user = $User; csrf = $csrf; created = $now; last_seen = $now; ip = $Ip; agent = $Agent }
    Save-KfwSessions $St
    return $token
}

function Get-KfwSession($St, [string]$Token, [int]$IdleMinutes, [int]$SessionHours) {
    # The session and its account, or $null if either has gone. A disabled
    # or removed account, or a changed role, takes effect at once.
    if (-not $Token) { return $null }
    $th = Get-KfwTokenHash $Token
    $s = $St.Sessions[$th]
    if (-not $s) { return $null }
    $u = Get-KfwUser $St ([string]$s.user)
    $now = Get-KfwEpoch
    if (-not $u -or $u.disabled -or ($now - [double]$s.last_seen) -gt $IdleMinutes * 60 -or ($now - [double]$s.created) -gt $SessionHours * 3600 -or
        [double]$s.created -lt $u.sessions_after) {
        $St.Sessions.Remove($th)
        Save-KfwSessions $St
        return $null
    }
    if (($now - [double]$s.last_seen) -gt 5) {
        $s.last_seen = $now
        $St.SessionsDirty = $true
    }
    return @{ user = $u.name; role = $u.role; csrf = [string]$s.csrf; must_change = $u.must_change; token_hash = $th }
}

function Stop-KfwSession($St, [string]$TokenHash) {
    $St.Sessions.Remove($TokenHash)
    Save-KfwSessions $St
}

function Stop-KfwSessionsOf($St, [string]$User, [string]$ExceptHash = '') {
    if (-not $St.Server) {
        # From the command line, while the server may hold the sessions: every
        # session of this account from before now is void, wherever it is kept.
        $now = Get-KfwEpoch
        Set-KfwUserRecord $St $User { param($u) $u.SessionsAfter = $now }
        return
    }
    foreach ($k in @($St.Sessions.Keys)) {
        $s = $St.Sessions[$k]
        if ($s -and [string]::Equals([string]$s.user, $User, [StringComparison]::OrdinalIgnoreCase) -and $k -ne $ExceptHash) { $St.Sessions.Remove($k) }
    }
    Save-KfwSessions $St
}

function Clear-KfwOldSessions($St, [int]$IdleMinutes, [int]$SessionHours) {
    $now = Get-KfwEpoch
    $gone = $false
    foreach ($k in @($St.Sessions.Keys)) {
        $s = $St.Sessions[$k]
        if ($s -and (([double]$s.last_seen) -lt $now - $IdleMinutes * 60 -or ([double]$s.created) -lt $now - $SessionHours * 3600)) {
            $St.Sessions.Remove($k); $gone = $true
        }
    }
    if ($gone -or $St.SessionsDirty) { Save-KfwSessions $St }
}

function Get-KfwActiveSessions($St) {
    $out = @{}
    foreach ($s in @($St.Sessions.Values)) {
        $k = ([string]$s.user).ToLowerInvariant()
        $out[$k] = 1 + [int]$out[$k]
    }
    return $out
}

# --- sign-in lockout --------------------------------------------------------------
function Test-KfwLocked($St, [string]$Key) {
    $f = $St.Failures[$Key]
    return [bool]($f -and $f.until -and (Get-KfwEpoch) -lt $f.until)
}

function Add-KfwLoginFailure($St, [string]$Key, [int]$Limit, [int]$Window = 900, [int]$LockFor = 900) {
    # Five wrong passwords for a name, or twenty from one address, inside
    # a quarter of an hour: that name or address waits a quarter of an hour.
    [Threading.Monitor]::Enter($St.Lock)
    try {
        $now = Get-KfwEpoch
        $f = $St.Failures[$Key]
        if (-not $f -or $now - $f.first -gt $Window) { $f = @{ count = 0; first = $now; until = $null } }
        $f.count++
        $f.until = if ($f.count -ge $Limit) { $now + $LockFor } else { $null }
        $St.Failures[$Key] = $f
    } finally { [Threading.Monitor]::Exit($St.Lock) }
}

function Clear-KfwLoginFailures($St, [string]$Key) {
    [Threading.Monitor]::Enter($St.Lock)
    try { $St.Failures.Remove($Key) } finally { [Threading.Monitor]::Exit($St.Lock) }
}

function Clear-KfwOldFailures($St) {
    [Threading.Monitor]::Enter($St.Lock)
    try {
        $now = Get-KfwEpoch
        foreach ($k in @($St.Failures.Keys)) {
            $f = $St.Failures[$k]
            if ($f.first -lt $now - 1800 -and (-not $f.until -or $f.until -lt $now)) { $St.Failures.Remove($k) }
        }
    } finally { [Threading.Monitor]::Exit($St.Lock) }
}

# --- audit ------------------------------------------------------------------------
function Write-KfwAudit {
    param($St, [string]$User = '', [string]$Role = '', [string]$Ip = '', [string]$Action = '', [string]$Target = '', [string]$Result = '', [string]$Detail = '')
    if ($Detail.Length -gt 600) { $Detail = $Detail.Substring(0, 600) }
    $e = [ordered]@{ Time = Get-KfwNowText; User = $User; Role = $Role; Ip = $Ip; Action = $Action; Target = $Target; Result = $Result; Detail = $Detail }
    $line = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $e -Compress) + "`n")
    [Threading.Monitor]::Enter($St.Lock)
    try {
        $fs = [IO.FileStream]::new($St.AuditPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        try { $fs.Write($line, 0, $line.Length) } finally { $fs.Dispose() }
    } finally { [Threading.Monitor]::Exit($St.Lock) }
}

function Read-KfwAuditLines($St) {
    if (-not (Test-Path -LiteralPath $St.AuditPath -PathType Leaf)) { return , @() }
    $fs = [IO.FileStream]::new($St.AuditPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try {
        $r = [IO.StreamReader]::new($fs, [Text.Encoding]::UTF8)
        $text = $r.ReadToEnd()
    } finally { $fs.Dispose() }
    return , $text.Split("`n", [StringSplitOptions]::RemoveEmptyEntries)
}

function Get-KfwAuditEntries($St, [int]$Limit = 400, [string]$Text = '') {
    $lines = Read-KfwAuditLines $St
    $out = [Collections.Generic.List[object]]::new()
    for ($i = $lines.Count - 1; $i -ge 0 -and $out.Count -lt $Limit; $i--) {
        try { $e = ConvertFrom-Json $lines[$i] -AsHashtable } catch { continue }
        if ($Text) {
            $hit = $false
            foreach ($f in 'User', 'Action', 'Target', 'Result', 'Detail') {
                if (([string]$e[$f]).IndexOf($Text, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true; break }
            }
            if (-not $hit) { continue }
        }
        $out.Add([ordered]@{ Time = [string]$e.Time; User = [string]$e.User; Role = [string]$e.Role; Ip = [string]$e.Ip; Action = [string]$e.Action
                Target = [string]$e.Target; Result = [string]$e.Result; Detail = [string]$e.Detail })
    }
    return , $out
}
