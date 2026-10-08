# Who may use the app, and what they may do.
#
#   operator  sees everything, and can do what cannot break a kiosk: scan now,
#             read live, screenshot, reload, restart the browser, a message on
#             the screen, the launcher log
#   admin     everything: restart a kiosk, hold/resume, stop, the sign-in
#             password, the kiosk config, auto-scan, stopping a run, the audit
#             log, users, settings and editing the kiosk list
#
# Passwords are kept as a salted PBKDF2-SHA256 hash, never the password - the
# same format as the PowerShell server's Config\web-users.json, which can be
# imported as it is.

$script:RoleRank = @{ operator = 1; admin = 2 }

# The least role each thing needs. Anything not listed needs admin.
$script:Permissions = [ordered]@{
    view = 'operator'; scan = 'operator'; live = 'operator'; snapshot = 'operator'
    reload = 'operator'; relaunch = 'operator'; message = 'operator'; log = 'operator'
    restart = 'admin'; hold = 'admin'; resume = 'admin'; stop = 'admin'; password = 'admin'
    config = 'admin'; autoscan = 'admin'; stoprun = 'admin'; audit = 'admin'
    users = 'admin'; settings = 'admin'; kiosklist = 'admin'
}

$script:HashIterations = 210000

function Test-KfwAllowed([string]$Role, [string]$Action) {
    if (-not $Role -or -not $script:RoleRank.ContainsKey($Role)) { return $false }
    $need = if ($script:Permissions.Contains($Action)) { $script:Permissions[$Action] } else { 'admin' }
    return $script:RoleRank[$Role] -ge $script:RoleRank[$need]
}

function Get-KfwAllowedActions([string]$Role) {
    $out = [Collections.Generic.List[string]]::new()
    foreach ($a in $script:Permissions.Keys) { if (Test-KfwAllowed $Role $a) { $out.Add($a) } }
    $out.Sort([StringComparer]::Ordinal)
    return , $out.ToArray()
}

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
