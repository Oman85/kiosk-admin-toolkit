# Who may use the app, and what they may do.
#
#   viewer    sees everything, and changes nothing
#   operator  sees everything, and can do what cannot break a kiosk: scan now,
#             read live, screenshot, reload, restart the browser, a message on
#             the screen, the launcher log
#   admin     everything: restart a kiosk, hold/resume, stop, the sign-in
#             password, the kiosk config, auto-scan, stopping a run, the audit
#             log, users, settings and editing the kiosk list
#
# The role is where an account starts. On top of it, an account can be given
# single permissions its role does not have (Grant), or have single ones of
# its role taken away (Deny): an operator who may also restart kiosks, say,
# or an admin who may not touch the kiosk configs. Seeing the fleet and
# managing the accounts go with the role only: everyone sees, and only
# admins manage accounts, so there is always an admin to undo a mistake.
#
# Passwords are kept as a salted PBKDF2-SHA256 hash, never the password - the
# same format as the PowerShell server's Config\web-users.json, which can be
# imported as it is.

$script:RoleRank = [ordered]@{ viewer = 0; operator = 1; admin = 2 }

# The least role each thing needs, and what the Users page calls it.
$script:Permissions = [ordered]@{
    view     = @{ role = 'viewer'; label = 'See the fleet, screens and history' }
    scan     = @{ role = 'operator'; label = 'Scan now' }
    live     = @{ role = 'operator'; label = 'Read live' }
    snapshot = @{ role = 'operator'; label = 'Take screenshots' }
    reload   = @{ role = 'operator'; label = 'Reload the page' }
    relaunch = @{ role = 'operator'; label = 'Restart the browser' }
    message  = @{ role = 'operator'; label = 'Put a message on the screen' }
    log      = @{ role = 'operator'; label = 'Read the launcher log' }
    restart  = @{ role = 'admin'; label = 'Restart the PC' }
    hold     = @{ role = 'admin'; label = 'Hold the launcher' }
    resume   = @{ role = 'admin'; label = 'Resume the launcher' }
    stop     = @{ role = 'admin'; label = 'Stop the launcher' }
    password = @{ role = 'admin'; label = 'Set the sign-in password' }
    config   = @{ role = 'admin'; label = 'Read and write the kiosk config, add screens' }
    autoscan = @{ role = 'admin'; label = 'Turn auto-scan on or off' }
    stoprun  = @{ role = 'admin'; label = 'Stop a running scan' }
    audit    = @{ role = 'admin'; label = 'Read the audit log' }
    settings = @{ role = 'admin'; label = 'Settings: upload the kiosk list, test a kiosk' }
    kiosklist = @{ role = 'admin'; label = 'Edit the kiosk list' }
    users    = @{ role = 'admin'; label = 'Manage the accounts' }
}

# These go with the role, and are never granted or denied one by one.
$script:RoleOnlyPermissions = @('view', 'users')

function Get-KfwRoles {
    # The roles, least first.
    return , [string[]]@($script:RoleRank.Keys)
}

function Test-KfwRoleHas([string]$Role, [string]$Permission) {
    # Whether a role, by itself, has a permission. Anything unknown: no.
    if (-not $Role -or -not $script:RoleRank.Contains($Role) -or -not $script:Permissions.Contains($Permission)) { return $false }
    return $script:RoleRank[$Role] -ge $script:RoleRank[$script:Permissions[$Permission].role]
}

function Test-KfwAdjustable([string]$Permission) {
    # Whether a permission can be granted or denied to one account.
    return $script:Permissions.Contains($Permission) -and $Permission -cnotin $script:RoleOnlyPermissions
}

function Get-KfwBadPermission($Names) {
    # The first name in a list that cannot be granted or denied, or $null.
    foreach ($n in @($Names)) { if (-not (Test-KfwAdjustable ([string]$n))) { return [string]$n } }
    return $null
}

function Get-KfwRightsOf([string]$Role, $Grant, $Deny) {
    # What an account may do: its role's permissions, plus what it was
    # granted, less what it was denied. Sorted; empty for an unknown role.
    $out = [Collections.Generic.List[string]]::new()
    if (-not $Role -or -not $script:RoleRank.Contains($Role)) { return , $out.ToArray() }
    $g = @($Grant | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $d = @($Deny | Where-Object { $_ } | ForEach-Object { [string]$_ })
    foreach ($p in $script:Permissions.Keys) {
        $has = Test-KfwRoleHas $Role $p
        if (Test-KfwAdjustable $p) {
            if ($g -ccontains $p) { $has = $true }
            if ($d -ccontains $p) { $has = $false }
        }
        if ($has) { $out.Add($p) }
    }
    $out.Sort([StringComparer]::Ordinal)
    return , $out.ToArray()
}

function Get-KfwRightsChange([string]$Role, $Grant, $Deny) {
    # A grant and deny list kept to what differs from the role: no grant of
    # what the role has anyway, no deny of what it does not have. Sorted.
    $g = [Collections.Generic.List[string]]::new(); $d = [Collections.Generic.List[string]]::new()
    foreach ($p in @($Grant | Where-Object { $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique -CaseSensitive)) {
        if ((Test-KfwAdjustable $p) -and -not (Test-KfwRoleHas $Role $p) -and @($Deny) -cnotcontains $p) { $g.Add($p) }
    }
    foreach ($p in @($Deny | Where-Object { $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique -CaseSensitive)) {
        if ((Test-KfwAdjustable $p) -and (Test-KfwRoleHas $Role $p)) { $d.Add($p) }
    }
    $g.Sort([StringComparer]::Ordinal); $d.Sort([StringComparer]::Ordinal)
    return @{ Grant = $g.ToArray(); Deny = $d.ToArray() }
}

function Test-KfwAllowed($Session, [string]$Action) {
    # Whether a signed-in session may do something. Anything not listed: no.
    if (-not $Session -or -not $Session.allowed) { return $false }
    return @($Session.allowed) -ccontains $Action
}

function Get-KfwPermissionCatalog {
    # Every permission, for the Users page: its name, what it is, the least
    # role that has it, and whether it can be granted or denied one by one.
    foreach ($p in $script:Permissions.Keys) {
        [ordered]@{ name = $p; label = $script:Permissions[$p].label; role = $script:Permissions[$p].role; adjustable = Test-KfwAdjustable $p }
    }
}

$script:HashIterations = 210000

function New-KfwToken([int]$Bytes = 32) {
    # URL-safe base64, as Python's secrets.token_urlsafe.
    $b = [Security.Cryptography.RandomNumberGenerator]::GetBytes($Bytes)
    [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-KfwTokenHash([string]$Token) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Token))).ToLowerInvariant()
}

function New-KfwPasswordHash([string]$Password, [int]$Iterations = $script:HashIterations) {
    $salt = [Security.Cryptography.RandomNumberGenerator]::GetBytes(16)
    $digest = [Security.Cryptography.Rfc2898DeriveBytes]::Pbkdf2([Text.Encoding]::UTF8.GetBytes($Password), $salt, $Iterations, [Security.Cryptography.HashAlgorithmName]::SHA256, 32)
    [ordered]@{ Algorithm = 'PBKDF2-SHA256'; Iterations = $Iterations; Salt = [Convert]::ToBase64String($salt); Hash = [Convert]::ToBase64String($digest) }
}

function Test-KfwPassword($Record, [string]$Password) {
    if (-not $Record -or $Record.Algorithm -ne 'PBKDF2-SHA256' -or -not $Record.Salt -or -not $Record.Hash) { return $false }
    try {
        $salt = [Convert]::FromBase64String([string]$Record.Salt)
        $want = [Convert]::FromBase64String([string]$Record.Hash)
        $got = [Security.Cryptography.Rfc2898DeriveBytes]::Pbkdf2([Text.Encoding]::UTF8.GetBytes([string]$Password), $salt, [int]$Record.Iterations, [Security.Cryptography.HashAlgorithmName]::SHA256, $want.Length)
        return [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($got, $want)
    } catch {
        return $false
    }
}

$script:DummyHash = $null

function Invoke-KfwBurnTime([string]$Password) {
    # A name that does not exist costs the same work as one that does, so
    # how long a sign-in takes says nothing about which names are real.
    if ($null -eq $script:DummyHash) { $script:DummyHash = New-KfwPasswordHash (New-KfwToken 16) }
    [void](Test-KfwPassword $script:DummyHash $Password)
}

function Test-KfwFixedTimeEquals([string]$A, [string]$B) {
    $a1 = [Text.Encoding]::UTF8.GetBytes([string]$A)
    $b1 = [Text.Encoding]::UTF8.GetBytes([string]$B)
    [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($a1, $b1)
}

function Test-KfwUserName([string]$Name) {
    [bool]($Name -cmatch '^[A-Za-z0-9][A-Za-z0-9._@-]{1,63}$')
}

function Get-KfwPasswordProblem([string]$Password, [string]$UserName = '') {
    # Why a password is not good enough, or $null. Enforced on the passwords
    # people choose for themselves (first setup, Change password, the change
    # at first sign-in); an admin setting one on the Users page or the command
    # line is only told.
    if (-not $Password -or $Password.Length -lt 12) { return 'at least 12 characters' }
    if ($Password.Length -gt 256) { return 'at most 256 characters' }
    if ($UserName -and $Password.ToLowerInvariant().Contains($UserName.ToLowerInvariant())) { return 'not containing the account name' }
    $kinds = 0
    foreach ($rx in '[a-z]', '[A-Z]', '[0-9]', '[^A-Za-z0-9]') { if ($Password -cmatch $rx) { $kinds++ } }
    if ($kinds -lt 3 -and $Password.Length -lt 20) { return 'three of: lower case, upper case, digits, symbols (or 20 characters or more)' }
    return $null
}
