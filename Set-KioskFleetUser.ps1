#Requires -Version 7.4
<#
.SYNOPSIS
    Accounts of Kiosk Fleet Web, from the command line on the server.

.DESCRIPTION
    The same accounts admins manage on the Users page. Works while the server
    runs; it reads the change at once.

      list                              every account
      add NAME [-Role admin]            asks for the password twice
      passwd NAME [-MustChange]
      role NAME operator|admin
      disable NAME | enable NAME | remove NAME
      import web-users.json             accounts from the PowerShell server, hashes and all

    KFW_NEW_PASSWORD, if set, is used instead of asking.

.EXAMPLE
    .\Set-KioskFleetUser.ps1 add alice -Role admin
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('list', 'add', 'passwd', 'role', 'disable', 'enable', 'remove', 'import')][string]$Action,
    [Parameter(Position = 1)][string]$Name,
    [Parameter(Position = 2)][ValidateSet('operator', 'admin')][string]$Role,
    # They choose their own password at the next sign-in.
    [switch]$MustChange,
    [string]$DataDir
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'KioskFleetWeb\KioskFleetWeb.psd1') -Force
$settings = Get-KfwSettings -DataDir $DataDir
Initialize-KfwDirs $settings
$st = Open-KfwStore $settings.DataDir

function Read-NewPassword([string]$For) {
    if ($env:KFW_NEW_PASSWORD) { $p1 = $p2 = $env:KFW_NEW_PASSWORD }
    else {
        $p1 = Read-Host "Password for $For" -MaskInput
        $p2 = Read-Host 'Again' -MaskInput
    }
    if ($p1 -cne $p2) { throw 'The two did not match. Nothing was changed.' }
    if (-not $p1) { throw 'An empty password. Nothing was changed.' }
    # Set from the server's own command line: any password will do, as on
    # the Users page. The rules are for the passwords people choose.
    $problem = Get-KfwPasswordProblem $p1 $For
    if ($problem) { Write-Host "Note: below the password rules (it would need $problem)." }
    return $p1
}

if ($Action -eq 'list') {
    $users = Get-KfwUsers $st
    if (-not $users.Count) { 'No accounts.'; return }
    foreach ($u in $users) {
        $state = if ($u.disabled) { 'disabled' } elseif ($u.must_change) { 'must change password' } else { 'active' }
        '{0,-32} {1,-9} {2,-22} last sign-in {3}' -f $u.name, $u.role, $state, $(if ($u.last_login) { $u.last_login } else { 'never' })
    }
    return
}
if ($Action -eq 'import') {
    if (-not $Name) { throw 'Which file? Set-KioskFleetUser.ps1 import web-users.json' }
    $done = Import-KfwWebUsers $st (Resolve-Path -LiteralPath $Name).ProviderPath
    "Imported $($done.Count) account(s): $(if ($done.Count) { $done -join ', ' } else { '-' })"
    return
}
if (-not $Name) { throw 'Which account?' }
$u = Get-KfwUser $st $Name
if ($Action -eq 'add') {
    if ($u) { throw "There is an account called $Name already." }
    if (-not (Test-KfwUserName $Name)) { throw 'An account name is 2 to 64 letters, digits, dots, dashes, underscores or @.' }
    $r = if ($Role) { $Role } else { 'operator' }
    Add-KfwUser $st $Name $r (Read-NewPassword $Name) ([bool]$MustChange)
    Write-KfwAudit $st -Action 'user-add' -Target $Name -Result 'ok' -Detail "$r, from the command line"
    "Added $Name ($r)."
    return
}
if (-not $u) { throw "No account called $Name." }
$Name = $u.name
$lastAdmin = $u.role -eq 'admin' -and -not $u.disabled -and (Get-KfwUserCount $st -ActiveAdminsOnly) -le 1
switch ($Action) {
    'passwd' {
        Set-KfwUserPassword $st $Name (Read-NewPassword $Name) ([bool]$MustChange)
        Stop-KfwSessionsOf $st $Name
        $detail = 'new password'
    }
    'role' {
        if (-not $Role) { throw 'The role is operator or admin.' }
        if ($lastAdmin -and $Role -ne 'admin') { throw 'That is the last admin.' }
        Set-KfwUserRole $st $Name $Role
        $detail = "role=$Role"
    }
    { $_ -in 'disable', 'enable' } {
        if ($Action -eq 'disable' -and $lastAdmin) { throw 'That is the last admin.' }
        Set-KfwUserDisabled $st $Name ($Action -eq 'disable')
        if ($Action -eq 'disable') { Stop-KfwSessionsOf $st $Name }
        $detail = "${Action}d"
    }
    'remove' {
        if ($lastAdmin) { throw 'That is the last admin.' }
        Remove-KfwUser $st $Name
        $detail = 'removed'
    }
}
Write-KfwAudit $st -Action 'user-change' -Target $Name -Result 'ok' -Detail "$detail, from the command line"
"${Name}: $detail."
