# Settings: KFW_* environment variables, then kfw.env in the data folder
# (KEY=VALUE lines - the scheduled task that runs the server has no
# environment of its own), then the defaults. A secret can come from a file
# instead: KFW_SHARE_PASSWORD_FILE next to KFW_SHARE_PASSWORD.

$script:DefaultShare = '\\{0}\C$\Users\Public\Documents'
$script:ModuleRoot = Split-Path -Parent $PSScriptRoot

function Get-KfwDefaultDataDir {
    if ($IsWindows) { return (Join-Path $env:ProgramData 'KioskFleetWeb') }
    return '/var/lib/kiosk-fleet-web'
}

function Read-KfwEnvFile([string]$Path) {
    $out = @{}
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $out }
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        $k = $t.Substring(0, $i).Trim()
        $v = $t.Substring($i + 1).Trim()
        if ($v.Length -ge 2 -and (($v[0] -eq '"' -and $v[-1] -eq '"') -or ($v[0] -eq "'" -and $v[-1] -eq "'"))) { $v = $v.Substring(1, $v.Length - 2) }
        $out[$k] = $v
    }
    return $out
}

function New-KfwSettings {
    # Every setting at its default. load reads the environment over these.
    [ordered]@{
        DataDir                 = Get-KfwDefaultDataDir
        # Each kiosk's Public Documents folder - the only part of a kiosk this
        # app reads or writes. {0} is the host name. A UNC path is opened by
        # Windows, as the account the server runs under or with the share
        # account; anything else is a local folder per kiosk (tests, demos, or
        # shares mounted on Linux).
        ShareTemplate           = $script:DefaultShare
        ShareUser               = ''
        SharePassword           = ''
        SmbTimeout              = 20
        KioskList               = ''
        KioskListSheet          = ''
        IncludeAllHosts         = $false
        PublishCsv              = ''
        Autoscan                = $true
        AutoscanMinutes         = 15
        StaleMinutes            = 45
        RefreshSeconds          = 5
        AgentStaleMinutes       = 10
        LauncherStaleMinutes    = 5
        ParallelHosts           = 8
        HostTimeoutSeconds      = 180
        PingTimeoutMs           = 1500
        RetentionDays           = 400
        RunRowRetentionDays     = 30
        ReconcileDays           = 30
        KeepaliveHours          = 24
        HeartbeatMinutes        = 60
        TrustedFromAgentVersion = '6.1'
        KeepPreUpgradeHistory   = $false
        IdleMinutes             = 30
        SessionHours            = 10
        SecureCookies           = 'auto'
        TrustProxy              = $true
        SiteName                = ''
        RestartMessage          = 'IT is restarting this kiosk remotely. Please do not switch it off - it will come back on its own.'
        RestartWarningSeconds   = 60
        SccmSiteServer          = ''
        BootstrapAdmin          = ''
        BootstrapPassword       = ''
        TemplatesDir            = Join-Path $script:ModuleRoot 'templates'
        WebDir                  = Join-Path $script:ModuleRoot 'web'
        Listen                  = 'http://127.0.0.1:8081/'
        JobThreads              = 8
        RequestThreads          = 16
        # A pretend fleet (KFW_DEMO): kiosks as folders in the data folder.
        Demo                    = $false
        # For the tests: skip the network reachability check.
        OfflineOk               = $false
    }
}

function Get-KfwSettings {
    [CmdletBinding()]
    param([string]$DataDir)

    $passed = [Environment]::GetEnvironmentVariable('KFW_SETTINGS_JSON')
    if ($passed) {
        # A child process (a scan) takes the server's settings as they are.
        $s = New-KfwSettings
        $data = ConvertFrom-Json $passed -AsHashtable
        foreach ($k in @($data.Keys)) { if ($s.Contains($k)) { $s[$k] = $data[$k] } }
        return $s
    }

    if (-not $DataDir) { $DataDir = [Environment]::GetEnvironmentVariable('KFW_DATA_DIR') }
    if (-not $DataDir) { $DataDir = Get-KfwDefaultDataDir }
    $file = Read-KfwEnvFile (Join-Path $DataDir 'kfw.env')

    $get = {
        param([string]$Name, [string]$Default = '')
        $path = [Environment]::GetEnvironmentVariable($Name + '_FILE')
        if (-not $path -and $file.ContainsKey($Name + '_FILE')) { $path = $file[$Name + '_FILE'] }
        if ($path) {
            try { return ([IO.File]::ReadAllText($path)).Trim() } catch { return $Default }
        }
        $v = [Environment]::GetEnvironmentVariable($Name)
        if ($null -ne $v) { return $v }
        if ($file.ContainsKey($Name)) { return $file[$Name] }
        return $Default
    }
    $bool = {
        param([string]$Name, [bool]$Default)
        $v = (& $get $Name '').Trim().ToLowerInvariant()
        if (-not $v) { return $Default }
        return $v -in '1', 'true', 'yes', 'on', 'y'
    }
    $int = {
        param([string]$Name, [int]$Default, [int]$Lo, [int]$Hi)
        $v = (& $get $Name '').Trim()
        if (-not $v) { return $Default }
        $n = 0
        if (-not [int]::TryParse($v, [ref]$n)) { throw "$Name has to be a whole number, not '$v'" }
        if ($n -lt $Lo -or $n -gt $Hi) { throw "$Name has to be $Lo to $Hi, not $n" }
        return $n
    }

    $s = New-KfwSettings
    $s.DataDir = $DataDir
    $share = & $get 'KFW_SHARE'
    if (-not $share) {
        $old = & $get 'KFW_ROOT_TEMPLATE'
        if ($old) {
            # It named the C: drive; the app starts at Public Documents.
            Write-Host 'KFW_ROOT_TEMPLATE is read as KFW_SHARE; rename it.'
            $sep = if ($old.StartsWith('\\')) { '\' } else { '/' }
            $share = $old.TrimEnd('\', '/') + $sep + (@('Users', 'Public', 'Documents') -join $sep)
        } else {
            $share = $script:DefaultShare
        }
    }
    $s.ShareTemplate = $share
    $s.ShareUser = & $get 'KFW_SHARE_USER'
    $s.SharePassword = & $get 'KFW_SHARE_PASSWORD'
    if (-not $s.SharePassword) {
        # The share account's password, kept by Save-KioskShareCredential.ps1.
        $cred = Read-KfwShareCredential (Join-Path $DataDir 'share.cred')
        if ($cred) {
            if (-not $s.ShareUser) { $s.ShareUser = $cred.User }
            if ($s.ShareUser -eq $cred.User) { $s.SharePassword = $cred.Password }
        }
    }
    $s.SmbTimeout = & $int 'KFW_SMB_TIMEOUT' 20 2 300
    $s.KioskList = & $get 'KFW_KIOSK_LIST'
    $s.KioskListSheet = & $get 'KFW_KIOSK_LIST_SHEET'
    $s.IncludeAllHosts = & $bool 'KFW_INCLUDE_ALL_HOSTS' $false
    $s.PublishCsv = & $get 'KFW_PUBLISH_CSV'
    $s.Autoscan = & $bool 'KFW_AUTOSCAN' $true
    $s.AutoscanMinutes = & $int 'KFW_AUTOSCAN_MINUTES' 15 1 1440
    $s.StaleMinutes = & $int 'KFW_STALE_MINUTES' 45 1 10080
    $s.RefreshSeconds = & $int 'KFW_REFRESH_SECONDS' 5 1 3600
    $s.AgentStaleMinutes = & $int 'KFW_AGENT_STALE_MINUTES' 10 1 1440
    $s.LauncherStaleMinutes = & $int 'KFW_LAUNCHER_STALE_MINUTES' 5 1 1440
    $s.ParallelHosts = & $int 'KFW_PARALLEL_HOSTS' 8 1 64
    $s.HostTimeoutSeconds = & $int 'KFW_HOST_TIMEOUT_SECONDS' 180 15 900
    $s.PingTimeoutMs = & $int 'KFW_PING_TIMEOUT_MS' 1500 100 10000
    $s.RetentionDays = & $int 'KFW_RETENTION_DAYS' 400 30 3650
    $s.RunRowRetentionDays = & $int 'KFW_RUN_ROW_RETENTION_DAYS' 30 1 3650
    $s.ReconcileDays = & $int 'KFW_RECONCILE_DAYS' 30 1 3650
    $s.KeepaliveHours = & $int 'KFW_KEEPALIVE_HOURS' 24 1 720
    $s.HeartbeatMinutes = & $int 'KFW_HEARTBEAT_MINUTES' 60 1 1440
    $s.TrustedFromAgentVersion = & $get 'KFW_TRUSTED_FROM_AGENT_VERSION' '6.1'
    $s.KeepPreUpgradeHistory = & $bool 'KFW_KEEP_PRE_UPGRADE_HISTORY' $false
    $s.IdleMinutes = & $int 'KFW_IDLE_MINUTES' 30 5 1440
    $s.SessionHours = & $int 'KFW_SESSION_HOURS' 10 1 168
    $s.SecureCookies = (& $get 'KFW_SECURE_COOKIES' 'auto').ToLowerInvariant()
    $s.TrustProxy = & $bool 'KFW_TRUST_PROXY' $true
    $site = (& $get 'KFW_SITE_NAME').Trim()
    $s.SiteName = if ($site.Length -gt 120) { $site.Substring(0, 120) } else { $site }
    $s.RestartMessage = & $get 'KFW_RESTART_MESSAGE' $s.RestartMessage
    $s.RestartWarningSeconds = & $int 'KFW_RESTART_WARNING_SECONDS' 60 0 3600
    $s.SccmSiteServer = & $get 'KFW_SCCM_SITE_SERVER'
    $s.BootstrapAdmin = & $get 'KFW_ADMIN_USER'
    $s.BootstrapPassword = & $get 'KFW_ADMIN_PASSWORD'
    $t = & $get 'KFW_TEMPLATES_DIR'
    if ($t) { $s.TemplatesDir = $t }
    $l = & $get 'KFW_LISTEN'
    if ($l) { $s.Listen = $l }
    $s.Demo = & $bool 'KFW_DEMO' $false
    $s.JobThreads = & $int 'KFW_JOB_THREADS' 8 1 64
    $s.RequestThreads = & $int 'KFW_REQUEST_THREADS' 16 2 128
    if ($s.SecureCookies -notin 'auto', 'true', 'false') { throw 'KFW_SECURE_COOKIES is auto, true or false' }
    return $s
}

function ConvertTo-KfwSettingsJson($Settings) {
    # The settings, for a child process (a scan) to pick up as they are.
    ConvertTo-Json $Settings -Compress -Depth 4
}

# --- what follows from them ----------------------------------------------------
function Get-KfwLogDir($S) { Join-Path $S.DataDir 'logs' }
function Get-KfwRunDir($S) { Join-Path (Get-KfwLogDir $S) 'run' }
function Get-KfwSnapshotDir($S) { Join-Path (Get-KfwLogDir $S) 'snapshots' }
function Get-KfwLocalCsv($S) { Join-Path $S.DataDir 'MWST_FleetEvents.csv' }

function Get-KfwEventsCsv($S) {
    # The CSV the dashboard reads: the published one if there is one.
    if ($S.PublishCsv) { return $S.PublishCsv }
    return Get-KfwLocalCsv $S
}

function Test-KfwUsesUnc($S) { ([string]$S.ShareTemplate).StartsWith('\\') }
function Test-KfwHasCredential($S) { [bool]($S.ShareUser -and $S.SharePassword) }

function Get-KfwShareProblem($S) {
    # Why the server cannot open the kiosks' shares at all, or ''.
    if ((Test-KfwUsesUnc $S) -and -not $IsWindows) {
        return 'a \\server\share path is opened by Windows; on Linux, mount the shares and set KFW_SHARE to the mounted folder ({0} is the kiosk)'
    }
    return ''
}

function Resolve-KfwKioskList($S) {
    if ($S.KioskList) { return $S.KioskList }
    foreach ($name in 'kiosk-list.xlsx', 'kiosk-list.csv', 'kiosk-list.txt') {
        $p = Join-Path $S.DataDir $name
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    return $null
}

function Initialize-KfwDirs($S) {
    foreach ($d in $S.DataDir, (Get-KfwLogDir $S), (Get-KfwRunDir $S), (Get-KfwSnapshotDir $S)) {
        [void][IO.Directory]::CreateDirectory($d)
    }
}

# --- the share account's password, kept on the server ---------------------------
function Protect-KfwText([string]$Text) {
    # DPAPI, machine scope: readable on this server only. The file's ACL
    # (the installer's) keeps other accounts on it out.
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine))
}

function Unprotect-KfwText([string]$Base64) {
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Base64), $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    [Text.Encoding]::UTF8.GetString($bytes)
}

function Read-KfwShareCredential([string]$Path) {
    if (-not $IsWindows -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $j = ConvertFrom-Json ([IO.File]::ReadAllText($Path)) -AsHashtable
        return @{ User = [string]$j.User; Password = Unprotect-KfwText ([string]$j.Password) }
    } catch {
        Write-Warning "Could not read the share account from ${Path}: $($_.Exception.Message)"
        return $null
    }
}
