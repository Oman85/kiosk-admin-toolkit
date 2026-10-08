# What only a Windows server does - DPAPI, a kiosk's share opened by Windows -
# and the server behind Caddy, where Caddy is installed (KFW_TEST_CADDY, or
# caddy on the PATH). Skipped elsewhere.

function Test-ShareCredentialRoundTrip {
    if (-not $IsWindows) { Skip-Test 'DPAPI is Windows' }
    $secret = 'Share-Pass-' + [guid]::NewGuid()
    $blob = Protect-KfwText $secret
    Assert-That (-not $blob.Contains($secret)) 'encrypted'
    Assert-Equal $secret (Unprotect-KfwText $blob)
    $w = New-TestWork
    Set-TestText (Join-Path $w.Data 'share.cred') (ConvertTo-Json @{ User = 'CONTOSO\svc-share'; Password = $blob })
    $saved = @{}; foreach ($n in 'KFW_SHARE_USER', 'KFW_SHARE_PASSWORD', 'KFW_SETTINGS_JSON') { $saved[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n, $null) }
    try {
        $s = Get-KfwSettings -DataDir $w.Data
        Assert-That ($s.ShareUser -eq 'CONTOSO\svc-share' -and $s.SharePassword -eq $secret) 'the server reads share.cred'
    } finally { foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) } }
}

function Test-NativeShareOfThisComputer {
    # \\localhost\C$\Users\Public\Documents, opened by Windows as whoever runs the tests.
    if (-not $IsWindows) { Skip-Test 'a \\server\share is opened by Windows' }
    if (-not (Test-Path '\\localhost\C$\Users\Public\Documents')) { Skip-Test 'the admin share of this computer is not open to this account' }
    $s = New-KfwSettings
    $s.ShareTemplate = '\\{0}\C$\Users\Public\Documents'
    $reach = Test-KfwReachable 'localhost' $s
    Assert-That $reach.Ok "reachable: $($reach.Error)"
    $docs = Connect-KfwKiosk $s 'localhost'
    Assert-Equal '\\localhost\C$\Users\Public\Documents' $docs
    $probe = Join-KfwPath $docs "kfw-test-$PID.txt"
    Write-KfwKioskText $probe 'hello'
    try { Assert-Equal 'hello' (Read-KfwText $probe) } finally { Remove-KfwKioskFile $probe }
}

function Test-ShareProblemOnLinux {
    if ($IsWindows) { Skip-Test 'about Linux' }
    $s = New-KfwSettings
    Assert-That (Get-KfwShareProblem $s).Contains('mount the shares') 'a \\server\share path on Linux says what to do'
    try { [void](Connect-KfwKiosk $s 'MWEB1'); throw 'opened' } catch { Assert-That (Test-KfwKioskError $_.Exception) $_.Exception.Message }
}

function Get-TestCaddy {
    if ($env:KFW_TEST_CADDY -and (Test-Path $env:KFW_TEST_CADDY)) { return $env:KFW_TEST_CADDY }
    $c = Get-Command caddy -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

function Test-BehindCaddy {
    $caddy = Get-TestCaddy
    if (-not $caddy) { Skip-Test 'no Caddy here (KFW_TEST_CADDY)' }
    $srv = Start-TestServer (New-TestWork) -Fleet
    $port = Get-FreePort
    $dir = Join-Path $srv.Work.Dir 'caddy'
    [void][IO.Directory]::CreateDirectory($dir)
    $file = Join-Path $dir 'Caddyfile'
    $text = Get-KfwCaddyfile -SiteAddress "https://localhost:$port" -WebDir (Join-Path $script:Repo 'KioskFleetWeb/web') -Storage $dir -Backend "127.0.0.1:$($srv.Port)"
    # No :80 for the redirect in a test.
    Set-TestText $file ($text -replace 'skip_install_trust', "skip_install_trust`n`tauto_https disable_redirects")
    $p = Start-Process $caddy -ArgumentList 'run', '--config', $file, '--adapter', 'caddyfile' -PassThru -RedirectStandardError (Join-Path $dir 'err.txt') -RedirectStandardOutput (Join-Path $dir 'out.txt')
    try {
        $h = [Net.Http.HttpClientHandler]::new()
        $h.ServerCertificateCustomValidationCallback = [Net.Http.HttpClientHandler]::DangerousAcceptAnyServerCertificateValidator
        $h.CookieContainer = [Net.CookieContainer]::new()
        $c = @{ Http = [Net.Http.HttpClient]::new($h); Csrf = $null; Base = "https://localhost:$port" }
        $deadline = [datetime]::UtcNow.AddSeconds(30)
        do { Start-Sleep -Milliseconds 300; try { $hz = Get-Test $c '/healthz' } catch { $hz = $null } } while (-not ($hz -and $hz.Status -eq 200) -and [datetime]::UtcNow -lt $deadline)
        Assert-That ($hz -and $hz.Json.fleet) 'healthz through Caddy'
        $page = Get-Test $c '/'
        Assert-That ($page.Status -eq 200 -and $page.Headers['strict-transport-security'] -and $page.Headers['content-security-policy']) 'the page, from Caddy, with its headers'
        Assert-Equal 200 (Get-Test $c '/setup').Status
        $origin = @{ Origin = "https://localhost:$port" }
        Assert-Equal 403 (Send-Test $c '/api/login' @{ user = 'webadmin'; password = $script:AdminPass } -Headers @{ Origin = 'https://evil.example' }).Status
        $msg = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, "$($c.Base)/api/login")
        $msg.Headers.Add('Origin', $origin.Origin)
        $msg.Content = [Net.Http.StringContent]::new((ConvertTo-Json @{ user = 'webadmin'; password = $script:AdminPass }), [Text.Encoding]::UTF8, 'application/json')
        $r = $c.Http.SendAsync($msg).GetAwaiter().GetResult()
        $cookie = ($r.Headers.GetValues('Set-Cookie') -join ';')
        Assert-That ($cookie.Contains('Secure') -and $cookie.Contains('HttpOnly')) "a Secure cookie over HTTPS: $cookie"
        $me = ConvertFrom-Json ($r.Content.ReadAsStringAsync().GetAwaiter().GetResult()) -AsHashtable
        Assert-Equal $false $me.insecure 'HTTPS, as Caddy says'
        $c.Csrf = $me.csrf
        $j = Send-Test $c '/api/kiosks/MWEB1/reload' @{} -Headers $origin
        Assert-Equal 202 $j.Status $j.Text
    } finally {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
}
