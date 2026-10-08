#Requires -Version 7.4
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Keeps the account that opens the kiosks' shares, encrypted for this server.

.DESCRIPTION
    Only needed when the server should not open the shares as the account it
    runs as. Writes share.cred in the data folder: the account's name, and its
    password encrypted with DPAPI for this computer, which only this server can
    read - and the data folder's permissions keep everyone but administrators
    and the service account out. Then restarts the server so it takes it.

    -Remove deletes it: the shares are opened as the service account again.

.EXAMPLE
    .\Save-KioskShareCredential.ps1 -User 'CONTOSO\svc-kioskshare'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, ParameterSetName = 'Save')][string]$User,
    [Parameter(ParameterSetName = 'Save')][securestring]$Password,
    [Parameter(Mandatory, ParameterSetName = 'Remove')][switch]$Remove,
    [string]$DataDir
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'KioskFleetWeb\KioskFleetWeb.psd1') -Force -DisableNameChecking
if (-not $IsWindows) { throw 'The share account is kept with Windows DPAPI. On Linux, mount the shares with their account and set KFW_SHARE to the mounted folder.' }
if (-not $DataDir) { $DataDir = if ($env:KFW_DATA_DIR) { $env:KFW_DATA_DIR } else { Get-KfwDefaultDataDir } }
$path = Join-Path $DataDir 'share.cred'
if ($Remove) {
    if (Test-Path $path) { Remove-Item $path }
    'The share account is removed; the kiosks are opened as the account the server runs as.'
} else {
    if (-not $Password) { $Password = Read-Host "Password for $User" -AsSecureString }
    $plain = [Net.NetworkCredential]::new('', $Password).Password
    [IO.File]::WriteAllText($path, (ConvertTo-Json ([ordered]@{ User = $User; Password = Protect-KfwText $plain })))
    "Saved: the kiosks are opened as $User."
}
if (Get-ScheduledTask -TaskName 'Kiosk Fleet Web' -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName 'Kiosk Fleet Web'
    Start-Sleep -Seconds 2
    Start-ScheduledTask -TaskName 'Kiosk Fleet Web'
    'The server is restarted.'
}
