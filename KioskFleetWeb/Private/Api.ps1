# The API behind the page, and the page itself when no Caddy is in front.
#
# Everyone signs in with an account of this app (no Windows / AD sign-in).
# A session is an HttpOnly, SameSite=Strict cookie, Secure over HTTPS; every
# change also needs the session's CSRF token in X-Fleet-Csrf and, from a
# browser, the page's own origin. Roles are checked here on every request, so
# a hand-made request gets 403 and an audit entry, not an action.

$script:Cookie = 'kfw_session'

$script:KioskActions = @{
    'live'         = @{ perm = 'live'; label = 'reading'; launcher = $true; job = 'live' }
    'snapshot'     = @{ perm = 'snapshot'; label = 'taking a screenshot'; launcher = $true; job = 'snapshot' }
    'reload'       = @{ perm = 'reload'; label = 'reloading the page'; launcher = $true; job = 'control'; file = 'refresh.txt' }
    'relaunch'     = @{ perm = 'relaunch'; label = 'restarting the browser'; launcher = $true; job = 'control'; file = 'relaunch.txt' }
    'hold'         = @{ perm = 'hold'; label = 'holding'; launcher = $true; job = 'control'; file = 'hold.txt' }
    'resume'       = @{ perm = 'resume'; label = 'carrying on'; launcher = $true; job = 'control'; file = 'hold.txt'; remove = $true }
    'stop'         = @{ perm = 'stop'; label = 'stopping the launcher'; launcher = $true; job = 'control'; file = 'kill.txt' }
    'log'          = @{ perm = 'log'; label = 'reading the log'; launcher = $true; job = 'log' }
    'password'     = @{ perm = 'password'; label = 'setting the password'; launcher = $true; job = 'password' }
    'restart'      = @{ perm = 'restart'; label = 'restarting'; job = 'restart' }
    'message'      = @{ perm = 'message'; label = 'sending a message'; job = 'message' }
    'config-read'  = @{ perm = 'config'; label = 'reading the config'; any_host = $true; job = 'config-read' }
    'config-write' = @{ perm = 'config'; label = 'writing the config'; any_host = $true; job = 'config-write' }
    'test'         = @{ perm = 'settings'; label = 'testing the connection'; any_host = $true; job = 'test' }
}

# What can be done to many kiosks at once: nothing that cannot be undone.
$script:GroupActions = @('live', 'snapshot', 'reload', 'relaunch', 'message')
$script:MaxGroup = 500

$script:StaticFiles = @{
    'app.js'   = 'text/javascript; charset=utf-8'
    'app.css'  = 'text/css; charset=utf-8'
    'logo.svg' = 'image/svg+xml'
}

# --- small helpers --------------------------------------------------------------------
function Get-KfwText($Body, [string]$Name, [int]$MaxLength = 400) {
    $v = $Body[$Name]
    if ($null -eq $v) { return '' }
    $v = if ($v -is [bool]) { if ($v) { 'True' } else { 'False' } } else { [string]$v }
    if ($v.Length -gt $MaxLength) { Stop-KfwRequest 400 "$Name is too long" }
    return $v
}

function Get-KfwFlag($Body, [string]$Name) {
    $v = $Body[$Name]
    return ($v -is [bool]) -and $v
}

function Get-KfwInteger($Body, [string]$Name, [int]$Default, [int]$Lo, [int]$Hi, [string]$Say) {
    $v = $Body[$Name]
    if ($null -eq $v -or ([string]$v).Trim() -eq '' -or $v -is [bool]) {
        if ($v -is [bool]) { Stop-KfwRequest 400 $Say }
        return $Default
    }
    $n = 0
    if (-not [int]::TryParse(([string]$v).Trim(), [Globalization.NumberStyles]::AllowLeadingSign, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { Stop-KfwRequest 400 $Say }
    if ($n -lt $Lo -or $n -gt $Hi) { Stop-KfwRequest 400 $Say }
    return $n
}

function Get-KfwCleanHost([string]$Text) {
    # A typed name ("  \\PC-01 " -> "PC-01"), or $null for anything that is not one.
    if (-not $Text) { return $null }
    $name = $Text.Trim().Trim('\')
    if ($name -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$') { return $name }
    return $null
}

function Get-KfwSessionFor($Req) {
    Get-KfwSession $script:St ([string]$Req.Cookies[$script:Cookie]) $script:S.IdleMinutes $script:S.SessionHours
}

function Assert-KfwSession($Req) {
    $s = Get-KfwSessionFor $Req
    if (-not $s) { Stop-KfwRequest 401 'Sign in first.' }
    if ($Req.Method -notin 'GET', 'HEAD') {
        if (-not (Test-KfwSameOrigin $Req)) { Stop-KfwRequest 403 'wrong origin' }
        $sent = [string]$Req.Headers['X-Fleet-Csrf']
        if (-not $sent -or -not (Test-KfwFixedTimeEquals $sent $s.csrf)) { Stop-KfwRequest 403 'The page is out of date - reload it.' }
    }
    return $s
}

function Assert-KfwAllowed($Req, $Session, [string]$Perm, [string]$Action = '', [string]$Target = '') {
    if (-not (Test-KfwAllowed $Session.role $Perm)) {
        Write-KfwAudit $script:St -User $Session.user -Role $Session.role -Ip (Get-KfwClientIp $Req) -Action ($(if ($Action) { $Action } else { $Perm })) -Target $Target -Result 'refused' -Detail 'not allowed for this role'
        Stop-KfwRequest 403 'Your role cannot do that.'
    }
}

function Get-KfwMe($Session, $Req) {
    $allowed = [string[]]::new(0)
    if ($Session) { $allowed = Get-KfwAllowedActions $Session.role }
    [ordered]@{
        user = if ($Session) { $Session.user } else { $null }
        role = if ($Session) { $Session.role } else { $null }
        csrf = if ($Session) { $Session.csrf } else { $null }
        allowed = $allowed
        mustChange = [bool]($Session -and $Session.must_change)
        methods = [ordered]@{ windows = $false; local = $true }
        setup = $null -ne $script:App.SetupToken
        insecure = -not (Test-KfwHttps $Req) -and -not (Test-KfwLocalClient $Req)
        version = $script:Version
        idleMinutes = $script:S.IdleMinutes
        site = $script:S.SiteName
    }
}

function Add-KfwSessionCookie($Resp, $Req, [string]$Token) {
    $secure = switch ($script:S.SecureCookies) { 'true' { $true } 'false' { $false } default { Test-KfwHttps $Req } }
    $c = "$($script:Cookie)=$Token; HttpOnly; Path=/; SameSite=Strict"
    if ($secure) { $c += '; Secure' }
    $Resp.Cookies.Add($c)
}

function ConvertTo-KfwCsvField([string]$Value, [switch]$Always) {
    if ($Always -or $Value.IndexOfAny([char[]]@(',', '"', "`r", "`n")) -ge 0) { return '"' + $Value.Replace('"', '""') + '"' }
    return $Value
}

function Get-KfwFileResponse([string]$Path, [string]$ContentType, [hashtable]$Headers = @{}) {
    New-KfwResponse -Status 200 -ContentType $ContentType -Body ([IO.File]::ReadAllBytes($Path)) -Headers $Headers
}

function Get-KfwContentType([string]$Name) {
    switch ([IO.Path]::GetExtension($Name).ToLowerInvariant()) {
        '.csv' { 'text/csv; charset=utf-8' }
        '.txt' { 'text/plain; charset=utf-8' }
        '.xlsx' { 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }
        default { 'application/octet-stream' }
    }
}

function Get-KfwAttachment([string]$Name) {
    $safe = $Name -replace '[^A-Za-z0-9._ -]', '_'
    @{ 'Content-Disposition' = "attachment; filename=`"$safe`"" }
}

# --- routing ----------------------------------------------------------------------------
function Invoke-KfwRoute($Req) {
    $seg = $Req.Segments
    $m = $Req.Method
    if ($seg.Count -eq 0 -or ($seg.Count -eq 1 -and $seg[0] -in 'index.html', 'setup')) {
        if ($m -notin 'GET', 'HEAD') { Stop-KfwRequest 405 'Method Not Allowed' }
        return Get-KfwFileResponse (Join-Path $script:S.WebDir 'index.html') 'text/html; charset=utf-8' @{ 'Cache-Control' = 'no-cache' }
    }
    if ($seg.Count -eq 1 -and $script:StaticFiles.ContainsKey($seg[0]) -and $m -in 'GET', 'HEAD') {
        return Get-KfwFileResponse (Join-Path $script:S.WebDir $seg[0]) $script:StaticFiles[$seg[0]] @{ 'Cache-Control' = 'no-cache' }
    }
    if ($seg.Count -eq 1 -and $seg[0] -eq 'favicon.ico') { return New-KfwResponse -Status 204 }
    if ($seg.Count -eq 1 -and $seg[0] -eq 'healthz') {
        $st = $script:App.Cache.State
        return New-KfwJsonResponse ([ordered]@{ ok = $true; version = $script:Version; fleet = [bool]($st -and $st.Ok) })
    }
    if ($seg[0] -ne 'api') { Stop-KfwRequest 404 'Not Found' }

    $a = if ($seg.Count -gt 1) { $seg[1] } else { '' }
    $route = "$m /$((@($seg) | Select-Object -Skip 1) -join '/')"
    switch -Regex ($route) {
        '^POST /login$' { return Invoke-KfwLogin $Req }
        '^POST /setup$' { return Invoke-KfwSetup $Req }
        '^GET /me$' {
            $s = Get-KfwSessionFor $Req
            return New-KfwJsonResponse (Get-KfwMe $s $Req) ($(if ($s) { 200 } else { 401 }))
        }
        '^POST /logout$' { return Invoke-KfwLogout $Req }
        '^POST /me/password$' { return Invoke-KfwOwnPassword $Req }
        '^GET /state$' { return Get-KfwStateResponse $Req }
        '^POST /kiosks/[^/]+/[^/]+$' { return Invoke-KfwKioskAction $Req $seg[2] $seg[3] }
        '^GET /kiosks/[^/]+/history$' { return Get-KfwHistoryResponse $Req $seg[2] }
        '^POST /group/[^/]+$' { return Invoke-KfwGroupAction $Req $seg[2] }
        '^GET /jobs/[^/]+$' { return Get-KfwJobResponse $Req $seg[2] }
        '^GET /screens$' {
            [void](Assert-KfwSession $Req)
            return New-KfwJsonResponse ([ordered]@{ screens = (Get-KfwLatestScreens (Get-KfwSnapshotDir $script:S)) })
        }
        '^GET /snapshots/[^/]+$' {
            [void](Assert-KfwSession $Req)
            $p = Get-KfwSnapshotPath $script:S $seg[2]
            if (-not $p) { Stop-KfwRequest 404 'no such picture' }
            # Each picture has a name of its own and never changes: the Screens
            # page can redraw without fetching every one again.
            return Get-KfwFileResponse $p 'image/png' @{ 'Cache-Control' = 'private, max-age=86400, immutable' }
        }
        '^GET /run$' {
            [void](Assert-KfwSession $Req)
            $from = 0L
            [void][long]::TryParse([string]$Req.Query['from'], [ref]$from)
            return New-KfwJsonResponse (Read-KfwRunLog $script:App $from)
        }
        '^POST /scan$' {
            $s = Assert-KfwSession $Req
            Assert-KfwAllowed $Req $s 'scan'
            $why = Start-KfwScan $script:App -Session $s
            Write-KfwAudit $script:St -User $s.user -Role $s.role -Ip (Get-KfwClientIp $Req) -Action 'scan' -Result ($(if ($why) { 'refused' } else { 'started' })) -Detail ([string]$why)
            if ($why) { Stop-KfwRequest 409 $why }
            return New-KfwJsonResponse @{ ok = $true } 202
        }
        '^POST /autoscan$' {
            $s = Assert-KfwSession $Req
            Assert-KfwAllowed $Req $s 'autoscan'
            $on = Get-KfwFlag (Read-KfwJsonBody $Req) 'on'
            $why = if ($on) { Enable-KfwAutoscan $script:App } else { $null }
            if (-not $on) { $script:App.Runner.AutoscanOn = $false }
            Write-KfwAudit $script:St -User $s.user -Role $s.role -Ip (Get-KfwClientIp $Req) -Action 'autoscan' -Target ($(if ($on) { 'on' } else { 'off' })) -Result ($(if ($why) { 'refused' } else { 'ok' })) -Detail ([string]$why)
            if ($why) { Stop-KfwRequest 409 $why }
            return New-KfwJsonResponse @{ on = [bool]$script:App.Runner.AutoscanOn }
        }
        '^POST /run/stop$' {
            $s = Assert-KfwSession $Req
            Assert-KfwAllowed $Req $s 'stoprun'
            $title = if ($script:App.Runner.Run) { $script:App.Runner.Run.Title } else { '' }
            $why = Stop-KfwRun $script:App $s
            if ($why) { Stop-KfwRequest 409 $why }
            Write-KfwAudit $script:St -User $s.user -Role $s.role -Ip (Get-KfwClientIp $Req) -Action 'stop-run' -Target $title -Result 'ok'
            return New-KfwJsonResponse @{ ok = $true }
        }
        '^GET /reports$' {
            [void](Assert-KfwSession $Req)
            $rows = foreach ($f in (Get-KfwReports $script:App)) {
                [ordered]@{ name = $f.Name; when = $f.LastWriteTime.ToString('ddd dd MMM HH:mm', [Globalization.CultureInfo]::InvariantCulture)
                    kind = if ($f.Name.StartsWith('scan-')) { 'Scan output' } else { 'Output' }; size = $f.Length }
            }
            return New-KfwJsonResponse ([ordered]@{ reports = @($rows) })
        }
        '^GET /reports/[^/]+$' {
            [void](Assert-KfwSession $Req)
            $f = (Get-KfwReports $script:App) | Where-Object { $_.Name -ceq $seg[2] } | Select-Object -First 1
            if (-not $f) { Stop-KfwRequest 404 'no such report' }
            return Get-KfwFileResponse $f.FullName (Get-KfwContentType $f.Name) (Get-KfwAttachment $f.Name)
        }
        '^GET /audit$' {
            $s = Assert-KfwSession $Req
            Assert-KfwAllowed $Req $s 'audit'
            $q = [string]$Req.Query['q']
            if ($q.Length -gt 100) { $q = $q.Substring(0, 100) }
            return New-KfwJsonResponse ([ordered]@{ entries = (Get-KfwAuditEntries $script:St 400 $q) })
        }
        '^GET /audit\.csv$' { return Get-KfwAuditCsv $Req }
        '^GET /users$' { return Get-KfwUsersResponse $Req }
        '^POST /users$' { return Add-KfwUserFromPage $Req }
        '^POST /users/[^/]+$' { return Set-KfwUserFromPage $Req $seg[2] }
        '^DELETE /users/[^/]+$' { return Remove-KfwUserFromPage $Req $seg[2] }
        '^GET /settings$' { return Get-KfwSettingsResponse $Req }
        '^POST /settings/kiosk-list$' { return Invoke-KfwListUpload $Req }
        '^GET /settings/kiosk-list$' {
            $s = Assert-KfwSession $Req
            Assert-KfwAllowed $Req $s 'settings'
            $p = Resolve-KfwKioskList $script:S
            if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Leaf)) { Stop-KfwRequest 404 'no kiosk list' }
            $name = [IO.Path]::GetFileName($p)
            return Get-KfwFileResponse $p (Get-KfwContentType $name) (Get-KfwAttachment $name)
        }
        '^GET /kiosklist$' {
            $s = Assert-KfwSession $Req
            Assert-KfwAllowed $Req $s 'kiosklist'
            try {
                return New-KfwJsonResponse (Get-KfwListView $script:S)
            } catch {
                # An unreadable list is shown, not a 500.
                return New-KfwJsonResponse ([ordered]@{ path = [string](Resolve-KfwKioskList $script:S); fixed = [bool]$script:S.KioskList; editable = $false
                        error = $_.Exception.Message; rows = @(); scanned = 0; total = 0 })
            }
        }
        '^POST /kiosklist$' { return Invoke-KfwListSave $Req }
        '^POST /kiosklist/active$' { return Invoke-KfwListActive $Req }
        '^POST /kiosklist/remove$' { return Invoke-KfwListRemove $Req }
    }
    Stop-KfwRequest 404 'not here'
}

# --- signing in and out --------------------------------------------------------------------
function Invoke-KfwLogin($Req) {
    if (-not (Test-KfwSameOrigin $Req)) { Stop-KfwRequest 403 'wrong origin' }
    $b = Read-KfwJsonBody $Req
    $name = (Get-KfwText $b 'user' 64).Trim()
    $password = Get-KfwText $b 'password' 256
    $ip = Get-KfwClientIp $Req
    $ukey = 'u:' + $name.ToLowerInvariant(); $ikey = 'ip:' + $ip
    if ((Test-KfwLocked $script:St $ukey) -or (Test-KfwLocked $script:St $ikey)) {
        Write-KfwAudit $script:St -User $name -Ip $ip -Action 'sign-in' -Result 'refused' -Detail 'locked out for now'
        Stop-KfwRequest 429 'Too many wrong passwords. Try again in 15 minutes.'
    }
    $u = if ($name -and $password) { Test-KfwLogin $script:St $name $password } else { $null }
    if (-not $u) {
        Add-KfwLoginFailure $script:St $ukey 5
        Add-KfwLoginFailure $script:St $ikey 20
        Write-KfwAudit $script:St -User $name -Ip $ip -Action 'sign-in' -Result 'failed'
        Stop-KfwRequest 401 'That name and password do not match.'
    }
    Clear-KfwLoginFailures $script:St $ukey
    $token = New-KfwSession $script:St $u.name $ip ([string]$Req.Headers['User-Agent'])
    $s = Get-KfwSession $script:St $token $script:S.IdleMinutes $script:S.SessionHours
    Write-KfwAudit $script:St -User $u.name -Role $u.role -Ip $ip -Action 'sign-in' -Result 'ok'
    $resp = New-KfwJsonResponse (Get-KfwMe $s $Req)
    Add-KfwSessionCookie $resp $Req $token
    return $resp
}

function Invoke-KfwSetup($Req) {
    # The first admin account, with the one-time link from the server's log.
    if (-not (Test-KfwSameOrigin $Req)) { Stop-KfwRequest 403 'wrong origin' }
    $b = Read-KfwJsonBody $Req
    $token = $script:App.SetupToken
    if ($null -eq $token -or (Get-KfwUserCount $script:St) -gt 0) { Stop-KfwRequest 409 'Setup is done already. Sign in.' }
    if (-not (Test-KfwFixedTimeEquals (Get-KfwText $b 'token' 100) $token)) {
        Write-KfwAudit $script:St -Ip (Get-KfwClientIp $Req) -Action 'setup' -Result 'refused' -Detail 'wrong setup token'
        Stop-KfwRequest 403 "That setup link is not right. Use the one in the server's log."
    }
    $name = (Get-KfwText $b 'user' 64).Trim()
    $p1 = Get-KfwText $b 'password' 256; $p2 = Get-KfwText $b 'password2' 256
    if (-not (Test-KfwUserName $name)) { Stop-KfwRequest 400 'An account name is 2 to 64 letters, digits, dots, dashes, underscores or @.' }
    if ($p1 -cne $p2) { Stop-KfwRequest 400 'The two passwords did not match.' }
    $problem = Get-KfwPasswordProblem $p1 $name
    if ($problem) { Stop-KfwRequest 400 "The password needs $problem." }
    Add-KfwUser $script:St $name 'admin' $p1
    Clear-KfwSetupToken $script:App
    $ip = Get-KfwClientIp $Req
    Write-KfwAudit $script:St -User $name -Role 'admin' -Ip $ip -Action 'setup' -Target $name -Result 'ok' -Detail 'first admin account'
    $t = New-KfwSession $script:St $name $ip ([string]$Req.Headers['User-Agent'])
    $resp = New-KfwJsonResponse (Get-KfwMe (Get-KfwSession $script:St $t $script:S.IdleMinutes $script:S.SessionHours) $Req)
    Add-KfwSessionCookie $resp $Req $t
    return $resp
}

function Invoke-KfwLogout($Req) {
    $s = Get-KfwSessionFor $Req
    if ($s -and (Test-KfwFixedTimeEquals ([string]$Req.Headers['X-Fleet-Csrf']) $s.csrf)) {
        Stop-KfwSession $script:St $s.token_hash
        Write-KfwAudit $script:St -User $s.user -Role $s.role -Ip (Get-KfwClientIp $Req) -Action 'sign-out' -Result 'ok'
    }
    $resp = New-KfwJsonResponse @{ ok = $true }
    $resp.Cookies.Add("$($script:Cookie)=`"`"; expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=0; Path=/; SameSite=Strict")
    return $resp
}

function Invoke-KfwOwnPassword($Req) {
    $s = Assert-KfwSession $Req
    $b = Read-KfwJsonBody $Req
    $current = Get-KfwText $b 'current' 256; $p1 = Get-KfwText $b 'password' 256; $p2 = Get-KfwText $b 'password2' 256
    $ip = Get-KfwClientIp $Req
    if (-not (Test-KfwLogin $script:St $s.user $current)) {
        Write-KfwAudit $script:St -User $s.user -Role $s.role -Ip $ip -Action 'password-change' -Target $s.user -Result 'failed' -Detail 'current password wrong'
        Stop-KfwRequest 400 'The current password is not right.'
    }
    if ($p1 -cne $p2) { Stop-KfwRequest 400 'The two new passwords did not match.' }
    $problem = Get-KfwPasswordProblem $p1 $s.user
    if ($problem) { Stop-KfwRequest 400 "The new password needs $problem." }
    Set-KfwUserPassword $script:St $s.user $p1
    Stop-KfwSessionsOf $script:St $s.user $s.token_hash
    Write-KfwAudit $script:St -User $s.user -Role $s.role -Ip $ip -Action 'password-change' -Target $s.user -Result 'ok'
    return New-KfwJsonResponse @{ ok = $true }
}

# --- the fleet --------------------------------------------------------------------------------
function Copy-KfwTable($Table) {
    $out = @{}
    foreach ($k in @($Table.Keys)) { $out[$k] = $Table[$k] }
    return $out
}

function Get-KfwStateResponse($Req) {
    $s = Assert-KfwSession $Req
    if ($s.must_change) { Stop-KfwRequest 428 'Change your password first.' }
    $App = $script:App; $c = $App.Cache
    $fresh = Get-KfwFreshness $c.State $script:S.StaleMinutes
    $written = [Collections.Generic.List[string]]::new()
    foreach ($k in @($App.ConfigWritten.Keys)) { $written.Add($k) }
    $written.Sort([StringComparer]::Ordinal)
    $note = Get-KfwCredentialNote $App
    $dyn = [ordered]@{
        stamp = $c.Stamp
        fresh = [ordered]@{ text = $fresh.text; stale = $fresh.stale; lastRun = $fresh.lastRun }
        busy = Copy-KfwTable $App.Busy; live = Copy-KfwTable $App.Live; hold = Copy-KfwTable $App.Hold; snapshots = Copy-KfwTable $App.Snapshots
        configWritten = @($written); run = Get-KfwRunStatus $App; lastRun = $App.Runner.Last
        autoscan = [ordered]@{ on = [bool]$App.Runner.AutoscanOn; minutes = $script:S.AutoscanMinutes; nextIn = Get-KfwNextScanMinutes $App }
        credential = [ordered]@{ ok = -not $note; note = $note }
        kioskList = [bool](Resolve-KfwKioskList $script:S)
        clock = [datetime]::Now.ToString('ddd dd MMM  HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
        restart = [ordered]@{ message = $script:S.RestartMessage; seconds = $script:S.RestartWarningSeconds }
        remoteControl = ([string]$script:S.SccmSiteServer).Trim().Trim('\')
        shareTemplate = $script:S.ShareTemplate; csv = Get-KfwEventsCsv $script:S
    }
    $since = [string]$Req.Query['since']
    $fleet = if ($since -and $since -eq $c.Stamp -and $c.State) { 'null' } else { $c.ViewJson }
    return New-KfwRawJsonResponse ('{"fleet":' + $fleet + ',"live":' + (ConvertTo-KfwJson $dyn) + '}')
}

function Resolve-KfwTarget($Kiosk, [string]$Screen, [string]$Kind) {
    if ($Screen) {
        if ($Screen -cnotmatch '^S\d{1,2}$' -or $Kind -cnotin 'NG', 'PBI', 'WEB') { Stop-KfwRequest 400 'pick a screen like S1 and its launcher' }
        $found = $false
        foreach ($sc in @($Kiosk.Screens)) { if ($sc.Screen -ceq $Screen -and $script:KindOfScreenLauncher[$sc.Launcher] -ceq $Kind) { $found = $true } }
        if (-not $found) { Stop-KfwRequest 400 "$($Kiosk.Host) has no $Kind screen $Screen" }
        return @($Screen, $Kind)
    }
    if (@($Kiosk.Screens).Count -or $Kiosk.Ng -or $Kiosk.Pbi -or $Kiosk.Web) { return @('', 'ALL') }
    $k = if ($script:TabKinds.Contains([string]$Kiosk.Tab)) { $script:TabKinds[[string]$Kiosk.Tab] } else { '' }
    return @('', $k)
}

function Invoke-KfwKioskAction($Req, [string]$HostName, [string]$Action) {
    $s = Assert-KfwSession $Req
    $spec = $script:KioskActions[$Action]
    if (-not $spec -or -not $script:KioskActions.ContainsKey($Action)) { Stop-KfwRequest 404 'no such action' }
    Assert-KfwAllowed $Req $s $spec.perm $Action $HostName
    $name = Get-KfwCleanHost $HostName
    if (-not $name) { Stop-KfwRequest 400 'that is not a kiosk name' }
    $k = Get-KfwCachedKiosk $script:App $name
    if ($k) { $name = $k.Host }
    elseif (-not $spec.any_host) { Stop-KfwRequest 404 "$name is not in the last scan" }
    if ($script:App.Busy.ContainsKey($name)) { Stop-KfwRequest 409 "$name is busy: $($script:App.Busy[$name])" }
    $problem = Get-KfwShareProblem $script:S
    if ($problem -and $Action -ne 'test') { Stop-KfwRequest 503 "The server cannot reach kiosks: $problem" }

    $b = Read-KfwJsonBody $Req
    $ctx = New-KfwActionContext $name "$($s.user) ($($s.role))"
    $detail = ''
    if ($spec.launcher) {
        $t = Resolve-KfwTarget $k (Get-KfwText $b 'screen' 4) (Get-KfwText $b 'kind' 4)
        if (-not $t[1]) { Stop-KfwRequest 400 "$name has no launcher" }
        $ctx.Screen = $t[0]; $ctx.Kind = $t[1]
        $detail = if ($t[0]) { "$($t[0]) $($t[1])" } else { 'all screens' }
    }
    if ($spec.file) { $ctx.Params.file = $spec.file; $ctx.Params['remove'] = [bool]$spec['remove'] }
    switch ($Action) {
        'log' { $ctx.Params.lines = 60 }
        'password' {
            if ($ctx.Kind -eq 'WEB') { Stop-KfwRequest 400 'a web page screen signs in to nothing' }
            $p1 = Get-KfwText $b 'password' 256; $p2 = Get-KfwText $b 'password2' 256
            if (-not $p1) { Stop-KfwRequest 400 'Type the password first.' }
            if ($p1 -cne $p2) { Stop-KfwRequest 400 'The two did not match. Nothing was changed.' }
            $ctx.Secret = $p1
        }
        'restart' {
            $secs = Get-KfwInteger $b 'seconds' $script:S.RestartWarningSeconds 0 3600 'The countdown has to be a whole number of seconds, 0 to 3600.'
            $ctx.Params.seconds = $secs; $ctx.Params.message = (Get-KfwText $b 'message' 500).Trim()
            $detail = "countdown ${secs}s"
        }
        'message' {
            if (-not ($k.Ng -or $k.Tab -eq 'Mach2')) { Stop-KfwRequest 400 'Only Mach2 kiosks have a watchdog to show a message.' }
            $msg = (Get-KfwText $b 'text' 1000).Trim()
            if (-not $msg) { Stop-KfwRequest 400 'Type the message first.' }
            $ctx.Params.text = $msg
            $ctx.Params.seconds = Get-KfwInteger $b 'seconds' 60 5 900 'Between 5 and 900 seconds.'
            $detail = $msg
        }
        { $_ -in 'config-read', 'config-write' } {
            $kind = Get-KfwText $b 'kind' 4
            if ($kind -cnotin 'NG', 'PBI', 'WEB') { Stop-KfwRequest 400 'which launcher: NG, PBI or WEB' }
            $instance = (Get-KfwText $b 'instance' 4).Trim().ToUpperInvariant()
            if ($Action -eq 'config-write' -and $instance -cnotmatch '^S\d{1,2}$') { Stop-KfwRequest 400 'A screen folder is named like S1 or S2.' }
            if ($instance -and $instance -cnotmatch '^S\d{1,2}$') { Stop-KfwRequest 400 'A screen folder is named like S1 or S2.' }
            $ctx.Kind = $kind
            $ctx.Params.instance = $instance
            $detail = "$instance $kind"
            if ($Action -eq 'config-write') {
                $values = [ordered]@{}
                $given = $b['values']
                if ($given -is [Collections.IDictionary]) {
                    foreach ($key in @($given.Keys)) {
                        if ([string]$key -cnotmatch '^[A-Za-z][A-Za-z0-9_]{0,63}$') { Stop-KfwRequest 400 "'$key' is not a setting" }
                        $v = if ($null -eq $given[$key]) { '' } elseif ($given[$key] -is [bool]) { if ($given[$key]) { 'True' } else { 'False' } } else { [string]$given[$key] }
                        if ($v.Length -gt 4000) { Stop-KfwRequest 400 "$key is too long" }
                        $values[[string]$key] = $v.Trim()
                    }
                }
                $missing = @($script:ConfigRequired[$kind] | Where-Object { $values.Contains($_) -and -not $values[$_] })
                if ($missing.Count) { Stop-KfwRequest 400 ('Still empty: ' + ($missing -join ', ') + '.') }
                $p1 = Get-KfwText $b 'password' 256; $p2 = Get-KfwText $b 'password2' 256
                if ($p1 -cne $p2) { Stop-KfwRequest 400 'The two passwords did not match. Nothing was saved.' }
                if ($p1 -and $kind -ne 'WEB') { $ctx.Secret = $p1 }
                $ctx.Params['values'] = $values
                $keys = [Collections.Generic.List[string]]::new([string[]]@($values.Keys))
                $keys.Sort([StringComparer]::Ordinal)
                $detail = "$instance $kind; " + (($keys | ForEach-Object { "$_=$($values[$_])" }) -join ', ') + $(if ($ctx.Secret) { '; new sign-in password' } else { '' })
            }
        }
    }

    [Threading.Monitor]::Enter($script:App.JobsLock)
    try {
        if ($script:App.Busy.ContainsKey($name)) { Stop-KfwRequest 409 "$name is busy: $($script:App.Busy[$name])" }
        $job = Start-KfwJob $script:App $spec.job $spec.label $name $ctx $s (Get-KfwClientIp $Req) $Action
    } finally { [Threading.Monitor]::Exit($script:App.JobsLock) }
    Write-KfwAudit $script:St -User $s.user -Role $s.role -Ip (Get-KfwClientIp $Req) -Action $Action -Target $name -Result 'started' -Detail $detail
    return New-KfwJsonResponse ([ordered]@{ job = $job.id; label = $spec.label }) 202
}

function Get-KfwHistoryResponse($Req, [string]$HostName) {
    $s = Assert-KfwSession $Req
    Assert-KfwAllowed $Req $s 'view'
    $name = Get-KfwCleanHost $HostName
    if (-not $name) { Stop-KfwRequest 400 'that is not a kiosk name' }
    $days = 28
    $q = [string]$Req.Query['days']
    if ($q -and -not [int]::TryParse($q, [ref]$days)) { Stop-KfwRequest 400 '1 to 366 days' }
    if ($days -lt 1 -or $days -gt 366) { Stop-KfwRequest 400 '1 to 366 days' }
    $k = Get-KfwCachedKiosk $script:App $name
    $path = Get-KfwEventsCsv $script:S
    $rows = Get-KfwEventRows $script:App $path
    $h = Get-KfwKioskHistory $rows ($(if ($k) { $k.Host } else { $name })) $days $script:S.KeepaliveHours
    if (-not $h.Found -and -not $k) { Stop-KfwRequest 404 "$name has nothing in the events file" }
    $h.Status = if ($k) { $k.Status } else { '' }
    $h.Tab = if ($k) { $k.Tab } else { '' }
    return New-KfwJsonResponse $h
}

function Invoke-KfwGroupAction($Req, [string]$Action) {
    # One action on many kiosks: a job each, as if they were clicked one by
    # one. Kiosks it cannot apply to, or that are busy, are skipped and named,
    # not refused as a whole.
    $s = Assert-KfwSession $Req
    if ($Action -cnotin $script:GroupActions) { Stop-KfwRequest 404 'no such group action' }
    $spec = $script:KioskActions[$Action]
    Assert-KfwAllowed $Req $s $spec.perm "group-$Action"
    $problem = Get-KfwShareProblem $script:S
    if ($problem) { Stop-KfwRequest 503 "The server cannot reach kiosks: $problem" }
    $b = Read-KfwJsonBody $Req
    $hosts = $b['hosts']
    if ($hosts -isnot [Collections.IList] -or $hosts.Count -eq 0) { Stop-KfwRequest 400 'Pick the kiosks first.' }
    if ($hosts.Count -gt $script:MaxGroup) { Stop-KfwRequest 400 "$($script:MaxGroup) kiosks at most at once." }
    $msg = ''; $secs = 0
    if ($Action -eq 'message') {
        $msg = (Get-KfwText $b 'text' 1000).Trim()
        if (-not $msg) { Stop-KfwRequest 400 'Type the message first.' }
        $secs = Get-KfwInteger $b 'seconds' 60 5 900 'Between 5 and 900 seconds.'
    }
    $ip = Get-KfwClientIp $Req; $who = "$($s.user) ($($s.role))"
    $dayKeys = @()
    if ($script:App.Cache.State) { $dayKeys = @($script:App.Cache.State.DayKeys) }
    $started = [Collections.Generic.List[object]]::new()
    $skipped = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($raw in $hosts) {
        $name = Get-KfwCleanHost ([string]$raw)
        if (-not $name -or -not $seen.Add($name)) { continue }
        $k = Get-KfwCachedKiosk $script:App $name
        if (-not $k) { $skipped.Add([ordered]@{ host = $name; why = 'not in the last scan' }); continue }
        $name = $k.Host
        $v = Get-KfwKioskView $k $dayKeys
        if ($Action -eq 'message' -and -not $v.MessageOk) {
            $skipped.Add([ordered]@{ host = $name; why = $(if ($v.MessageWhy) { $v.MessageWhy } else { 'no watchdog to show it' }) }); continue
        }
        $screen = ''; $kind = ''
        if ($spec.launcher) {
            if ($Action -ne 'live' -and -not $v.HasLauncher) { $skipped.Add([ordered]@{ host = $name; why = 'not on the new launcher yet' }); continue }
            $t = Resolve-KfwTarget $k '' ''
            $screen = $t[0]; $kind = $t[1]
            if (-not $kind) { $skipped.Add([ordered]@{ host = $name; why = 'no launcher' }); continue }
        }
        $ctx = New-KfwActionContext $name $who
        if ($spec.launcher) { $ctx.Screen = $screen; $ctx.Kind = $kind }
        if ($spec.file) { $ctx.Params.file = $spec.file; $ctx.Params['remove'] = [bool]$spec['remove'] }
        if ($Action -eq 'message') { $ctx.Params.text = $msg; $ctx.Params.seconds = $secs }
        $job = $null
        [Threading.Monitor]::Enter($script:App.JobsLock)
        try {
            if ($script:App.Busy.ContainsKey($name)) { $why = 'busy: ' + $script:App.Busy[$name] }
            else { $job = Start-KfwJob $script:App $spec.job $spec.label $name $ctx $s $ip $Action }
        } finally { [Threading.Monitor]::Exit($script:App.JobsLock) }
        if ($job) { $started.Add([ordered]@{ host = $name; job = $job.id }) } else { $skipped.Add([ordered]@{ host = $name; why = $why }) }
    }
    $names = ($started | ForEach-Object { $_.host }) -join ', '
    if ($names.Length -gt 1000) { $names = $names.Substring(0, 1000) }
    $detail = "$($started.Count) started, $($skipped.Count) skipped" + $(if ($msg) { "; $msg" } else { '' })
    Write-KfwAudit $script:St -User $s.user -Role $s.role -Ip $ip -Action "group-$Action" -Target $names -Result ($(if ($started.Count) { 'started' } else { 'refused' })) -Detail $detail
    if (-not $started.Count) {
        Stop-KfwRequest 409 ('Nothing to do: ' + ((@($skipped) | Select-Object -First 10 | ForEach-Object { "$($_.host) $($_.why)" }) -join '; '))
    }
    return New-KfwJsonResponse ([ordered]@{ jobs = @($started); skipped = @($skipped); label = $spec.label }) 202
}

function Get-KfwJobResponse($Req, [string]$Id) {
    $s = Assert-KfwSession $Req
    $job = if ($Id -cmatch '^[A-Za-z0-9_-]{10,40}$') { $script:App.Jobs[$Id] } else { $null }
    if (-not $job -or (-not [string]::Equals($job.user, $s.user, [StringComparison]::OrdinalIgnoreCase) -and $s.role -ne 'admin')) {
        Stop-KfwRequest 404 'no such job'
    }
    return New-KfwJsonResponse (ConvertTo-KfwJobView $job)
}

# --- audit --------------------------------------------------------------------------------------
function Get-KfwAuditCsv($Req) {
    $s = Assert-KfwSession $Req
    Assert-KfwAllowed $Req $s 'audit'
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append([char]0xFEFF).Append("Time,User,Role,Ip,Action,Target,Result,Detail`r`n")
    $fields = 'Time', 'User', 'Role', 'Ip', 'Action', 'Target', 'Result', 'Detail'
    foreach ($line in (Read-KfwAuditLines $script:St)) {
        try { $e = ConvertFrom-Json $line -AsHashtable } catch { continue }
        [void]$sb.Append((($fields | ForEach-Object { ConvertTo-KfwCsvField ([string]$e[$_]) }) -join ',')).Append("`r`n")
    }
    $h = Get-KfwAttachment 'kiosk-fleet-audit.csv'
    return New-KfwResponse -Status 200 -ContentType 'text/csv; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($sb.ToString())) -Headers $h
}

# --- users ---------------------------------------------------------------------------------------
function Get-KfwUsersResponse($Req) {
    $s = Assert-KfwSession $Req
    Assert-KfwAllowed $Req $s 'users'
    $sessions = Get-KfwActiveSessions $script:St
    $out = foreach ($u in (Get-KfwUsers $script:St)) {
        [ordered]@{ name = $u.name; role = $u.role; disabled = $u.disabled; mustChange = $u.must_change; created = $u.created
            lastLogin = [string]$u.last_login; sessions = [int]$sessions[$u.name.ToLowerInvariant()] }
    }
    return New-KfwJsonResponse ([ordered]@{ users = @($out) })
}

function Test-KfwNewPassword([string]$P1, [string]$P2, [string]$Name) {
    # A password an admin sets for an account: any password will do - the
    # rules are for the ones people choose themselves - but the audit log
    # says when it is below them. Returns that note, or ''.
    if (-not $P1) { Stop-KfwRequest 400 'Type the password first.' }
    if ($P1 -cne $P2) { Stop-KfwRequest 400 'The two passwords did not match.' }
    $problem = Get-KfwPasswordProblem $P1 $Name
    if ($problem) { return " (set below the password rules: it would need $problem)" }
    return ''
}

function Add-KfwUserFromPage($Req) {
    $s = Assert-KfwSession $Req
    Assert-KfwAllowed $Req $s 'users' 'user-add'
    $b = Read-KfwJsonBody $Req
    $name = (Get-KfwText $b 'name' 64).Trim(); $role = Get-KfwText $b 'role' 10
    if (-not (Test-KfwUserName $name)) { Stop-KfwRequest 400 'An account name is 2 to 64 letters, digits, dots, dashes, underscores or @.' }
    if (-not $script:RoleRank.ContainsKey($role) -or $role -cnotin 'operator', 'admin') { Stop-KfwRequest 400 'The role is operator or admin.' }
    if (Get-KfwUser $script:St $name) { Stop-KfwRequest 409 "There is an account called $name already." }
    $weak = Test-KfwNewPassword (Get-KfwText $b 'password' 256) (Get-KfwText $b 'password2' 256) $name
    Add-KfwUser $script:St $name $role (Get-KfwText $b 'password' 256) (Get-KfwFlag $b 'mustChange')
    Write-KfwAudit $script:St -User $s.user -Role $s.role -Ip (Get-KfwClientIp $Req) -Action 'user-add' -Target $name -Result 'ok' -Detail ($role + $weak)
    return New-KfwJsonResponse @{ ok = $true }
}

function Set-KfwUserFromPage($Req, [string]$Name) {
    $s = Assert-KfwSession $Req
    Assert-KfwAllowed $Req $s 'users' 'user-change' $Name
    $u = Get-KfwUser $script:St $Name
    if (-not $u) { Stop-KfwRequest 404 'no such account' }
    $Name = $u.name
    $b = Read-KfwJsonBody $Req
    $changes = [Collections.Generic.List[string]]::new()
    $lastAdmin = $u.role -eq 'admin' -and -not $u.disabled -and (Get-KfwUserCount $script:St -ActiveAdminsOnly) -le 1
    $self = [string]::Equals($Name, $s.user, [StringComparison]::OrdinalIgnoreCase)
    if ($b.Contains('role')) {
        $role = Get-KfwText $b 'role' 10
        if ($role -cnotin 'operator', 'admin') { Stop-KfwRequest 400 'The role is operator or admin.' }
        if ($role -ne $u.role) {
            if ($lastAdmin) { Stop-KfwRequest 409 'That is the last admin. Make another admin first.' }
            Set-KfwUserRole $script:St $Name $role
            $changes.Add("role=$role")
        }
    }
    if ($b.Contains('disabled')) {
        $dis = Get-KfwFlag $b 'disabled'
        if ($dis -ne $u.disabled) {
            if ($dis -and $lastAdmin) { Stop-KfwRequest 409 'That is the last admin. Make another admin first.' }
            if ($dis -and $self) { Stop-KfwRequest 409 'You cannot disable your own account.' }
            Set-KfwUserDisabled $script:St $Name $dis
            if ($dis) { Stop-KfwSessionsOf $script:St $Name }
            $changes.Add($(if ($dis) { 'disabled' } else { 'enabled' }))
        }
    }
    if ($b['password']) {
        $p1 = Get-KfwText $b 'password' 256
        $weak = Test-KfwNewPassword $p1 (Get-KfwText $b 'password2' 256) $Name
        $must = Get-KfwFlag $b 'mustChange'
        Set-KfwUserPassword $script:St $Name $p1 $must
        Stop-KfwSessionsOf $script:St $Name ($(if ($self) { $s.token_hash } else { '' }))
        $changes.Add('new password' + $(if ($must) { ', to be changed at next sign-in' } else { '' }) + $weak)
    }
    if ($b['signOut']) {
        Stop-KfwSessionsOf $script:St $Name ($(if ($self) { $s.token_hash } else { '' }))
        $changes.Add('signed out everywhere')
    }
    $detail = if ($changes.Count) { $changes -join '; ' } else { 'nothing changed' }
    Write-KfwAudit $script:St -User $s.user -Role $s.role -Ip (Get-KfwClientIp $Req) -Action 'user-change' -Target $Name -Result 'ok' -Detail $detail
    return New-KfwJsonResponse ([ordered]@{ ok = $true; changed = @($changes) })
}

function Remove-KfwUserFromPage($Req, [string]$Name) {
    $s = Assert-KfwSession $Req
    Assert-KfwAllowed $Req $s 'users' 'user-remove' $Name
    $u = Get-KfwUser $script:St $Name
    if (-not $u) { Stop-KfwRequest 404 'no such account' }
    if ([string]::Equals($u.name, $s.user, [StringComparison]::OrdinalIgnoreCase)) { Stop-KfwRequest 409 'You cannot remove your own account.' }
    if ($u.role -eq 'admin' -and -not $u.disabled -and (Get-KfwUserCount $script:St -ActiveAdminsOnly) -le 1) { Stop-KfwRequest 409 'That is the last admin.' }
    Remove-KfwUser $script:St $u.name
    Write-KfwAudit $script:St -User $s.user -Role $s.role -Ip (Get-KfwClientIp $Req) -Action 'user-remove' -Target $u.name -Result 'ok'
    return New-KfwJsonResponse @{ ok = $true }
}

# --- settings --------------------------------------------------------------------------------------
function Get-KfwListInfo {
    $p = Resolve-KfwKioskList $script:S
    if (-not $p) { return [ordered]@{ path = ''; exists = $false } }
    $exists = Test-Path -LiteralPath $p -PathType Leaf
    $info = [ordered]@{ path = $p; exists = $exists
        uploaded = ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($p)) -eq [IO.Path]::GetFullPath($script:S.DataDir).TrimEnd([IO.Path]::DirectorySeparatorChar)) -and [IO.Path]::GetFileName($p).StartsWith('kiosk-list.')
    }
    if ($exists) {
        $info.modified = [IO.File]::GetLastWriteTime($p).ToString('ddd dd MMM yyyy HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        try {
            $r = Import-KfwKioskList $p $script:S.KioskListSheet $script:S.IncludeAllHosts
            $info.rows = $r.Stats.Rows; $info.included = $r.Stats.Included; $info.inactive = $r.Stats.Inactive; $info.notFlagged = $r.Stats.NotFlagged
            $info.watchdog = @($r.Kiosks | Where-Object { $_.RunsWatchdog }).Count
            $info.sample = @($r.Kiosks | Select-Object -First 500 | ForEach-Object { [ordered]@{ host = $_.Host; location = $_.Location; type = $_.Type } })
        } catch {
            # Shown to the admin as it is.
            $info.error = $_.Exception.Message
        }
    }
    return $info
}

function Get-KfwSettingsResponse($Req) {
    $s = Assert-KfwSession $Req
    Assert-KfwAllowed $Req $s 'settings'
    $st = $script:S
    $mode = if (-not (Test-KfwUsesUnc $st)) { 'folder' } elseif (Test-KfwHasCredential $st) { 'account' } else { 'windows' }
    $account = if ($mode -eq 'windows') { "$([Environment]::UserDomainName)\$([Environment]::UserName)" } else { $st.ShareUser }
    return New-KfwJsonResponse ([ordered]@{
            kioskList = Get-KfwListInfo
            kioskListFixed = [bool]$st.KioskList
            kiosks = [ordered]@{ shareTemplate = $st.ShareTemplate; smb = Test-KfwUsesUnc $st; user = $account
                credential = (Test-KfwHasCredential $st) -or $mode -eq 'windows'; auth = $mode }
            data = [ordered]@{ dir = $st.DataDir; csv = Get-KfwLocalCsv $st; published = $st.PublishCsv }
            collector = [ordered]@{ autoscanDefault = $st.Autoscan; minutes = $st.AutoscanMinutes; parallel = $st.ParallelHosts
                hostTimeout = $st.HostTimeoutSeconds; retentionDays = $st.RetentionDays; trustedFrom = $st.TrustedFromAgentVersion }
            sessions = [ordered]@{ idleMinutes = $st.IdleMinutes; hours = $st.SessionHours; secureCookies = $st.SecureCookies; trustProxy = $st.TrustProxy }
            version = $script:Version
        })
}

function Invoke-KfwListUpload($Req) {
    $s = Assert-KfwSession $Req
    Assert-KfwAllowed $Req $s 'settings' 'kiosk-list'
    if ($script:S.KioskList) { Stop-KfwRequest 409 'The kiosk list is set by KFW_KIOSK_LIST on the server; change it there.' }
    $file = Read-KfwUpload $Req 'file'
    if (-not $file) { Stop-KfwRequest 400 'Upload an .xlsx, .csv or .txt kiosk list.' }
    $ext = [IO.Path]::GetExtension($file.FileName.ToLowerInvariant())
    if ($ext -notin '.xlsx', '.csv', '.txt') { Stop-KfwRequest 400 'Upload an .xlsx, .csv or .txt kiosk list.' }
    if ($file.Bytes.Length -gt 10MB) { Stop-KfwRequest 400 'That file is over 10 MB.' }
    $dir = $script:S.DataDir
    $tmp = Join-Path $dir "kiosk-list.upload$ext"
    [IO.File]::WriteAllBytes($tmp, $file.Bytes)
    try {
        $r = Import-KfwKioskList $tmp $script:S.KioskListSheet $script:S.IncludeAllHosts
    } catch {
        [IO.File]::Delete($tmp)
        Stop-KfwRequest 400 "That list could not be read: $($_.Exception.Message)"
    }
    if (-not @($r.Kiosks).Count) {
        [IO.File]::Delete($tmp)
        Stop-KfwRequest 400 "That list has no kiosks to scan ($($r.Stats.Rows) rows, $($r.Stats.Inactive) not active, $($r.Stats.NotFlagged) not flagged)."
    }
    [Threading.Monitor]::Enter($script:App.ListLock)
    try {
        foreach ($old in [IO.DirectoryInfo]::new($dir).GetFiles('kiosk-list*')) {
            if ($old.Name.StartsWith('kiosk-list.upload') -or -not ($old.Name.StartsWith('kiosk-list.') -or $old.Name.StartsWith('kiosk-list-before-edit.'))) { continue }
            $old.Delete()
        }
        [IO.File]::Move($tmp, (Join-Path $dir "kiosk-list$ext"), $true)
    } finally { [Threading.Monitor]::Exit($script:App.ListLock) }
    Write-KfwAudit $script:St -User $s.user -Role $s.role -Ip (Get-KfwClientIp $Req) -Action 'kiosk-list' -Target $file.FileName -Result 'ok' -Detail "$(@($r.Kiosks).Count) kiosks of $($r.Stats.Rows) rows"
    return New-KfwJsonResponse ([ordered]@{ ok = $true; kiosks = @($r.Kiosks).Count; rows = $r.Stats.Rows })
}

# --- the kiosk list, edited here ----------------------------------------------------------------------
function Invoke-KfwListChange([scriptblock]$Change) {
    try {
        return (& $Change)
    } catch {
        $e = $_.Exception
        if ($e.Data.Contains('KfwStatus')) { throw }
        if ($e.Data.Contains('KfwConflict')) { Stop-KfwRequest 409 $e.Message }
        if ($e.Data.Contains('KfwInvalid')) { Stop-KfwRequest 400 $e.Message }
        throw
    }
}

function Invoke-KfwListSave($Req) {
    $s = Assert-KfwSession $Req
    Assert-KfwAllowed $Req $s 'kiosklist' 'kiosk-list-edit'
    $b = Read-KfwJsonBody $Req
    $row = $b['row']
    $values = @{
        host = Get-KfwText $b 'host' 100; location = Get-KfwText $b 'location' 1000; type = Get-KfwText $b 'type' 1000
        restartGroup = Get-KfwText $b 'restartGroup' 1000; info = Get-KfwText $b 'info' 1000; version = Get-KfwText $b 'version' 1000
        active = Get-KfwText $b 'active' 10; watchdog = (Get-KfwFlag $b 'watchdog')
    }
    $was = Get-KfwText $b 'was' 100
    $r = Invoke-KfwListChange { Set-KfwListRow $script:S $script:App.ListLock $row $was $values }
    $action = if ($null -eq $row) { 'kiosk-list-add' } else { 'kiosk-list-edit' }
    Write-KfwAudit $script:St -User $s.user -Role $s.role -Ip (Get-KfwClientIp $Req) -Action $action -Target $r.Row.Host -Result 'ok' -Detail $r.Change
    return New-KfwJsonResponse ([ordered]@{ ok = $true; host = $r.Row.Host; change = $r.Change })
}

function Invoke-KfwListActive($Req) {
    $s = Assert-KfwSession $Req
    Assert-KfwAllowed $Req $s 'kiosklist' 'kiosk-list-edit'
    $b = Read-KfwJsonBody $Req
    $on = Get-KfwFlag $b 'active'
    $was = Get-KfwText $b 'was' 100
    $row = $b['row']
    $hostName = Invoke-KfwListChange { Set-KfwListRowActive $script:S $script:App.ListLock $row $was $on }
    Write-KfwAudit $script:St -User $s.user -Role $s.role -Ip (Get-KfwClientIp $Req) -Action 'kiosk-list-edit' -Target $hostName -Result 'ok' -Detail ($(if ($on) { 'active -> Y' } else { 'active -> N (not scanned)' }))
    return New-KfwJsonResponse ([ordered]@{ ok = $true; host = $hostName })
}

function Invoke-KfwListRemove($Req) {
    $s = Assert-KfwSession $Req
    Assert-KfwAllowed $Req $s 'kiosklist' 'kiosk-list-remove'
    $b = Read-KfwJsonBody $Req
    $was = Get-KfwText $b 'was' 100
    $row = $b['row']
    $gone = Invoke-KfwListChange { Remove-KfwListRow $script:S $script:App.ListLock $row $was }
    Write-KfwAudit $script:St -User $s.user -Role $s.role -Ip (Get-KfwClientIp $Req) -Action 'kiosk-list-remove' -Target $gone.Host -Result 'ok' -Detail "location=$($gone.Location), type=$($gone.Type)"
    return New-KfwJsonResponse ([ordered]@{ ok = $true; host = $gone.Host })
}
