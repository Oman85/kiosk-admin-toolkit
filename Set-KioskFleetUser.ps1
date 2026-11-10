#Requires -Version 7.4
<#
.SYNOPSIS
    Accounts of Kiosk Fleet Web, from the command line on the server.

.DESCRIPTION
    The same accounts admins manage on the Users page. Works while the server
    runs; it reads the change at once.

      list                              every account
      add NAME [-Role viewer|operator|admin]   asks for the password twice
      passwd NAME [-MustChange]
      role NAME viewer|operator|admin
      rights NAME                       what the account may do, and why
      grant NAME PERMISSION[,...]       may do this too, whatever the role
      deny NAME PERMISSION[,...]        may not do this, whatever the role
      reset NAME                        back to what the role gives
      permissions                       every permission, and the least role that has it
      disable NAME | enable NAME | remove NAME
      import web-users.json             accounts from the PowerShell server, hashes and all

    KFW_NEW_PASSWORD, if set, is used instead of asking.

.EXAMPLE
    .\Set-KioskFleetUser.ps1 add alice -Role admin

.EXAMPLE
    .\Set-KioskFleetUser.ps1 grant nightshift restart,hold,resume
    An operator who may also restart kiosks and hold their launchers.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('list', 'add', 'passwd', 'role', 'rights', 'grant', 'deny', 'reset', 'permissions', 'disable', 'enable', 'remove', 'import')][string]$Action,
    [Parameter(Position = 1)][string]$Name,
    # The role (add, role), or the permissions (grant, deny): several with commas.
    [Parameter(Position = 2)][Alias('Role')][string[]]$Value,
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

$roles = Get-KfwRoles
$values = @($Value | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
function Get-RoleArgument {
    if ($values.Count -ne 1 -or $values[0] -cnotin $roles) { throw "The role is one of: $($roles -join ', ')." }
    return $values[0]
}
function Get-RightsText($u) {
    $parts = @(@($u.grant | ForEach-Object { "+$_" }) + @($u.deny | ForEach-Object { "-$_" }))
    if ($parts.Count) { return $parts -join ' ' }
    return ''
}

if ($Action -eq 'permissions') {
    foreach ($p in (Get-KfwPermissionCatalog)) {
        '{0,-10} {1,-9} {2}{3}' -f $p.name, $p.role, $p.label, $(if ($p.adjustable) { '' } else { ' (goes with the role only)' })
    }
    return
}
if ($Action -eq 'list') {
    $users = Get-KfwUsers $st
    if (-not $users.Count) { 'No accounts.'; return }
    foreach ($u in $users) {
        $state = if ($u.disabled) { 'disabled' } elseif ($u.must_change) { 'must change password' } else { 'active' }
        $rights = Get-RightsText $u
        ('{0,-32} {1,-9} {2,-22} last sign-in {3}' -f $u.name, $u.role, $state, $(if ($u.last_login) { $u.last_login } else { 'never' })) + $(if ($rights) { "  $rights" } else { '' })
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
    $r = if ($values.Count) { Get-RoleArgument } else { 'operator' }
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
        $r = Get-RoleArgument
        if ($lastAdmin -and $r -ne 'admin') { throw 'That is the last admin.' }
        Set-KfwUserRole $st $Name $r
        $detail = "role=$r"
    }
    'rights' {
        $allowed = Get-KfwRightsOf $u.role $u.grant $u.deny
        "$Name ($($u.role)$(if ($r = Get-RightsText $u) { ", $r" }))"
        foreach ($p in (Get-KfwPermissionCatalog)) {
            $why = if ($u.grant -ccontains $p.name) { 'granted' } elseif ($u.deny -ccontains $p.name) { 'denied' } else { 'role' }
            '  {0} {1,-10} {2,-8} {3}' -f $(if ($allowed -ccontains $p.name) { 'yes' } else { ' no' }), $p.name, $why, $p.label
        }
        return
    }
    { $_ -in 'grant', 'deny' } {
        if (-not $values.Count) { throw "Which permissions? Set-KioskFleetUser.ps1 permissions lists them." }
        $bad = Get-KfwBadPermission $values
        if ($null -ne $bad) { throw "$bad is not a permission that can be given or taken one by one. Set-KioskFleetUser.ps1 permissions lists them." }
        # Granting takes a permission out of the account's deny list, and
        # denying one takes it out of its grants: the last word counts.
        $grant = @($u.grant); $deny = @($u.deny)
        if ($Action -eq 'grant') { $grant = @($grant) + $values; $deny = @($deny | Where-Object { $values -cnotcontains $_ }) }
        else { $deny = @($deny) + $values; $grant = @($grant | Where-Object { $values -cnotcontains $_ }) }
        Set-KfwUserRights $st $Name $grant $deny
        $now = Get-KfwUser $st $Name
        $detail = 'permissions: ' + $(if ($r = Get-RightsText $now) { $r } else { 'as the role' })
    }
    'reset' {
        Set-KfwUserRights $st $Name @() @()
        $detail = 'permissions: as the role'
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
