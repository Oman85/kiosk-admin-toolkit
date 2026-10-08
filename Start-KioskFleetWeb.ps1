#Requires -Version 7.4
<#
.SYNOPSIS
    Kiosk Fleet Web: the server behind the page.

.DESCRIPTION
    Listens on 127.0.0.1:8081 (KFW_LISTEN) for Caddy in front of it, which does
    HTTPS and serves the page. Install-KioskFleetWeb.ps1 runs this at startup
    as a scheduled task; run it by hand to try it, or with -Demo for a
    pretend fleet. Settings are KFW_* variables, or kfw.env in the data folder.

    With no accounts yet, the log prints a one-time link (/setup?token=...)
    that makes the first admin account. It is also in setup-link.txt in the
    data folder until it is used.

.EXAMPLE
    .\Start-KioskFleetWeb.ps1 -Demo -DataDir .\data -Listen http://localhost:8080/
#>
[CmdletBinding()]
param(
    # The data folder: accounts, the audit log, the kiosk list, the events
    # CSV, logs. Default: KFW_DATA_DIR, or C:\ProgramData\KioskFleetWeb.
    [string]$DataDir,
    # Where to listen, e.g. http://localhost:8080/ to use it without Caddy.
    [string]$Listen,
    # A pretend fleet to try it on; nothing touches a real kiosk.
    [switch]$Demo
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'KioskFleetWeb\KioskFleetWeb.psd1') -Force
$settings = Get-KfwSettings -DataDir $DataDir
if ($Listen) { $settings.Listen = $Listen }
$demoOn = $Demo -or ([string]$env:KFW_DEMO).ToLowerInvariant() -in '1', 'true', 'yes'
Start-KfwServer -Settings $settings -Demo:$demoOn
