#Requires -Version 7.4
<#
.SYNOPSIS
    One scan of the kiosk fleet, as Scan now and auto-scan run it.

.DESCRIPTION
    Reads every kiosk on the list and merges what it finds into
    MWST_FleetEvents.csv (and KFW_PUBLISH_CSV) and its .status.json. The
    server runs scans itself; this is for a scan from the command line.
    Exit code 0, or 1 when something could not be read or written.

.EXAMPLE
    .\Invoke-FleetScan.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$DataDir,
    # Read everything, write nothing.
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'KioskFleetWeb\KioskFleetWeb.psd1') -Force
$code = Invoke-KfwScan -Settings (Get-KfwSettings -DataDir $DataDir) -DryRun:$DryRun
# Straight out: a thread still waiting on a kiosk that hung is not waited for.
[Environment]::Exit($code)
