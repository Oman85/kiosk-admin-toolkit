#Requires -Version 7.4
<#
.SYNOPSIS
    Checks a Kiosk Fleet Web that Install-KioskFleetWeb.ps1 installed, through
    Caddy, as a browser would use it: the task and the service run, the page
    comes with its headers, an admin signs in, the fleet is there, a kiosk
    action and a scan go through.

.EXAMPLE
    ./Tests/Test-Installed.ps1 -SiteAddress https://localhost -User admin -Password '...'
#>
param(
    [Parameter(Mandatory)][string]$SiteAddress,
    [Parameter(Mandatory)][string]$User,
    [Parameter(Mandatory)][string]$Password
)
$ErrorActionPreference = 'Stop'
$base = $SiteAddress.TrimEnd('/')
$fail = 0
function Check([string]$What, [scriptblock]$Test) {
    try {
        $r = & $Test
        if ($r -eq $false) { throw 'no' }
        Write-Host "  ok    $What"
    } catch {
        $script:fail++
        Write-Host "  FAIL  $What - $($_.Exception.Message)" -ForegroundColor Red
    }
}
$h = [Net.Http.HttpClientHandler]::new()
$h.ServerCertificateCustomValidationCallback = [Net.Http.HttpClientHandler]::DangerousAcceptAnyServerCertificateValidator
$h.CookieContainer = [Net.CookieContainer]::new()
$http = [Net.Http.HttpClient]::new($h)
$csrf = $null
function Call([string]$Method, [string]$Path, $Body = $null) {
    $m = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), "$base$Path")
    if ($Method -ne 'GET') {
        $m.Headers.Add('Origin', $base)
        if ($script:csrf) { $m.Headers.Add('X-Fleet-Csrf', $script:csrf) }
        $m.Content = [Net.Http.StringContent]::new((ConvertTo-Json -InputObject $(if ($null -ne $Body) { $Body } else { @{} }) -Compress -Depth 5), [Text.Encoding]::UTF8, 'application/json')
    }
    $r = $http.SendAsync($m).GetAwaiter().GetResult()
    $t = $r.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $j = $null; try { $j = ConvertFrom-Json $t -AsHashtable -Depth 40 } catch { }
    return @{ Status = [int]$r.StatusCode; Json = $j; Text = $t; Headers = $r.Headers }
}

if ($IsWindows) {
    Check 'the scheduled task runs' { (Get-ScheduledTask -TaskName 'Kiosk Fleet Web').State -eq 'Running' }
    Check 'the Caddy service runs' { (Get-Service KioskFleetCaddy).Status -eq 'Running' }
}
Check 'healthz, with the fleet read' { $r = Call GET '/healthz'; $r.Status -eq 200 -and $r.Json.fleet }
Check 'the page, with its headers' {
    $r = $http.GetAsync("$base/").GetAwaiter().GetResult()
    $r.StatusCode -eq 200 -and $r.Headers.Contains('Strict-Transport-Security') -and $r.Content.Headers.ContentType.MediaType -eq 'text/html'
}
Check 'signing in' { $r = Call POST '/api/login' @{ user = $User; password = $Password }; $script:csrf = $r.Json.csrf; $r.Status -eq 200 -and $r.Json.role -eq 'admin' -and -not $r.Json.insecure }
Check 'the fleet' { $r = Call GET '/api/state'; $r.Status -eq 200 -and $r.Json.fleet.Total -ge 7 }
Check 'a kiosk action' {
    $r = Call POST '/api/kiosks/MWEB1/reload' @{ screen = 'S1'; kind = 'NG' }
    if ($r.Status -ne 202) { throw $r.Text }
    $deadline = [datetime]::UtcNow.AddSeconds(30)
    do { Start-Sleep -Milliseconds 300; $j = (Call GET "/api/jobs/$($r.Json.job)").Json } while (-not $j.done -and [datetime]::UtcNow -lt $deadline)
    if (-not $j.ok) { throw (ConvertTo-Json $j -Compress) }
}
Check 'a scan' {
    $r = Call POST '/api/scan'
    if ($r.Status -ne 202) { throw $r.Text }
    $deadline = [datetime]::UtcNow.AddSeconds(120)
    do { Start-Sleep -Seconds 1; $run = (Call GET '/api/run?from=0').Json } while ($run.running -and [datetime]::UtcNow -lt $deadline)
    if (-not $run.last -or $run.last.Code -ne 0) { throw $run.text }
}
Check 'the audit log' { $r = Call GET '/api/audit'; @($r.Json.entries | Where-Object { $_.Action -eq 'scan-finished' }).Count -ge 1 }
Write-Host ''
if ($fail) { Write-Host "$fail check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'Installed and working.' -ForegroundColor Green
