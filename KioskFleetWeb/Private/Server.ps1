# The server: an HttpListener on 127.0.0.1 (Caddy in front of it does HTTPS
# and serves the page), each request answered on a thread of a runspace pool.
# Every thread imports this module; what they share - settings, accounts, the
# fleet as last read, kiosk jobs, the scan - is the synchronized $App.

$script:ModuleManifest = Join-Path (Split-Path -Parent $PSScriptRoot) 'KioskFleetWeb.psd1'
$script:LogLock = [object]::new()
$script:Version = '2.0.0'

function Write-KfwLog([string]$Message) {
    # The console, and logs\server.log: the scheduled task has no console.
    $line = "[$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture))] $Message"
    [Threading.Monitor]::Enter($script:LogLock)
    try {
        [Console]::Out.WriteLine($line)
        if ($script:App -and $script:App.LogPath) {
            try {
                $p = $script:App.LogPath
                if ([IO.File]::Exists($p) -and ([IO.FileInfo]::new($p)).Length -ge 5MB) { [IO.File]::Move($p, "$p.1", $true) }
                [IO.File]::AppendAllText($p, $line + [Environment]::NewLine)
            } catch { }
        }
    } finally { [Threading.Monitor]::Exit($script:LogLock) }
}

function Set-KfwContext($App) {
    # Each thread's view of the shared state.
    $script:App = $App
    $script:S = $App.Settings
    $script:St = $App.Store
}

function New-KfwRunspacePool([int]$Max) {
    $iss = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
    if ($IsWindows) { $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass }
    $iss.ImportPSModule($script:ModuleManifest)
    $pool = [runspacefactory]::CreateRunspacePool(1, $Max, $iss, $Host)
    $pool.Open()
    return $pool
}

function Invoke-KfwInBackground($Pool, [string]$Command, [object[]]$Arguments) {
    # Runs a module function on a pool thread. The caller keeps the handle
    # for Complete-KfwBackground.
    $ps = [powershell]::Create()
    $ps.RunspacePool = $Pool
    [void]$ps.AddCommand($Command)
    foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
    return @{ PS = $ps; Handle = $ps.BeginInvoke() }
}

function Complete-KfwBackground($Work, [switch]$Wait) {
    if (-not $Wait -and -not $Work.Handle.IsCompleted) { return $false }
    try {
        [void]$Work.PS.EndInvoke($Work.Handle)
        foreach ($e in $Work.PS.Streams.Error) { Write-KfwLog "background: $e" }
    } catch {
        Write-KfwLog "background: $($_.Exception.InnerException.Message ?? $_.Exception.Message)"
    } finally {
        $Work.PS.Dispose()
    }
    return $true
}

function Start-KfwServer {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings, [switch]$Demo, [switch]$NoBackground)

    $App = New-KfwApp $Settings
    Set-KfwContext $App
    if ($Demo) { Start-KfwDemo $App }
    Initialize-KfwApp $App -Background:(-not $NoBackground)

    $listener = [Net.HttpListener]::new()
    foreach ($p in ([string]$Settings.Listen).Split(',', [StringSplitOptions]::RemoveEmptyEntries)) {
        $prefix = $p.Trim()
        if (-not $prefix.EndsWith('/')) { $prefix += '/' }
        $listener.Prefixes.Add($prefix)
    }
    try {
        $listener.Start()
    } catch {
        throw "Could not listen on $($Settings.Listen): $($_.Exception.Message)$(if ($IsWindows) { ' (as a service account, the installer adds the URL reservation: netsh http add urlacl)' })"
    }
    $App.RequestPool = New-KfwRunspacePool $Settings.RequestThreads
    Write-KfwLog "Kiosk Fleet Web $script:Version listening on $($Settings.Listen) (data in $($Settings.DataDir))."
    Write-KfwAudit $App.Store -Action 'server-start' -Result 'ok' -Detail "Kiosk Fleet Web $script:Version"

    $pending = [Collections.Generic.List[object]]::new()
    try {
        while (-not $App.Stopping) {
            $task = $listener.GetContextAsync()
            while (-not $task.Wait(250)) {
                for ($i = $pending.Count - 1; $i -ge 0; $i--) { if (Complete-KfwBackground $pending[$i]) { $pending.RemoveAt($i) } }
                if ($App.Stopping) { break }
            }
            if ($App.Stopping) { break }
            $ctx = $task.GetAwaiter().GetResult()
            $pending.Add((Invoke-KfwInBackground $App.RequestPool 'Invoke-KfwRequest' @($App, $ctx)))
            for ($i = $pending.Count - 1; $i -ge 0; $i--) { if (Complete-KfwBackground $pending[$i]) { $pending.RemoveAt($i) } }
        }
    } finally {
        $App.Stopping = $true
        Write-KfwAudit $App.Store -Action 'server-stop' -Result 'ok'
        Save-KfwSessions $App.Store
        try { $listener.Stop(); $listener.Close() } catch { }
        Stop-KfwApp $App
        Write-KfwLog 'Stopped.'
    }
}

# --- one request --------------------------------------------------------------------
$script:MaxBody = 256KB
$script:MaxUpload = 10MB + 64KB
$script:Csp = "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"

function Stop-KfwRequest([int]$Status, [string]$Message) {
    # Ends the request with {"error": message} and this status.
    $e = [Exception]::new($Message)
    $e.Data['KfwStatus'] = $Status
    throw $e
}

function New-KfwResponse([int]$Status = 200, [string]$ContentType = 'application/json', [byte[]]$Body = @(), [hashtable]$Headers = @{}) {
    @{ Status = $Status; ContentType = $ContentType; Body = $Body; Headers = $Headers; Cookies = [Collections.Generic.List[string]]::new() }
}

function ConvertTo-KfwJson($Value) {
    if ($null -eq $Value) { return 'null' }
    ConvertTo-Json -InputObject $Value -Depth 40 -Compress
}

function New-KfwJsonResponse($Value, [int]$Status = 200) {
    New-KfwResponse -Status $Status -Body ([Text.Encoding]::UTF8.GetBytes((ConvertTo-KfwJson $Value)))
}

function New-KfwRawJsonResponse([string]$Json, [int]$Status = 200) {
    New-KfwResponse -Status $Status -Body ([Text.Encoding]::UTF8.GetBytes($Json))
}

function Get-KfwRequest($Ctx) {
    $r = $Ctx.Request
    $raw = [string]$r.RawUrl
    $q = $raw.IndexOf('?')
    $path = if ($q -ge 0) { $raw.Substring(0, $q) } else { $raw }
    # (Assigned straight, not from an if: the collection would be unrolled.)
    $query = [Web.HttpUtility]::ParseQueryString($(if ($q -ge 0) { $raw.Substring($q + 1) } else { '' }))
    $segments = [Collections.Generic.List[string]]::new()
    foreach ($seg in $path.Split('/')) { if ($seg -ne '') { $segments.Add([Uri]::UnescapeDataString($seg)) } }
    $addr = $r.RemoteEndPoint.Address
    if ($addr.IsIPv4MappedToIPv6) { $addr = $addr.MapToIPv4() }
    $cookies = @{}
    foreach ($part in ([string]$r.Headers['Cookie']).Split(';')) {
        $i = $part.IndexOf('=')
        if ($i -gt 0) { $cookies[$part.Substring(0, $i).Trim()] = $part.Substring($i + 1).Trim() }
    }
    return @{
        Method = $r.HttpMethod; Path = $path; Segments = $segments; Query = $query; Headers = $r.Headers
        Cookies = $cookies; RemoteAddress = $addr; Raw = $r; BodyBytes = $null
    }
}

function Read-KfwBodyBytes($Req, [long]$Limit) {
    if ($null -ne $Req.BodyBytes) { return , $Req.BodyBytes }
    $r = $Req.Raw
    if ($r.ContentLength64 -gt $Limit) { Stop-KfwRequest 413 'too large' }
    $ms = [IO.MemoryStream]::new()
    $buf = [byte[]]::new(65536)
    while (($n = $r.InputStream.Read($buf, 0, $buf.Length)) -gt 0) {
        $ms.Write($buf, 0, $n)
        if ($ms.Length -gt $Limit) { Stop-KfwRequest 413 'too large' }
    }
    $Req.BodyBytes = $ms.ToArray()
    return , $Req.BodyBytes
}

function Read-KfwJsonBody($Req) {
    $raw = Read-KfwBodyBytes $Req ($script:MaxBody + 1)
    if ($raw.Length -eq 0) { return @{} }
    if ($raw.Length -gt $script:MaxBody) { Stop-KfwRequest 400 'too large' }
    if (-not ([string]$Req.Headers['Content-Type']).StartsWith('application/json')) { Stop-KfwRequest 400 'send JSON' }
    try {
        $data = ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($raw)) -AsHashtable -Depth 20
    } catch {
        Stop-KfwRequest 400 'that is not JSON'
    }
    if ($data -isnot [Collections.IDictionary]) { Stop-KfwRequest 400 'send a JSON object' }
    return $data
}

function Read-KfwUpload($Req, [string]$Field = 'file') {
    # One file from a multipart/form-data body: @{ FileName; Bytes } or $null.
    $ct = [string]$Req.Headers['Content-Type']
    $m = [regex]::Match($ct, 'boundary=(?:"([^"]+)"|([^;\s]+))')
    if (-not $ct.StartsWith('multipart/form-data') -or -not $m.Success) { Stop-KfwRequest 400 'send the file as multipart/form-data' }
    $boundary = '--' + ($m.Groups[1].Value + $m.Groups[2].Value)
    $raw = Read-KfwBodyBytes $Req $script:MaxUpload
    # Latin-1 maps every byte to one char and back, so the file's bytes survive.
    $latin = [Text.Encoding]::Latin1
    $text = $latin.GetString($raw)
    $pos = 0
    while (($start = $text.IndexOf($boundary, $pos, [StringComparison]::Ordinal)) -ge 0) {
        $headEnd = $text.IndexOf("`r`n`r`n", $start, [StringComparison]::Ordinal)
        if ($headEnd -lt 0) { break }
        $head = $text.Substring($start, $headEnd - $start)
        $next = $text.IndexOf("`r`n" + $boundary, $headEnd + 4, [StringComparison]::Ordinal)
        if ($next -lt 0) { break }
        # A browser quotes the names; .NET's HttpClient does not.
        $nm = [regex]::Match($head, '; name="?([^";\r\n]*)"?')
        if ($nm.Success -and $nm.Groups[1].Value -eq $Field) {
            $fm = [regex]::Match($head, '; filename="?([^";\r\n]*)"?')
            $bodyText = $text.Substring($headEnd + 4, $next - $headEnd - 4)
            $name = if ($fm.Success) { [Text.Encoding]::UTF8.GetString($latin.GetBytes($fm.Groups[1].Value)) } else { '' }
            return @{ FileName = $name; Bytes = $latin.GetBytes($bodyText) }
        }
        $pos = $next + 2
    }
    return $null
}

function Test-KfwFromProxy($Req) {
    [bool]($script:S.TrustProxy -and [Net.IPAddress]::IsLoopback($Req.RemoteAddress))
}

function Test-KfwHttps($Req) {
    if (Test-KfwFromProxy $Req) {
        $proto = ([string]$Req.Headers['X-Forwarded-Proto']).Split(',')[0].Trim().ToLowerInvariant()
        if ($proto) { return $proto -eq 'https' }
    }
    return [bool]$Req.Raw.IsSecureConnection
}

function Get-KfwClientIp($Req) {
    if (Test-KfwFromProxy $Req) {
        $fwd = [string]$Req.Headers['X-Forwarded-For']
        if ($fwd) { return $fwd.Split(',')[0].Trim() }
    }
    return $Req.RemoteAddress.ToString()
}

function Test-KfwLocalClient($Req) {
    $ip = $null
    if ([Net.IPAddress]::TryParse((Get-KfwClientIp $Req), [ref]$ip)) { return [Net.IPAddress]::IsLoopback($ip) }
    return $false
}

function Test-KfwSameOrigin($Req) {
    $origin = [string]$Req.Headers['Origin']
    if (-not $origin) { return $true }
    $hostName = [string]$Req.Headers['Host']
    if ((Test-KfwFromProxy $Req) -and $Req.Headers['X-Forwarded-Host']) { $hostName = [string]$Req.Headers['X-Forwarded-Host'] }
    $m = [regex]::Match($origin.Trim(), '^https?://([^/]+)$')
    return $m.Success -and $m.Groups[1].Value.ToLowerInvariant() -eq $hostName.Split(',')[0].Trim().ToLowerInvariant()
}

function Write-KfwResponse($Ctx, $Req, $Resp) {
    $out = $Ctx.Response
    try {
        $out.StatusCode = $Resp.Status
        $h = $Resp.Headers
        foreach ($pair in @(
                @('X-Content-Type-Options', 'nosniff'), @('X-Frame-Options', 'DENY'), @('Referrer-Policy', 'no-referrer'),
                @('Content-Security-Policy', $script:Csp), @('Cache-Control', 'no-store'))) {
            if (-not $h.ContainsKey($pair[0])) { $h[$pair[0]] = $pair[1] }
        }
        if ($Req -and (Test-KfwHttps $Req) -and -not $h.ContainsKey('Strict-Transport-Security')) { $h['Strict-Transport-Security'] = 'max-age=31536000' }
        foreach ($k in $h.Keys) { $out.Headers[$k] = [string]$h[$k] }
        foreach ($c in $Resp.Cookies) { $out.Headers.Add('Set-Cookie', $c) }
        $out.ContentType = $Resp.ContentType
        $body = [byte[]]$Resp.Body
        $out.ContentLength64 = $body.Length
        if ($body.Length -and $Req.Method -ne 'HEAD') { $out.OutputStream.Write($body, 0, $body.Length) }
    } catch {
        # The browser went away.
    } finally {
        try { $out.Close() } catch { }
    }
}

function Invoke-KfwRequest($App, $Ctx) {
    Set-KfwContext $App
    $req = $null
    try {
        $req = Get-KfwRequest $Ctx
        $resp = Invoke-KfwRoute $req
    } catch {
        $ex = $_.Exception
        while ($ex -and -not $ex.Data.Contains('KfwStatus') -and $ex.InnerException) { $ex = $ex.InnerException }
        if ($ex -and $ex.Data.Contains('KfwStatus')) {
            $resp = New-KfwJsonResponse @{ error = $ex.Message } ([int]$ex.Data['KfwStatus'])
        } else {
            Write-KfwLog "ERROR $($Ctx.Request.HttpMethod) $($Ctx.Request.RawUrl): $($_.Exception.Message) $($_.ScriptStackTrace -replace "`n", ' <- ')"
            $resp = New-KfwJsonResponse @{ error = 'Something went wrong on the server; it is in its log.' } 500
        }
    }
    Write-KfwResponse $Ctx $req $resp
}
