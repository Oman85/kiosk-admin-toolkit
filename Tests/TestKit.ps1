# What the tests share: a fleet of folders standing in for kiosks, a real
# server process on a free port, an HTTP client that keeps its cookies (one
# per person signed in), and the asserts. Nothing here touches a network
# beyond 127.0.0.1.

$ErrorActionPreference = 'Stop'
$script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
Import-Module (Join-Path $script:Repo 'KioskFleetWeb/KioskFleetWeb.psd1') -Force -DisableNameChecking

$script:AdminPass = 'Correct-Horse-42!'
$script:OpPass = 'Battery-Staple-77?'
$script:Servers = [Collections.Generic.List[object]]::new()
$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) "kfw-tests-$PID"

# --- asserts ----------------------------------------------------------------------------
function Assert-That($Condition, [string]$Message = 'expected it to hold') {
    if (-not $Condition) { throw "ASSERT: $Message" }
}

function ConvertTo-Canonical($Value) {
    # Dictionaries with their keys in order, so two compare by content.
    if ($Value -is [Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($k in (@($Value.Keys) | Sort-Object)) { $o[[string]$k] = ConvertTo-Canonical $Value[$k] }
        return $o
    }
    if ($Value -is [Collections.IList]) { return , @(foreach ($v in $Value) { ConvertTo-Canonical $v }) }
    return $Value
}

function Skip-Test([string]$Why) {
    # Not run here (not Windows, no Caddy): said so, not counted as passed.
    $e = [Exception]::new($Why)
    $e.Data['KfwSkip'] = $true
    throw $e
}

function Assert-Equal($Expected, $Actual, [string]$Message = '') {
    $e = ConvertTo-Json -InputObject (ConvertTo-Canonical $Expected) -Compress -Depth 10
    $a = ConvertTo-Json -InputObject (ConvertTo-Canonical $Actual) -Compress -Depth 10
    if ($e -cne $a) { throw "ASSERT: $Message expected $e, got $a" }
}

# --- a fleet of folders -----------------------------------------------------------------------
function New-TestWork {
    $dir = Join-Path $script:TestRoot ([guid]::NewGuid().ToString('N').Substring(0, 10))
    $root = Join-Path $dir 'kiosks'
    $data = Join-Path $dir 'data'
    [void][IO.Directory]::CreateDirectory($data)
    $dirs = New-KfwDemoKiosks $root
    $settings = New-KfwSettings
    $settings.DataDir = $data
    $settings.ShareTemplate = Join-KfwPath $root '{0}/Users/Public/Documents'
    $settings.Autoscan = $false
    $settings.RefreshSeconds = 1
    $settings.OfflineOk = $true
    $settings.ParallelHosts = 4
    $settings.HostTimeoutSeconds = 30
    return @{ Dir = $dir; Root = $root; Data = $data; Dirs = $dirs; Settings = $settings }
}

function Get-TestDocs($Work, [string]$HostName) { Get-KfwDemoDocs $Work.Root $HostName }

function Get-FreePort {
    $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop()
    return $p
}

function Start-TestServer {
    # The server in a process of its own, as it runs for real.
    #   -Fleet     the demo events in the CSV and the fake launcher playing
    #   -NoUsers   no accounts: the server makes a setup link
    #   -Env       KFW_* settings for this server
    param($Work, [switch]$Fleet, [switch]$NoUsers, [hashtable]$Env = @{})
    $port = Get-FreePort
    $psi = [Diagnostics.ProcessStartInfo]::new((Get-KfwPwshPath))
    foreach ($a in '-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'TestServer.ps1'), '-DataDir', $Work.Data, '-Root', $Work.Root, '-Port', $port) { $psi.ArgumentList.Add([string]$a) }
    if ($Fleet) { $psi.ArgumentList.Add('-Fleet') }
    if ($NoUsers) { $psi.ArgumentList.Add('-NoUsers') }
    $psi.Environment['KFW_SHARE'] = $Work.Settings.ShareTemplate
    $psi.Environment['KFW_AUTOSCAN'] = 'false'
    $psi.Environment['KFW_REFRESH_SECONDS'] = '1'
    $psi.Environment['KFW_PARALLEL_HOSTS'] = '4'
    $psi.Environment['KFW_HOST_TIMEOUT_SECONDS'] = '30'
    $psi.Environment['KFW_SETTINGS_JSON'] = $null
    foreach ($k in $Env.Keys) { $psi.Environment[$k] = [string]$Env[$k] }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $log = Join-Path $Work.Dir "server-$port.log"
    $proc = [Diagnostics.Process]::Start($psi)
    $out = $proc.StandardOutput.ReadToEndAsync()
    $err = $proc.StandardError.ReadToEndAsync()
    $srv = @{ Process = $proc; Port = $port; Base = "http://127.0.0.1:$port"; Work = $Work; Log = $log; Out = $out; Err = $err }
    $script:Servers.Add($srv)
    $c = [Net.Http.HttpClient]::new()
    $deadline = [datetime]::UtcNow.AddSeconds(60)
    while ([datetime]::UtcNow -lt $deadline) {
        if ($proc.HasExited) { throw "the test server stopped: $($out.Result) $($err.Result)" }
        try {
            $r = $c.GetAsync("$($srv.Base)/healthz").GetAwaiter().GetResult()
            if ($r.IsSuccessStatusCode) { $c.Dispose(); return $srv }
        } catch { }
        Start-Sleep -Milliseconds 200
    }
    throw 'the test server did not answer within 60 s'
}

function Stop-TestServer($Srv) {
    try { if (-not $Srv.Process.HasExited) { $Srv.Process.Kill($true) } } catch { }
    [void]$Srv.Process.WaitForExit(5000)
    try { [IO.File]::WriteAllText($Srv.Log, "$($Srv.Out.Result)`n$($Srv.Err.Result)") } catch { }
}

function Get-TestServerLog($Srv) {
    $p = Join-Path $Srv.Work.Data 'logs/server.log'
    if (Test-Path $p) { return Get-Content -Raw $p }
    return ''
}

function Stop-TestServers {
    foreach ($s in $script:Servers) { Stop-TestServer $s }
    $script:Servers.Clear()
}

# --- a person with a browser -----------------------------------------------------------------
function New-TestClient($Srv) {
    $h = [Net.Http.HttpClientHandler]::new()
    $h.CookieContainer = [Net.CookieContainer]::new()
    $h.UseCookies = $true
    $h.AllowAutoRedirect = $false
    $c = [Net.Http.HttpClient]::new($h)
    $c.Timeout = [timespan]::FromSeconds(120)
    return @{ Http = $c; Csrf = $null; Base = $Srv.Base; Srv = $Srv }
}

function Invoke-TestRequest {
    param($C, [string]$Method, [string]$Path, $Body = $null, [switch]$NoCsrf, [hashtable]$Headers = @{}, [hashtable]$Query = @{}, $Content = $null)
    $url = $C.Base + $Path
    if ($Query.Count) {
        $q = ($Query.Keys | ForEach-Object { [Uri]::EscapeDataString($_) + '=' + [Uri]::EscapeDataString([string]$Query[$_]) }) -join '&'
        $url += '?' + $q
    }
    $msg = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $url)
    if ($Content) { $msg.Content = $Content }
    elseif ($Method -ne 'GET') {
        $json = if ($null -ne $Body) { ConvertTo-Json -InputObject $Body -Depth 10 -Compress } else { '{}' }
        $msg.Content = [Net.Http.StringContent]::new($json, [Text.Encoding]::UTF8, 'application/json')
    }
    if (-not $NoCsrf -and $C.Csrf -and $Method -ne 'GET') { [void]$msg.Headers.TryAddWithoutValidation('X-Fleet-Csrf', $C.Csrf) }
    foreach ($k in $Headers.Keys) { [void]$msg.Headers.TryAddWithoutValidation($k, [string]$Headers[$k]) }
    $r = $C.Http.SendAsync($msg).GetAwaiter().GetResult()
    $bytes = $r.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    $json = $null
    if (([string]$r.Content.Headers.ContentType) -like 'application/json*') { try { $json = ConvertFrom-Json $text -AsHashtable -Depth 40 } catch { } }
    $hdr = @{}
    foreach ($h in $r.Headers) { $hdr[$h.Key.ToLowerInvariant()] = ($h.Value -join ', ') }
    foreach ($h in $r.Content.Headers) { $hdr[$h.Key.ToLowerInvariant()] = ($h.Value -join ', ') }
    return @{ Status = [int]$r.StatusCode; Text = $text; Json = $json; Headers = $hdr; Bytes = $bytes }
}

function Get-Test($C, [string]$Path, [hashtable]$Query = @{}) { Invoke-TestRequest $C GET $Path -Query $Query }
function Send-Test($C, [string]$Path, $Body = @{}, [switch]$NoCsrf, [hashtable]$Headers = @{}) { Invoke-TestRequest $C POST $Path $Body -NoCsrf:$NoCsrf -Headers $Headers }

function Connect-Test($C, [string]$User, [string]$Password) {
    $r = Send-Test $C '/api/login' @{ user = $User; password = $Password }
    if ($r.Status -eq 200) { $C.Csrf = $r.Json.csrf }
    return $r
}

function New-TestAdmin($Srv) {
    $c = New-TestClient $Srv
    $r = Connect-Test $c 'webadmin' $script:AdminPass
    Assert-Equal 200 $r.Status 'the admin signs in'
    return $c
}

function New-TestOperator($Srv) {
    $c = New-TestClient $Srv
    $r = Connect-Test $c 'webop' $script:OpPass
    Assert-Equal 200 $r.Status 'the operator signs in'
    return $c
}

function Invoke-TestJob($C, [string]$HostName, [string]$Action, $Body = @{}, [int]$Timeout = 30) {
    # Starts a kiosk action and waits for it: @(response, job or $null).
    $r = Send-Test $C "/api/kiosks/$HostName/$Action" $Body
    if ($r.Status -ne 202) { return @($r, $null) }
    $id = $r.Json.job
    $deadline = [datetime]::UtcNow.AddSeconds($Timeout)
    while ([datetime]::UtcNow -lt $deadline) {
        $j = (Get-Test $C "/api/jobs/$id").Json
        if ($j.done) { return @($r, $j) }
        Start-Sleep -Milliseconds 100
    }
    return @($r, $null)
}

function Wait-TestJobs($C, $Jobs, [int]$Timeout = 30) {
    $out = @{}
    $deadline = [datetime]::UtcNow.AddSeconds($Timeout)
    while ($out.Count -lt @($Jobs).Count -and [datetime]::UtcNow -lt $deadline) {
        foreach ($x in $Jobs) {
            if (-not $out.ContainsKey($x.host)) {
                $j = (Get-Test $C "/api/jobs/$($x.job)").Json
                if ($j.done) { $out[$x.host] = $j }
            }
        }
        Start-Sleep -Milliseconds 100
    }
    return $out
}

function Send-TestUpload($C, [string]$FileName, [byte[]]$Bytes) {
    $form = [Net.Http.MultipartFormDataContent]::new()
    $file = [Net.Http.ByteArrayContent]::new($Bytes)
    $form.Add($file, 'file', $FileName)
    Invoke-TestRequest $C POST '/api/settings/kiosk-list' -Content $form
}

function Get-TestAudit($C, [string]$Q = '') { @((Get-Test $C '/api/audit' @{ q = $Q }).Json.entries) }

function Set-TestText([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Text)
}
