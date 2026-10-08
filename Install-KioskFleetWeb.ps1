#Requires -Version 7.4
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs Kiosk Fleet Web on this Windows server: the PowerShell server as a
    startup task, and Caddy in front of it as a Windows service.

.DESCRIPTION
    Run it from the unpacked repository, in PowerShell 7 as an administrator.
    It is safe to run again: to update, or to change a setting given here.

      - copies the app to -InstallDir (C:\Program Files\KioskFleetWeb)
      - makes the data folder (-DataDir, C:\ProgramData\KioskFleetWeb), open to
        administrators, SYSTEM and the service account only, and writes the
        settings given here into kfw.env there
      - reserves http://127.0.0.1:8081/ for the service account (netsh http
        urlacl) and registers the scheduled task "Kiosk Fleet Web", which runs
        Start-KioskFleetWeb.ps1 at startup as -ServiceAccount, restarting it
        if it stops
      - fetches Caddy (or takes -CaddyExe), writes its Caddyfile and registers
        it as the service "KioskFleetCaddy", as NETWORK SERVICE, automatic,
        restarting on failure; opens 80 and 443 for it in the firewall
      - makes the first admin account (-AdminUser), or leaves the one-time
        setup link in setup-link.txt in the data folder

    The account the server runs as is also the account that opens the kiosks'
    shares, unless a share account is given (-ShareUser). NETWORK SERVICE
    reaches the network as this computer's account (DOMAIN\SERVER$); a gMSA
    (DOMAIN\svc-kioskfleet$) is the usual choice.

.EXAMPLE
    .\Install-KioskFleetWeb.ps1 -Demo -AdminUser admin
    Tries it out on a pretend fleet, at https://<this server> with a
    certificate Caddy makes itself.

.EXAMPLE
    .\Install-KioskFleetWeb.ps1 -SiteAddress https://kiosks.contoso.local -CertificateFile .\kiosks.crt -KeyFile .\kiosks.key `
        -ServiceAccount 'CONTOSO\svc-kioskfleet$' -ShareTemplate '\\{0}\KioskDocs' -SiteName 'CZECH DIVISION - Nyrany'

.EXAMPLE
    .\Install-KioskFleetWeb.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:ProgramFiles 'KioskFleetWeb'),
    [string]$DataDir = (Join-Path $env:ProgramData 'KioskFleetWeb'),
    # Where people open it: https://kiosks.contoso.local. Default: https:// and
    # this server's DNS name.
    [string]$SiteAddress,
    # The certificate and its key (PEM) from your CA, for -SiteAddress. Without
    # them Caddy makes its own, which browsers trust only once its root (in the
    # data folder, caddy\pki\authorities\local\root.crt) is trusted.
    [string]$CertificateFile,
    [string]$KeyFile,
    # No HTTPS at all: for trying it out on a closed network only.
    [switch]$HttpOnly,
    # The account the server runs as, and opens the kiosks' shares as: a gMSA
    # (DOMAIN\name$), a domain account (with -ServiceAccountPassword), or
    # NT AUTHORITY\NETWORK SERVICE.
    [string]$ServiceAccount = 'NT AUTHORITY\NETWORK SERVICE',
    [securestring]$ServiceAccountPassword,
    # Each kiosk's Public Documents; {0} is its name. Default: the admin share,
    # \\{0}\C$\Users\Public\Documents.
    [string]$ShareTemplate,
    # A separate account for the shares, kept encrypted for this server (DPAPI).
    [string]$ShareUser,
    [securestring]$SharePassword,
    # Shown under the name on the sign-in page.
    [string]$SiteName,
    # The first admin account. Without it, the setup link in setup-link.txt.
    [string]$AdminUser,
    [securestring]$AdminPassword,
    # A caddy.exe already here; otherwise it is downloaded from GitHub and its
    # SHA-512 checked.
    [string]$CaddyExe,
    [string]$CaddyVersion = '2.8.4',
    [int]$BackendPort = 8081,
    # A pretend fleet to try it on; nothing touches a real kiosk.
    [switch]$Demo,
    [switch]$Uninstall,
    # With -Uninstall: the data folder too - accounts, the audit log, the events CSV.
    [switch]$RemoveData
)
$ErrorActionPreference = 'Stop'
$TaskName = 'Kiosk Fleet Web'
$CaddyService = 'KioskFleetCaddy'
$FirewallRule = 'KioskFleetWeb-Caddy'
if (-not $IsWindows) { throw 'Install-KioskFleetWeb.ps1 sets up a Windows server. On Linux, run Start-KioskFleetWeb.ps1 under systemd and Caddy as its own service.' }

function Say([string]$Text) { Write-Host "  $Text" }
function Step([string]$Text) { Write-Host ''; Write-Host $Text -ForegroundColor Cyan }

function Remove-Everything([switch]$KeepData) {
    Step 'Removing Kiosk Fleet Web'
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Say "scheduled task '$TaskName' removed"
    }
    if (Get-Service $CaddyService -ErrorAction SilentlyContinue) {
        Stop-Service $CaddyService -Force -ErrorAction SilentlyContinue
        Remove-Service $CaddyService
        Say "service $CaddyService removed"
    }
    & netsh.exe http delete urlacl url="http://127.0.0.1:$BackendPort/" | Out-Null
    Get-NetFirewallRule -Name $FirewallRule -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force; Say "removed $InstallDir" }
    if (-not $KeepData -and (Test-Path $DataDir)) { Remove-Item $DataDir -Recurse -Force; Say "removed $DataDir" }
    elseif (Test-Path $DataDir) { Say "kept $DataDir (accounts, audit log, events CSV); -RemoveData removes it" }
    [Environment]::SetEnvironmentVariable('KFW_DATA_DIR', $null, 'Machine')
}

if ($Uninstall) {
    Remove-Everything -KeepData:(-not $RemoveData)
    return
}

# --- what is asked for -------------------------------------------------------------------------
if ($PSVersionTable.PSVersion -lt [version]'7.4') { throw 'PowerShell 7.4 or later is needed: winget install Microsoft.PowerShell' }
if (($CertificateFile -or $KeyFile) -and -not ($CertificateFile -and $KeyFile)) { throw 'Give both -CertificateFile and -KeyFile.' }
if ($ShareUser -and -not $SharePassword) { $SharePassword = Read-Host "Password for $ShareUser" -AsSecureString }
if ($AdminUser -and -not $AdminPassword) { $AdminPassword = Read-Host "Password for the admin account $AdminUser" -AsSecureString }
if (-not $SiteAddress) {
    $fqdn = try { [Net.Dns]::GetHostEntry([Environment]::MachineName).HostName } catch { [Environment]::MachineName }
    $SiteAddress = "$(if ($HttpOnly) { 'http' } else { 'https' })://$($fqdn.ToLowerInvariant())"
}
$SiteAddress = $SiteAddress.TrimEnd('/')
if ($HttpOnly -and -not $SiteAddress.StartsWith('http://')) { throw '-HttpOnly needs an http:// -SiteAddress.' }
$source = $PSScriptRoot
$plain = { param([securestring]$s) [Net.NetworkCredential]::new('', $s).Password }

# --- the files -------------------------------------------------------------------------------------
Step "Installing to $InstallDir"
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    # The task's pwsh, if it outlived the task.
    Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" | Where-Object { $_.CommandLine -like '*Start-KioskFleetWeb.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
if ([IO.Path]::GetFullPath($source).TrimEnd('\') -ne [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')) {
    if (Test-Path (Join-Path $InstallDir 'KioskFleetWeb')) { Remove-Item (Join-Path $InstallDir 'KioskFleetWeb') -Recurse -Force }
    [void](New-Item -ItemType Directory -Force $InstallDir)
    foreach ($item in 'KioskFleetWeb', 'deploy', 'docs', 'Start-KioskFleetWeb.ps1', 'Invoke-FleetScan.ps1', 'Set-KioskFleetUser.ps1',
        'Save-KioskShareCredential.ps1', 'Install-KioskFleetWeb.ps1', 'README.md', 'LICENSE') {
        $p = Join-Path $source $item
        if (Test-Path $p) { Copy-Item $p $InstallDir -Recurse -Force }
    }
    Say 'copied'
}
Get-ChildItem $InstallDir -Recurse -File | Unblock-File
Import-Module (Join-Path $InstallDir 'KioskFleetWeb\KioskFleetWeb.psd1') -Force -DisableNameChecking

# --- the data folder ----------------------------------------------------------------------------------
Step "Data in $DataDir"
foreach ($d in $DataDir, (Join-Path $DataDir 'caddy'), (Join-Path $DataDir 'tls'), (Join-Path $DataDir 'logs')) { [void](New-Item -ItemType Directory -Force $d) }
$acct = { param([string]$n) [Security.Principal.NTAccount]::new($n) }
$rule = { param([string]$who, [string]$rights) [Security.AccessControl.FileSystemAccessRule]::new((& $acct $who), $rights, 'ContainerInherit, ObjectInherit', 'None', 'Allow') }
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
$acl.AddAccessRule((& $rule 'BUILTIN\Administrators' 'FullControl'))
$acl.AddAccessRule((& $rule 'NT AUTHORITY\SYSTEM' 'FullControl'))
$acl.AddAccessRule((& $rule $ServiceAccount 'Modify'))
Set-Acl -Path $DataDir -AclObject $acl
# Caddy runs as NETWORK SERVICE: its own folder, and the certificate.
foreach ($pair in @(@('caddy', 'Modify'), @('tls', 'ReadAndExecute'), @('logs', 'Modify'))) {
    $a = Get-Acl (Join-Path $DataDir $pair[0])
    $a.AddAccessRule((& $rule 'NT AUTHORITY\NETWORK SERVICE' $pair[1]))
    Set-Acl -Path (Join-Path $DataDir $pair[0]) -AclObject $a
}
Say "open to administrators, SYSTEM and $ServiceAccount"
[Environment]::SetEnvironmentVariable('KFW_DATA_DIR', $DataDir, 'Machine')

# kfw.env: what is given here, over what was there.
$envFile = Join-Path $DataDir 'kfw.env'
$values = [ordered]@{}
if (Test-Path $envFile) { $old = Read-KfwEnvFile $envFile; foreach ($k in $old.Keys) { $values[$k] = $old[$k] } }
$values['KFW_LISTEN'] = "http://127.0.0.1:$BackendPort/"
if ($ShareTemplate) { $values['KFW_SHARE'] = $ShareTemplate }
if ($SiteName) { $values['KFW_SITE_NAME'] = $SiteName }
if ($Demo) { $values['KFW_DEMO'] = '1' } else { $values.Remove('KFW_DEMO') }
$lines = @('# Kiosk Fleet Web settings: KFW_* as in the README. Environment variables win over these.',
    '# Install-KioskFleetWeb.ps1 keeps what is here and changes what it is given.')
foreach ($k in $values.Keys) { $lines += "$k=$($values[$k])" }
[IO.File]::WriteAllLines($envFile, $lines)
Say "settings in $envFile"

if ($ShareUser) {
    $cred = [ordered]@{ User = $ShareUser; Password = Protect-KfwText (& $plain $SharePassword) }
    [IO.File]::WriteAllText((Join-Path $DataDir 'share.cred'), (ConvertTo-Json $cred))
    Say "the share account $ShareUser, encrypted for this server"
}

if ($AdminUser) {
    $st = Open-KfwStore $DataDir
    if ((Get-KfwUserCount $st) -eq 0) {
        if (-not (Test-KfwUserName $AdminUser)) { throw 'An account name is 2 to 64 letters, digits, dots, dashes, underscores or @.' }
        $pw = & $plain $AdminPassword
        $problem = Get-KfwPasswordProblem $pw $AdminUser
        if ($problem) { throw "The admin password needs $problem." }
        Add-KfwUser $st $AdminUser 'admin' $pw
        Write-KfwAudit $st -Action 'user-add' -Target $AdminUser -Result 'ok' -Detail 'admin, from Install-KioskFleetWeb.ps1'
        Say "the admin account $AdminUser"
    } else {
        Say "there are accounts already; $AdminUser was not added (Set-KioskFleetUser.ps1 add $AdminUser -Role admin)"
    }
}

# --- the server: a startup task as the service account ----------------------------------------------
Step "The server, as $ServiceAccount"
& netsh.exe http delete urlacl url="http://127.0.0.1:$BackendPort/" | Out-Null
$r = & netsh.exe http add urlacl url="http://127.0.0.1:$BackendPort/" user="$ServiceAccount"
if ($LASTEXITCODE) { throw "netsh http add urlacl failed: $r" }
Say "http://127.0.0.1:$BackendPort/ reserved for it"

$pwsh = Join-Path $PSHOME 'pwsh.exe'
$arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $InstallDir 'Start-KioskFleetWeb.ps1')`" -DataDir `"$DataDir`""
$action = New-ScheduledTaskAction -Execute $pwsh -Argument $arguments -WorkingDirectory $InstallDir
$trigger = New-ScheduledTaskTrigger -AtStartup
$taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
$description = 'Kiosk Fleet Web: the server behind the page (Caddy, the service KioskFleetCaddy, is in front of it).'
if ($ServiceAccountPassword) {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $taskSettings -Description $description `
        -User $ServiceAccount -Password (& $plain $ServiceAccountPassword) -RunLevel Limited -Force | Out-Null
} else {
    $logon = if ($ServiceAccount.EndsWith('$')) { 'Password' } else { 'ServiceAccount' }
    $principal = New-ScheduledTaskPrincipal -UserId $ServiceAccount -LogonType $logon -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $taskSettings -Description $description `
        -Principal $principal -Force | Out-Null
}
Start-ScheduledTask -TaskName $TaskName
Say "scheduled task '$TaskName' registered and started"

# --- Caddy: HTTPS, the page, and the way in --------------------------------------------------------------
Step 'Caddy in front'
$caddyDir = Join-Path $InstallDir 'caddy'
[void](New-Item -ItemType Directory -Force $caddyDir)
$caddy = Join-Path $caddyDir 'caddy.exe'
if (Get-Service $CaddyService -ErrorAction SilentlyContinue) { Stop-Service $CaddyService -Force }
if ($CaddyExe) {
    Copy-Item $CaddyExe $caddy -Force
} elseif (-not (Test-Path $caddy) -or -not ((& $caddy version) -match [regex]::Escape("v$CaddyVersion"))) {
    $base = "https://github.com/caddyserver/caddy/releases/download/v$CaddyVersion"
    $zipName = "caddy_${CaddyVersion}_windows_amd64.zip"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "kfw-caddy-$PID"
    [void](New-Item -ItemType Directory -Force $tmp)
    Invoke-WebRequest "$base/$zipName" -OutFile (Join-Path $tmp $zipName)
    Invoke-WebRequest "$base/caddy_${CaddyVersion}_checksums.txt" -OutFile (Join-Path $tmp 'checksums.txt')
    $want = (Get-Content (Join-Path $tmp 'checksums.txt') | Where-Object { $_ -match [regex]::Escape($zipName) + '$' }) -split '\s+' | Select-Object -First 1
    $got = (Get-FileHash (Join-Path $tmp $zipName) -Algorithm SHA512).Hash
    if (-not $want -or $want.ToLowerInvariant() -ne $got.ToLowerInvariant()) { throw "the Caddy download does not match its SHA-512 ($zipName)" }
    Expand-Archive (Join-Path $tmp $zipName) -DestinationPath $tmp -Force
    Copy-Item (Join-Path $tmp 'caddy.exe') $caddy -Force
    Remove-Item $tmp -Recurse -Force
    Say "Caddy $CaddyVersion downloaded, SHA-512 checked"
}
Unblock-File $caddy

$tls = 'internal'; $crt = $null; $key = $null
if ($HttpOnly) { $tls = 'off' }
elseif ($CertificateFile) {
    $crt = Join-Path $DataDir 'tls\server.crt'; $key = Join-Path $DataDir 'tls\server.key'
    Copy-Item $CertificateFile $crt -Force; Copy-Item $KeyFile $key -Force
    $tls = 'files'
}
$caddyfile = Join-Path $DataDir 'caddy\Caddyfile'
$text = Get-KfwCaddyfile -SiteAddress $SiteAddress -WebDir (Join-Path $InstallDir 'KioskFleetWeb\web') -Storage (Join-Path $DataDir 'caddy') `
    -Tls $tls -CertificateFile $crt -KeyFile $key -Backend "127.0.0.1:$BackendPort" -LogFile (Join-Path $DataDir 'logs\caddy.log')
[IO.File]::WriteAllText($caddyfile, $text)
$check = & $caddy validate --config $caddyfile --adapter caddyfile 2>&1
if ($LASTEXITCODE) { throw "Caddy does not take the Caddyfile:`n$($check -join "`n")" }

if (Get-Service $CaddyService -ErrorAction SilentlyContinue) { Remove-Service $CaddyService }
$bin = "`"$caddy`" run --config `"$caddyfile`" --adapter caddyfile"
New-Service -Name $CaddyService -BinaryPathName $bin -DisplayName 'Kiosk Fleet Web (Caddy)' -StartupType Automatic `
    -Description 'HTTPS for Kiosk Fleet Web: the page, and the way to the server on 127.0.0.1.' | Out-Null
& sc.exe config $CaddyService obj= 'NT AUTHORITY\NetworkService' | Out-Null
& sc.exe failure $CaddyService reset= 86400 actions= restart/5000/restart/10000/restart/60000 | Out-Null
Start-Service $CaddyService
Say "service $CaddyService, as NETWORK SERVICE, started"

Get-NetFirewallRule -Name $FirewallRule -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -Name $FirewallRule -DisplayName 'Kiosk Fleet Web (Caddy)' -Direction Inbound -Action Allow -Protocol TCP `
    -LocalPort 80, 443 -Program $caddy | Out-Null
Say 'firewall: 80 and 443 open to Caddy'

# --- is it there? ----------------------------------------------------------------------------------------------
Step 'Checking'
$ok = $false
$deadline = [datetime]::UtcNow.AddSeconds(90)
while ([datetime]::UtcNow -lt $deadline) {
    try {
        $h = Invoke-RestMethod "$SiteAddress/healthz" -SkipCertificateCheck -TimeoutSec 5
        if ($h.ok) { $ok = $true; break }
    } catch { Start-Sleep -Seconds 2 }
}
if (-not $ok) {
    Write-Warning "$SiteAddress/healthz does not answer yet. The server's log: $(Join-Path $DataDir 'logs\server.log'); Caddy's: $(Join-Path $DataDir 'logs\caddy.log')."
} else {
    Say "$SiteAddress answers"
}
$link = Join-Path $DataDir 'setup-link.txt'
if (Test-Path $link) {
    Write-Host ''
    Write-Host "Make the first admin account here (the link works once): $SiteAddress$((Get-Content $link -Raw).Trim())" -ForegroundColor Yellow
}
if ($tls -eq 'internal') {
    Write-Host ''
    Write-Host "Caddy made its own certificate. Browsers trust it once its root is trusted (by group policy, say): $(Join-Path $DataDir 'caddy\pki\authorities\local\root.crt')"
}
Write-Host ''
Write-Host "Kiosk Fleet Web: $SiteAddress" -ForegroundColor Green
