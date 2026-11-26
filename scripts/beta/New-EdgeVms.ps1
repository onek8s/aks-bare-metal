<#
.SYNOPSIS
    BETA. Creates one Hyper-V edge VM per name in MultiNode.VmNames.

.DESCRIPTION
    Calls ..\1-New-EdgeVm.ps1 for each VM, so every VM gets the same sizing,
    switch, Secure Boot and vTPM settings. Each VM boots the maintenance
    environment ISO and produces its own ownership voucher; register all of
    them in the same site in the portal (README, multi-node section).

    Afterwards, ..\2-Get-EdgeVmInfo.ps1 -VmName <name> shows each VM's
    serial number and IP.
#>
[CmdletBinding()]
param(
    [string]$SettingsPath,
    [switch]$Force
)

. (Join-Path $PSScriptRoot '..\common.ps1')
Assert-Admin
$s = Get-Settings $SettingsPath
if (-not $s.ContainsKey('MultiNode')) { throw 'settings.psd1 has no MultiNode section.' }

$create = Join-Path $PSScriptRoot '..\1-New-EdgeVm.ps1'
foreach ($name in $s.MultiNode.VmNames) {
    Write-Step "=== $name ==="
    & $create -SettingsPath $SettingsPath -VmName $name -Force:$Force
}

Write-Host ''
Write-Host 'All VMs are booting. For each one, get its voucher with:' -ForegroundColor Green
foreach ($name in $s.MultiNode.VmNames) {
    Write-Host "    .\scripts\2-Get-EdgeVmInfo.ps1 -VmName $name -EdgeMachineName $name -EjectIso"
}
