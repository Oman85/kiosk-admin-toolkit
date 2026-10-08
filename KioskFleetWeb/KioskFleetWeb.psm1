# Kiosk Fleet Web: every kiosk screen, and what can be done to it, in a
# browser. The server, the collector and the account tools are all this
# module; Start-KioskFleetWeb.ps1, Invoke-FleetScan.ps1 and
# Set-KioskFleetUser.ps1 next to it are how it is run.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

foreach ($part in 'TimeUtil', 'Csv', 'Config', 'Auth', 'Store', 'KioskFs', 'Remote', 'Launchers', 'LauncherOptions',
    'KioskList', 'ListEditor', 'Collector', 'FleetState', 'History', 'Screens', 'Actions', 'Services', 'Server', 'Api', 'Demo') {
    . (Join-Path $PSScriptRoot "Private\$part.ps1")
}

# Every function, so each runspace of the server's pools can call them by name.
Export-ModuleMember -Function *
