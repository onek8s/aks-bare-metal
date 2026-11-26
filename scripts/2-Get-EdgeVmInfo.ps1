<#
.SYNOPSIS
    Shows what you need to fetch the ownership voucher from the edge VM,
    and optionally ejects the maintenance environment ISO.

.DESCRIPTION
    The voucher is fetched with the "Configurator App for Azure Local V2"
    (part of the portal download) by connecting to
    <serial number>.local or the VM's IP address.
    Default maintenance environment login: edgeuser / Password1

    Hyper-V gives each VM a BIOS serial number; this script reads it.

.PARAMETER EjectIso
    Remove the ISO from the DVD drive. Do this once the console shows
    "Maintenance environment setup completed successfully".
#>
[CmdletBinding()]
param(
    [string]$SettingsPath,
    [switch]$EjectIso
)

. (Join-Path $PSScriptRoot 'common.ps1')
Assert-Admin
$s = Get-Settings $SettingsPath

$vm = Get-VM -Name $s.VmName
$settingData = Get-CimInstance -Namespace 'root\virtualization\v2' -ClassName 'Msvm_VirtualSystemSettingData' |
    Where-Object { $_.ElementName -eq $s.VmName -and $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' }
$serial = $settingData.BIOSSerialNumber
$nic = Get-VMNetworkAdapter -VM $vm
$ips = @($nic.IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })

$info = [ordered]@{
    VmName        = $vm.Name
    State         = $vm.State
    Uptime        = $vm.Uptime
    SerialNumber  = $serial
    MdnsName      = if ($serial) { "$serial.local" } else { '' }
    MacAddress    = ($nic.MacAddress -replace '(..)(?!$)', '$1-')
    IPv4          = if ($ips) { $ips -join ', ' } else { '(not reported; check your DHCP server for the MAC above)' }
    DvdMedia      = (Get-VMDvdDrive -VM $vm | Select-Object -ExpandProperty Path)
}
[pscustomobject]$info | Format-List

$infoFile = Join-Path $s.OutputPath "$($s.VmName)-info.json"
[pscustomobject]$info | ConvertTo-Json | Set-Content -Path $infoFile -Encoding UTF8
Write-Host "Saved to $infoFile"

if ($EjectIso) {
    Write-Step 'Ejecting maintenance environment ISO'
    Get-VMDvdDrive -VM $vm | Set-VMDvdDrive -Path $null
    Set-VMFirmware -VM $vm -FirstBootDevice (Get-VMHardDiskDrive -VM $vm)
}

Write-Host ''
Write-Host 'Next (manual, see README step 3):' -ForegroundColor Green
Write-Host '  1. Open "Configurator App for Azure Local V2" as administrator, connect to the'
Write-Host '     serial .local name or IP above (edgeuser / Password1) and download the voucher (.pem).'
Write-Host '  2. In the portal, create a site, add the voucher, pick the Azure Linux (AKS) software'
Write-Host "     version and name the machine '$($s.EdgeMachineName)'."
Write-Host '  3. Run 3-Wait-EdgeMachine.ps1 until the machine is Provisioned.'
