# The web app: signing in, what each role may and may not do, the fleet it
# serves, what its buttons do to a kiosk, the config editor, accounts,
# settings and the audit log.

function Start-TestFleet([hashtable]$Env = @{}) {
    $w = New-TestWork
    return Start-TestServer $w -Fleet -Env $Env
}

# --- the page and signing in ------------------------------------------------------------------
function Test-PageAndHeaders {
    $srv = Start-TestFleet
    $c = New-TestClient $srv
    $r = Get-Test $c '/'
    Assert-That ($r.Status -eq 200 -and $r.Text.Contains('<title>Kiosk Fleet</title>')) 'the page'
    Assert-That ($r.Headers['content-security-policy'].Contains("default-src 'self'")) 'CSP'
    Assert-Equal 'DENY' $r.Headers['x-frame-options']
    Assert-That ((Get-Test $c '/app.js').Headers['content-type'].StartsWith('text/javascript')) 'app.js type'
    $logo = Get-Test $c '/logo.svg'
    Assert-That ($logo.Status -eq 200 -and $logo.Headers['content-type'].StartsWith('image/svg+xml') -and $logo.Text.Contains('<svg')) 'the logo'
    Assert-Equal $true (Get-Test $c '/healthz').Json.ok
    $me = Get-Test $c '/api/me'
    Assert-Equal 401 $me.Status
    Assert-Equal @{ windows = $false; local = $true } $me.Json.methods
    Assert-Equal '' $me.Json.site 'no site set: the page says what Kiosk Fleet is'
    Assert-Equal @() @($me.Json.allowed) 'nothing allowed before signing in'
    Assert-Equal 401 (Get-Test $c '/api/state').Status
    Assert-Equal 401 (Send-Test $c '/api/kiosks/MWEB1/reload').Status
    Assert-Equal 404 (Get-Test $c '/../kfw/app.py').Status
    Assert-That ((Get-Test $c '/api/nothing-here').Status -in 401, 404) 'unknown API'
}

function Test-SiteNameOnSignIn {
    $srv = Start-TestFleet @{ KFW_SITE_NAME = 'CZECH DIVISION - Nyrany' }
    $me = Get-Test (New-TestClient $srv) '/api/me'
    Assert-That ($me.Status -eq 401 -and $me.Json.site -eq 'CZECH DIVISION - Nyrany') 'shown before signing in'
}

function Test-SignInAndLockout {
    $srv = Start-TestFleet
    $a = New-TestClient $srv
    $bad = Connect-Test $a 'webop' 'wrong-password'
    $ghost = Connect-Test $a 'nobody' 'whatever-it-is'
    Assert-That ($bad.Status -eq 401 -and $ghost.Status -eq 401 -and $bad.Text -eq $ghost.Text) 'a wrong password and a wrong name look the same'
    foreach ($i in 1..4) { [void](Connect-Test $a 'webop' 'wrong-again') }
    Assert-Equal 429 (Connect-Test $a 'webop' $script:OpPass).Status 'five wrong passwords lock the name'
    $ok = Connect-Test $a 'webadmin' $script:AdminPass
    Assert-That ($ok.Status -eq 200 -and $ok.Json.role -eq 'admin') 'the admin still signs in'
}

function Test-SessionCookie {
    $srv = Start-TestFleet
    $msg = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, "$($srv.Base)/api/login")
    $msg.Content = [Net.Http.StringContent]::new((ConvertTo-Json @{ user = 'webadmin'; password = $script:AdminPass }), [Text.Encoding]::UTF8, 'application/json')
    $h = [Net.Http.HttpClientHandler]::new(); $h.UseCookies = $false
    $r = [Net.Http.HttpClient]::new($h).SendAsync($msg).GetAwaiter().GetResult()
    $cookie = ($r.Headers.GetValues('Set-Cookie') -join ';').ToLowerInvariant()
    Assert-That ($cookie.Contains('httponly') -and $cookie.Contains('samesite=strict')) "cookie: $cookie"
}

function Test-CsrfAndOrigin {
    $srv = Start-TestFleet
    $admin = New-TestAdmin $srv
    $r = Send-Test $admin '/api/scan' -NoCsrf
    Assert-That ($r.Status -eq 403 -and $r.Json.error.Contains('out of date')) 'no CSRF token'
    $r = Send-Test $admin '/api/kiosks/MWEB1/reload' @{} -Headers @{ Origin = 'http://evil.example' }
    Assert-That ($r.Status -eq 403 -and $r.Json.error -eq 'wrong origin') 'another origin'
    $r = Send-Test (New-TestClient $srv) '/api/login' @{ user = 'webadmin'; password = $script:AdminPass } -Headers @{ Origin = 'http://evil.example' }
    Assert-Equal 403 $r.Status 'signing in from another origin'
}

function Test-SignOut {
    $srv = Start-TestFleet
    $admin = New-TestAdmin $srv
    Assert-Equal 200 (Send-Test $admin '/api/logout').Status
    Assert-Equal 401 (Get-Test $admin '/api/state').Status
}

function Test-FirstAdminSetup {
    $w = New-TestWork
    $srv = Start-TestServer $w -NoUsers
    $token = ((Get-Content -Raw (Join-Path $w.Data 'setup-link.txt')) -split 'token=')[1].Trim()
    Assert-That $token 'with no accounts the server makes a one-time setup link'
    $c = New-TestClient $srv
    Assert-Equal $true (Get-Test $c '/api/me').Json.setup
    Assert-Equal 403 (Send-Test $c '/api/setup' @{ token = 'wrong'; user = 'boss'; password = $script:AdminPass; password2 = $script:AdminPass }).Status
    Assert-Equal 400 (Send-Test $c '/api/setup' @{ token = $token; user = 'boss'; password = 'short'; password2 = 'short' }).Status
    $r = Send-Test $c '/api/setup' @{ token = $token; user = 'boss'; password = $script:AdminPass; password2 = $script:AdminPass }
    Assert-That ($r.Status -eq 200 -and $r.Json.role -eq 'admin') "setup: $($r.Text)"
    $again = Send-Test $c '/api/setup' @{ token = $token; user = 'boss2'; password = $script:AdminPass; password2 = $script:AdminPass }
    Assert-Equal 409 $again.Status 'the link works once'
    Assert-That (-not (Test-Path (Join-Path $w.Data 'setup-link.txt'))) 'the link file goes once used'
}

function Test-BootstrapAdminFromEnvironment {
    $w = New-TestWork
    $srv = Start-TestServer $w -NoUsers -Env @{ KFW_ADMIN_USER = 'envadmin'; KFW_ADMIN_PASSWORD = $script:AdminPass }
    Assert-That (-not (Test-Path (Join-Path $w.Data 'setup-link.txt'))) 'no setup link'
    Assert-Equal 200 (Connect-Test (New-TestClient $srv) 'envadmin' $script:AdminPass).Status
}

# --- roles --------------------------------------------------------------------------------------
function Test-OperatorIsRefusedAdminThings {
    $srv = Start-TestFleet
    $op = New-TestOperator $srv
    $me = (Get-Test $op '/api/me').Json
    Assert-That ($me.role -eq 'operator' -and $me.allowed -notcontains 'restart' -and $me.allowed -contains 'live') 'the operator role'
    foreach ($action in 'restart', 'hold', 'stop', 'password', 'config-read', 'config-write') {
        Assert-Equal 403 (Send-Test $op "/api/kiosks/MWEB1/$action" @{ kind = 'NG' }).Status $action
    }
    foreach ($path in '/api/audit', '/api/users', '/api/settings', '/api/kiosklist') { Assert-Equal 403 (Get-Test $op $path).Status $path }
    Assert-Equal 403 (Send-Test $op '/api/autoscan' @{ on = $true }).Status
    Assert-Equal 403 (Send-Test $op '/api/users' @{ name = 'x1'; role = 'admin'; password = $script:AdminPass; password2 = $script:AdminPass }).Status
    $refused = @(Get-TestAudit (New-TestAdmin $srv) 'refused' | Where-Object { $_.Result -eq 'refused' -and $_.User -eq 'webop' })
    Assert-That ($refused.Count -ge 6) "every refusal is in the audit log ($($refused.Count))"
}

function Test-OperatorCanDoSafeThings {
    $srv = Start-TestFleet
    $r, $j = Invoke-TestJob (New-TestOperator $srv) 'MWEB1' 'reload'
    Assert-That ($r.Status -eq 202 -and $j.ok) "reload: $($r.Text) $(ConvertTo-Json $j -Compress)"
}

# --- the fleet ----------------------------------------------------------------------------------
function Test-State {
    $srv = Start-TestFleet
    $admin = New-TestAdmin $srv
    $d = (Get-Test $admin '/api/state').Json
    $f = $d.fleet
    Assert-That ($f.Ok -and $f.Total -eq 7) 'seven kiosks'
    Assert-That ($f.Attention -eq 3 -and $f.Critical -eq 3) "attention $($f.Attention) critical $($f.Critical)"
    $hosts = @{}; foreach ($k in $f.Kiosks) { $hosts[$k.Host] = $k }
    Assert-That ($f.Kiosks[0].Status -in 'OFFLINE', 'STALE', 'WRONG_ACCOUNT') 'trouble first'
    Assert-Equal '2 (1)' $hosts.MWEB2.Reboots
    Assert-Equal 3 ([int]($hosts.MWEB2.Days | Measure-Object -Sum).Sum)
    Assert-Equal 'kiosk@contoso.test' $hosts.PWEB1.Launchers.PBI.Account
    Assert-Equal '72%' $hosts.MWEB1.Launchers.Mach2.Screen
    Assert-That ($hosts.MWEB1.MessageOk -and -not $hosts.MWEB3.MessageOk) 'messages need V7.0 or NG'
    Assert-Equal 'Other' $hosts.OWEB1.Tab
    Assert-Equal $false $d.live.fresh.stale
    $again = (Get-Test $admin '/api/state' @{ since = $d.live.stamp }).Json
    Assert-Equal $null $again.fleet 'an unchanged fleet is not sent again'
}

function Test-KioskNamesAreChecked {
    $srv = Start-TestFleet
    $admin = New-TestAdmin $srv
    Assert-That ((Send-Test $admin '/api/kiosks/..%2F..%2Fetc/live').Status -in 400, 404) 'a path in the name'
    Assert-Equal 400 (Send-Test $admin '/api/kiosks/bad$name/live').Status
    Assert-Equal 404 (Send-Test $admin '/api/kiosks/NOSUCH1/live').Status
    Assert-Equal 404 (Send-Test $admin '/api/kiosks/MWEB1/format-disk').Status
}

# --- doing things to a kiosk ------------------------------------------------------------------------
function Test-ControlFiles {
    $srv = Start-TestFleet
    $admin = New-TestAdmin $srv
    $ng = $srv.Work.Dirs.ng
    foreach ($pair in @(@('reload', 'refresh.txt'), @('relaunch', 'relaunch.txt'), @('stop', 'kill.txt'))) {
        $r, $j = Invoke-TestJob $admin 'MWEB1' $pair[0] @{ screen = 'S1'; kind = 'NG' }
        Assert-That ($j -and $j.ok -and $j.detail.Contains('taken')) "$($pair[0]): $(ConvertTo-Json $j -Compress)"
        Assert-That ((Get-Content -Raw (Join-Path $ng "taken.$($pair[1])")).Contains('webadmin (admin)')) 'control files say who asked'
        Assert-That ($j.lines -contains "S1 NG: $($pair[1]) written") 'the job says what it did'
    }
    $r, $j = Invoke-TestJob $admin 'MWEB1' 'hold' @{ screen = 'S1'; kind = 'NG' }
    Assert-That ($j.ok -and (Test-Path (Join-Path $ng 'hold.txt'))) 'hold.txt stays'
    Assert-Equal $true (Get-Test $admin '/api/state').Json.live.hold.MWEB1
    $r, $j = Invoke-TestJob $admin 'MWEB1' 'resume' @{ screen = 'S1'; kind = 'NG' }
    Assert-That ($j.ok -and -not (Test-Path (Join-Path $ng 'hold.txt'))) 'resume removes it'
}

function Test-LiveRead {
    $srv = Start-TestFleet
    $admin = New-TestAdmin $srv
    $r, $j = Invoke-TestJob $admin 'PWEB1' 'live'
    Assert-That $j.ok (ConvertTo-Json $j -Compress -Depth 5)
    $lines = @{}; foreach ($l in $j.result.lines) { $lines[$l.Label] = $l.Value }
    Assert-That (@($lines.Values | Where-Object { $_.Contains('SHOWING as kiosk@contoso.test') }).Count) 'the launcher state'
    Assert-Equal 'https://app.powerbi.test/report' $lines.Shows
    Assert-That (@((Get-Test $admin '/api/state').Json.live.live.PWEB1.Lines).Count) 'the reading is shared'
}

function Test-Screenshot {
    $srv = Start-TestFleet
    $admin = New-TestAdmin $srv
    $r, $j = Invoke-TestJob $admin 'MWEB1' 'snapshot' @{ screen = 'S1'; kind = 'NG' }
    Assert-That $j.ok (ConvertTo-Json $j -Compress -Depth 5)
    $img = Get-Test $admin "/api/snapshots/$($j.result.file)"
    Assert-That ($img.Status -eq 200 -and $img.Headers['content-type'] -eq 'image/png' -and $img.Bytes[0] -eq 0x89 -and $img.Bytes[1] -eq 0x50) 'the picture'
    Assert-Equal 404 (Get-Test $admin '/api/snapshots/..%2Fusers.json').Status
}

function Test-Log {
    $srv = Start-TestFleet
    $r, $j = Invoke-TestJob (New-TestAdmin $srv) 'MWEB1' 'log' @{ screen = 'S1'; kind = 'NG' }
    Assert-That $j.ok (ConvertTo-Json $j -Compress -Depth 5)
    Assert-That (@($j.result.lines | Where-Object { $_.Contains('The dashboard is on screen.') }).Count) 'the log line'
}

function Test-PasswordHandOver {
    $srv = Start-TestFleet
    $admin = New-TestAdmin $srv
    $secret = 'Kiosk-Pass-9876!'
    Assert-Equal 400 (Send-Test $admin '/api/kiosks/PWEB1/password' @{ password = $secret; password2 = 'different' }).Status
    $r, $j = Invoke-TestJob $admin 'PWEB1' 'password' @{ password = $secret; password2 = $secret }
    Assert-That ($j.ok -and $j.detail.Contains('stored')) (ConvertTo-Json $j -Compress)
    Assert-Equal $secret (Get-Content -Raw (Join-Path $srv.Work.Dirs.pbi 'taken.seed'))
    $blob = ConvertTo-Json (Get-TestAudit $admin) -Depth 5
    Assert-That (-not $blob.Contains($secret)) 'a password is never in the audit log'
    foreach ($f in Get-ChildItem $srv.Work.Data -File) {
        Assert-That (-not ([IO.File]::ReadAllText($f.FullName)).Contains($secret)) "nor in $($f.Name)"
    }
}

function Test-ConfigEditor {
    $srv = Start-TestFleet
    $admin = New-TestAdmin $srv
    $ng = $srv.Work.Dirs.ng
    $r, $j = Invoke-TestJob $admin 'MWEB1' 'config-read' @{ kind = 'NG'; instance = 'S1' }
    Assert-That ($j.ok -and -not $j.result.isNew) (ConvertTo-Json $j -Compress -Depth 6)
    $fields = @{}; foreach ($f in $j.result.fields) { $fields[$f.Key] = $f }
    Assert-That ($fields.DisplayURL.Value -eq 'http://station:302/ord/dashboard' -and -not $fields.DisplayURL.Advanced) 'the URL first'

    $r, $j = Invoke-TestJob $admin 'MWEB1' 'config-write' @{ kind = 'NG'; instance = 'S1'; values = @{ DisplayURL = 'http://station:302/ord/other'; UserName = 'operator'; Sneaky = 'x' } }
    Assert-That $j.ok (ConvertTo-Json $j -Compress -Depth 6)
    $saved = Get-Content -Raw (Join-Path $ng 'MWEB1.json') | ConvertFrom-Json -AsHashtable
    Assert-Equal 'http://station:302/ord/other' $saved.DisplayURL
    Assert-That (-not $saved.ContainsKey('Sneaky')) 'only the file''s own keys can be set'
    Assert-That (@(Get-ChildItem $ng -Filter 'MWEB1.json.bak-*').Count) 'the old one is kept'

    # A new kiosk: the config comes from EXAMPLE.json.
    $r, $j = Invoke-TestJob $admin 'NEWWEB1' 'config-read' @{ kind = 'WEB'; instance = '' }
    Assert-That ($j.ok -and $j.result.isNew) (ConvertTo-Json $j -Compress -Depth 6)
    $r, $j = Invoke-TestJob $admin 'NEWWEB1' 'config-write' @{ kind = 'WEB'; instance = 'S1'; values = @{ DisplayURL = 'https://intranet.test/board' } }
    Assert-That ($j.ok -and $j.result.isNew) (ConvertTo-Json $j -Compress -Depth 6)
    $cfg = Get-Content -Raw (Join-Path (Get-TestDocs $srv.Work 'NEWWEB1') 'WebLauncher/S1/NEWWEB1.json') | ConvertFrom-Json -AsHashtable
    Assert-That ($cfg.DisplayURL -eq 'https://intranet.test/board' -and $cfg.LogName -eq 'WebLauncher_NEWWEB1.log') 'from the template'

    # One launcher per screen.
    $r, $j = Invoke-TestJob $admin 'MWEB1' 'config-write' @{ kind = 'PBI'; instance = 'S1'; values = @{ DisplayURL = 'https://x'; UserName = 'y' } }
    Assert-That (-not $j.ok -and $j.detail.Contains('one launcher per screen')) (ConvertTo-Json $j -Compress)
}

function Test-Message {
    $srv = Start-TestFleet
    $admin = New-TestAdmin $srv
    $r, $j = Invoke-TestJob $admin 'MWEB1' 'message' @{ text = 'Lunch in five'; seconds = 30 } 30
    Assert-That ($j -and $j.ok -and $j.result.status -eq 'ACKNOWLEDGED') (ConvertTo-Json $j -Compress)
    Assert-Equal 400 (Send-Test $admin '/api/kiosks/PWEB1/message' @{ text = 'hi' }).Status 'only Mach2 kiosks show messages'
}

function Test-Restart {
    # Through the launcher's restart.txt - no WMI - with the countdown and
    # message for it to pass to Windows.
    $srv = Start-TestFleet
    $admin = New-TestAdmin $srv
    $r, $j = Invoke-TestJob $admin 'MWEB1' 'restart' @{ seconds = 30; message = 'Back in a minute' }
    Assert-That ($j.ok -and $j.detail.Contains('restarts in 30 s')) (ConvertTo-Json $j -Compress)
    $asked = Get-Content -Raw (Join-Path $srv.Work.Dirs.ng 'taken.restart.txt') | ConvertFrom-Json -AsHashtable
    Assert-That ($asked.Seconds -eq 30 -and $asked.Message -eq 'Back in a minute' -and $asked.By -eq 'webadmin (admin)') 'restart.txt'
    Assert-Equal 400 (Send-Test $admin '/api/kiosks/MWEB1/restart' @{ seconds = 99999 }).Status
    [void][IO.Directory]::CreateDirectory((Get-TestDocs $srv.Work 'MWEB3'))
    $r, $j = Invoke-TestJob $admin 'MWEB3' 'restart' @{ seconds = 0 }
    Assert-That ($j -and -not $j.ok -and $j.detail.Contains('no launcher')) 'a kiosk without a launcher cannot be restarted from here'
}

function Test-ShareSettings {
    # Public Documents is all a kiosk shows; the old name still works.
    $names = 'KFW_SHARE', 'KFW_ROOT_TEMPLATE', 'KFW_SHARE_USER', 'KFW_SETTINGS_JSON', 'KFW_DATA_DIR'
    $saved = @{}; foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n, $null) }
    try {
        $d = Join-Path $script:TestRoot 'settings'
        Assert-Equal '\\{0}\C$\Users\Public\Documents' (Get-KfwSettings -DataDir $d).ShareTemplate
        [Environment]::SetEnvironmentVariable('KFW_ROOT_TEMPLATE', '\\{0}\C$')
        Assert-Equal '\\{0}\C$\Users\Public\Documents' (Get-KfwSettings -DataDir $d).ShareTemplate
        [Environment]::SetEnvironmentVariable('KFW_SHARE', '\\{0}\KioskDocs')
        Assert-Equal '\\{0}\KioskDocs' (Get-KfwSettings -DataDir $d).ShareTemplate
        # kfw.env in the data folder, under the environment.
        [Environment]::SetEnvironmentVariable('KFW_SHARE', $null)
        [Environment]::SetEnvironmentVariable('KFW_ROOT_TEMPLATE', $null)
        Set-TestText (Join-Path $d 'kfw.env') "# a comment`nKFW_SHARE='\\{0}\FromFile'`nKFW_SITE_NAME=Plant 7`n"
        $s = Get-KfwSettings -DataDir $d
        Assert-That ($s.ShareTemplate -eq '\\{0}\FromFile' -and $s.SiteName -eq 'Plant 7') 'kfw.env is read'
    } finally {
        foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
    }
}

function Test-Busy {
    $srv = Start-TestFleet
    $admin = New-TestAdmin $srv
    $r1 = Send-Test $admin '/api/kiosks/MWEB1/message' @{ text = 'one'; seconds = 30 }
    Assert-Equal 202 $r1.Status
    $r2 = Send-Test $admin '/api/kiosks/MWEB1/reload'
    Assert-That ($r2.Status -eq 409 -and $r2.Json.error.Contains('busy')) "busy: $($r2.Text)"
    [void](Wait-TestJobs $admin @(@{ host = 'MWEB1'; job = $r1.Json.job }))
}

function Test-JobsArePrivate {
    $srv = Start-TestFleet
    $admin = New-TestAdmin $srv; $op = New-TestOperator $srv
    $r, $j = Invoke-TestJob $op 'MWEB1' 'reload'
    Assert-Equal 200 (Get-Test $admin "/api/jobs/$($j.id)").Status 'an admin sees everyone''s'
    $r, $j = Invoke-TestJob $admin 'MWEB1' 'reload'
    Assert-Equal 404 (Get-Test $op "/api/jobs/$($j.id)").Status 'an operator sees their own'
}

function Test-ConnectionTest {
    $srv = Start-TestFleet
    $r, $j = Invoke-TestJob (New-TestAdmin $srv) 'MWEB1' 'test'
    Assert-That $j.ok (ConvertTo-Json $j -Compress -Depth 5)
    Assert-That (@($j.result.lines | Where-Object { $_.Value.Contains('Mach2 Launcher NG') }).Count) 'it finds the launcher'
}

function Test-NoDeploys {
    $srv = Start-TestFleet
    $admin = New-TestAdmin $srv
    Assert-Equal 404 (Get-Test $admin '/api/deploy/products').Status
    Assert-Equal 404 (Send-Test $admin '/api/deploy' @{ product = 'NG'; hosts = @('MWEB1') }).Status
    Assert-That ((Get-Test $admin '/api/me').Json.allowed -notcontains 'deploy') 'no deploy permission'
}

# --- accounts ------------------------------------------------------------------------------------
function Test-Users {
    $srv = Start-TestFleet
    $admin = New-TestAdmin $srv
    Assert-Equal 400 (Send-Test $admin '/api/users' @{ name = 'nightshift'; role = 'operator'; password = ''; password2 = '' }).Status
    Assert-Equal 400 (Send-Test $admin '/api/users' @{ name = 'nightshift'; role = 'operator'; password = 'short'; password2 = 'shorter' }).Status
    Assert-Equal 200 (Send-Test $admin '/api/users' @{ name = 'nightshift'; role = 'operator'; password = 'Night-Shift-2026!'; password2 = 'Night-Shift-2026!'; mustChange = $true }).Status
    Assert-Equal 409 (Send-Test $admin '/api/users' @{ name = 'NightShift'; role = 'operator'; password = 'Night-Shift-2026!'; password2 = 'Night-Shift-2026!' }).Status
    $names = @{}; foreach ($u in (Get-Test $admin '/api/users').Json.users) { $names[$u.name] = $u }
    Assert-Equal $true $names.nightshift.mustChange

    # They must choose their own password before anything else.
    $n = New-TestClient $srv
    Assert-Equal $true (Connect-Test $n 'nightshift' 'Night-Shift-2026!').Json.mustChange
    Assert-Equal 428 (Get-Test $n '/api/state').Status
    Assert-Equal 400 (Send-Test $n '/api/me/password' @{ current = 'wrong'; password = 'Own-Choice-2026?'; password2 = 'Own-Choice-2026?' }).Status
    Assert-Equal 200 (Send-Test $n '/api/me/password' @{ current = 'Night-Shift-2026!'; password = 'Own-Choice-2026?'; password2 = 'Own-Choice-2026?' }).Status
    Assert-Equal 200 (Get-Test $n '/api/state').Status

    # A role change or disabling takes effect at once.
    Assert-Equal 200 (Send-Test $admin '/api/users/nightshift' @{ role = 'admin' }).Status
    Assert-Equal 'admin' (Get-Test $n '/api/me').Json.role
    Assert-Equal 200 (Send-Test $admin '/api/users/nightshift' @{ disabled = $true }).Status
    Assert-Equal 401 (Get-Test $n '/api/state').Status
    Assert-Equal 401 (Connect-Test (New-TestClient $srv) 'nightshift' 'Own-Choice-2026?').Status

    Assert-Equal 200 (Invoke-TestRequest $admin DELETE '/api/users/nightshift').Status
    Assert-That (@((Get-Test $admin '/api/users').Json.users | ForEach-Object { $_.name }) -notcontains 'nightshift') 'removed'
    $acts = @(Get-TestAudit $admin | ForEach-Object { $_.Action })
    foreach ($a in 'user-add', 'user-change', 'user-remove', 'password-change') { Assert-That ($acts -contains $a) "audited: $a" }
}

function Test-AdminSetsAnyPassword {
    # The password rules are for the passwords people choose themselves; an
    # admin setting one is only told, in the audit log.
    $srv = Start-TestFleet
    $admin = New-TestAdmin $srv
    $r = Send-Test $admin '/api/users' @{ name = 'lineone'; role = 'operator'; password = '1234'; password2 = '1234'; mustChange = $true }
    Assert-Equal 200 $r.Status $r.Text
    $added = Get-TestAudit $admin 'lineone' | Where-Object { $_.Action -eq 'user-add' } | Select-Object -First 1
    Assert-That $added.Detail.Contains('below the password rules') $added.Detail

    # Their own choice still has to meet the rules.
    $u = New-TestClient $srv
    Assert-Equal $true (Connect-Test $u 'lineone' '1234').Json.mustChange
    Assert-Equal 400 (Send-Test $u '/api/me/password' @{ current = '1234'; password = 'abcd'; password2 = 'abcd' }).Status
    Assert-Equal 200 (Send-Test $u '/api/me/password' @{ current = '1234'; password = 'Line-One-2026!'; password2 = 'Line-One-2026!' }).Status

    Assert-Equal 200 (Send-Test $admin '/api/users/lineone' @{ password = 'line1'; password2 = 'line1'; mustChange = $false }).Status
    Assert-Equal 200 (Connect-Test (New-TestClient $srv) 'lineone' 'line1').Status
    $changed = Get-TestAudit $admin 'lineone' | Where-Object { $_.Action -eq 'user-change' } | Select-Object -First 1
    Assert-That $changed.Detail.Contains('below the password rules') $changed.Detail
    Assert-Equal 200 (Send-Test $admin '/api/users/lineone' @{ password = 'Strong-Enough-2026!'; password2 = 'Strong-Enough-2026!' }).Status
    $changed = Get-TestAudit $admin 'lineone' | Where-Object { $_.Action -eq 'user-change' } | Select-Object -First 1
    Assert-That (-not $changed.Detail.Contains('below')) $changed.Detail
}

function Test-LastAdminIsKept {
    $srv = Start-TestFleet
    $admin = New-TestAdmin $srv
    Assert-Equal 409 (Send-Test $admin '/api/users/webadmin' @{ role = 'operator' }).Status
    Assert-Equal 409 (Send-Test $admin '/api/users/webadmin' @{ disabled = $true }).Status
    Assert-Equal 409 (Invoke-TestRequest $admin DELETE '/api/users/webadmin').Status
}

function Test-ImportPowerShellAccounts {
    $srv = Start-TestFleet
    $rec = New-KfwPasswordHash 'Imported-Pass-11!'
    $file = Join-Path $srv.Work.Dir 'web-users.json'
    $u = [ordered]@{ Name = 'oldtimer'; Role = 'operator'; Disabled = $false }
    foreach ($k in $rec.Keys) { $u[$k] = $rec[$k] }
    Set-TestText $file (ConvertTo-Json @{ Version = 1; Users = @($u) } -Depth 4)
    # From the command line, while the server runs.
    $env:KFW_SETTINGS_JSON = $null
    $out = & (Get-KfwPwshPath) -NoProfile -File (Join-Path $script:Repo 'Set-KioskFleetUser.ps1') import $file -DataDir $srv.Work.Data 2>&1
    Assert-That (($out -join ' ').Contains('Imported 1 account(s): oldtimer')) ($out -join ' ')
    Assert-Equal 200 (Connect-Test (New-TestClient $srv) 'oldtimer' 'Imported-Pass-11!').Status 'the server reads the change at once'
}

function Test-CommandLineSignsPeopleOut {
    # A new password or disabling from Set-KioskFleetUser.ps1, while the server
    # runs, ends that person's sessions there too.
    $srv = Start-TestFleet
    $op = New-TestOperator $srv
    $cli = { param([string[]]$a)
        $env:KFW_SETTINGS_JSON = $null
        $env:KFW_NEW_PASSWORD = 'Brand-New-Pass-55!'
        try { & (Get-KfwPwshPath) -NoProfile -File (Join-Path $script:Repo 'Set-KioskFleetUser.ps1') @a -DataDir $srv.Work.Data 2>&1 }
        finally { $env:KFW_NEW_PASSWORD = $null }
    }
    $out = & $cli @('passwd', 'webop')
    Assert-That (($out -join ' ').Contains('webop: new password')) ($out -join ' ')
    Assert-Equal 401 (Get-Test $op '/api/state').Status 'the old session is over'
    Assert-Equal 401 (Connect-Test (New-TestClient $srv) 'webop' $script:OpPass).Status 'the old password is gone'
    $again = New-TestClient $srv
    Assert-Equal 200 (Connect-Test $again 'webop' 'Brand-New-Pass-55!').Status 'the new one works'
    $out = & $cli @('disable', 'webop')
    Assert-Equal 401 (Get-Test $again '/api/state').Status 'disabled: signed out'
    $listed = & $cli @('list')
    Assert-That (($listed -join "`n") -match 'webop\s+operator\s+disabled') ($listed -join ' | ')
}

# --- settings ----------------------------------------------------------------------------------------
function Test-KioskListUpload {
    $srv = Start-TestFleet
    $admin = New-TestAdmin $srv
    Assert-Equal $false (Get-Test $admin '/api/settings').Json.kioskList.exists
    Assert-Equal $false (Get-Test $admin '/api/state').Json.live.kioskList
    Assert-Equal 400 (Send-TestUpload $admin 'list.exe' ([Text.Encoding]::ASCII.GetBytes('MZ'))).Status
    $body = [Text.Encoding]::UTF8.GetBytes("Host,Location,Type,HasMwst,Active`nMWEB1,LINE1,Mach2,Y,`nPWEB1,APU1,PBI,,`nOLD1,X,Mach2,Y,N`n")
    $r = Send-TestUpload $admin 'kiosks.csv' $body
    Assert-That ($r.Status -eq 200 -and $r.Json.kiosks -eq 2) $r.Text
    $s = (Get-Test $admin '/api/settings').Json.kioskList
    Assert-That ($s.included -eq 2 -and $s.inactive -eq 1) (ConvertTo-Json $s -Compress)
    $down = Get-Test $admin '/api/settings/kiosk-list'
    Assert-Equal ([Convert]::ToBase64String($body)) ([Convert]::ToBase64String($down.Bytes)) 'the same file back'
}

function Test-AuditSearchAndCsv {
    $srv = Start-TestFleet
    $admin = New-TestAdmin $srv
    [void](Invoke-TestJob $admin 'MWEB1' 'reload')
    $hits = Get-TestAudit $admin 'reload'
    Assert-That ($hits.Count -and -not @($hits | Where-Object { -not (ConvertTo-Json $_ -Compress).ToLowerInvariant().Contains('reload') }).Count) 'search'
    $csv = (Get-Test $admin '/api/audit.csv').Text
    Assert-That ($csv.StartsWith([string][char]0xFEFF + 'Time,User,Role') -and $csv.Contains('reload')) $csv.Substring(0, [Math]::Min(80, $csv.Length))
}
