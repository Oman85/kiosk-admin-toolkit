# A server for the tests: the accounts webadmin and webop, with -Fleet the
# demo events and the fake launcher playing the kiosks under -Root.
param([string]$DataDir, [string]$Root, [int]$Port, [switch]$Fleet, [switch]$NoUsers)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../KioskFleetWeb/KioskFleetWeb.psd1') -Force -DisableNameChecking
$settings = Get-KfwSettings -DataDir $DataDir
$settings.Listen = "http://127.0.0.1:$Port/"
$settings.OfflineOk = $true
Initialize-KfwDirs $settings
if (-not $NoUsers) {
    $st = Open-KfwStore $DataDir
    if (-not (Get-KfwUser $st 'webadmin')) {
        Add-KfwUser $st 'webadmin' 'admin' 'Correct-Horse-42!'
        Add-KfwUser $st 'webop' 'operator' 'Battery-Staple-77?'
    }
}
if ($Fleet) {
    $csv = Get-KfwLocalCsv $settings
    if (-not (Test-Path $csv)) { Write-KfwDemoEvents $csv }
    $dirs = @{ ng = Join-KfwPath (Get-KfwDemoDocs $Root 'MWEB1') 'Mach2LauncherNG/S1'; pbi = Join-KfwPath (Get-KfwDemoDocs $Root 'PWEB1') 'PbiLauncher' }
    [void](Start-KfwFakeLauncherThread $Root $dirs)
}
Start-KfwServer -Settings $settings
