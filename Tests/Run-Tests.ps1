#Requires -Version 7.4
<#
.SYNOPSIS
    Runs the tests: every Test-* function in Tests\*.Tests.ps1.

.DESCRIPTION
    Nothing here touches a real kiosk or the network beyond 127.0.0.1.
    Kiosks are folders standing in for their Public Documents, with a thread
    playing their launchers and watchdog; each server test starts the real
    server in a process of its own.

.EXAMPLE
    ./Tests/Run-Tests.ps1
    ./Tests/Run-Tests.ps1 -Filter *Collector*, Test-History*
#>
[CmdletBinding()]
param(
    # Test names or file names to run (wildcards).
    [string[]]$Filter = @('*'),
    # Keep the test folders, to look at what a failed test left.
    [switch]$Keep
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestKit.ps1')

$files = Get-ChildItem (Join-Path $PSScriptRoot '*.Tests.ps1') | Sort-Object Name
foreach ($f in $files) { . $f.FullName }
$tests = foreach ($f in $files) {
    Get-Command -CommandType Function -Name 'Test-*' | Where-Object { $_.ScriptBlock.File -eq $f.FullName } |
        Where-Object { $n = $_.Name; $file = $f.BaseName; @($Filter | Where-Object { $n -like $_ -or $file -like "$_*" }).Count } |
        Sort-Object { $_.ScriptBlock.StartPosition.StartLine } | ForEach-Object { @{ Name = $_.Name; File = $f.BaseName } }
}

$failed = [Collections.Generic.List[string]]::new()
$sw = [Diagnostics.Stopwatch]::StartNew()
foreach ($t in $tests) {
    $one = [Diagnostics.Stopwatch]::StartNew()
    try {
        & $t.Name
        Write-Host ('  ok    {0,-58} {1,5:N1}s' -f "$($t.File)::$($t.Name)", $one.Elapsed.TotalSeconds)
    } catch {
        $failed.Add("$($t.File)::$($t.Name)")
        Write-Host ('  FAIL  {0,-58} {1,5:N1}s' -f "$($t.File)::$($t.Name)", $one.Elapsed.TotalSeconds) -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "        $($_.ScriptStackTrace -split "`n" | Select-Object -First 3)" -ForegroundColor DarkGray
        foreach ($s in $script:Servers) {
            $log = Get-TestServerLog $s
            $errs = @($log -split "`n" | Where-Object { $_ -match 'ERROR|background:|job ' })
            if ($errs.Count) { Write-Host ('        server: ' + ($errs -join "`n        server: ")) -ForegroundColor DarkYellow }
        }
    } finally {
        Stop-TestServers
    }
}
Write-Host ''
Write-Host ("{0} tests, {1} failed, {2:N0}s" -f @($tests).Count, $failed.Count, $sw.Elapsed.TotalSeconds)
if (-not $Keep) { try { Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
if ($failed.Count) { $failed | ForEach-Object { Write-Host "  failed: $_" -ForegroundColor Red }; exit 1 }
exit 0
