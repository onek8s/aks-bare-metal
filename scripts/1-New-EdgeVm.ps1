<#
.SYNOPSIS
    Creates the Hyper-V VM that acts as the AKS bare metal "edge machine"
    and boots it from the Azure Local maintenance environment ISO.

.DESCRIPTION
    Run on the Hyper-V host in an elevated PowerShell.

    The VM is Generation 2 with Secure Boot and a virtual TPM, because
    machine provisioning requires both. Memory is static (no dynamic memory)
    and automatic checkpoints are off, since the VM behaves like a physical
    host running Kubernetes directly.

    After it boots, the maintenance environment sets itself up (the VM
    reboots about twice, up to ~30 minutes) and generates an ownership
    voucher. Use 2-Get-EdgeVmInfo.ps1 for the serial number / IP you need
    to fetch that voucher.

.PARAMETER Force
    Delete and re-create the VM (and its disk) if it already exists.
#>
[CmdletBinding()]
param(
    [string]$SettingsPath,
    [switch]$Force
)

. (Join-Path $PSScriptRoot 'common.ps1')
Assert-Admin
$s = Get-Settings $SettingsPath

if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
    throw 'Hyper-V PowerShell module not found. Enable Hyper-V and its management tools first.'
}
if (-not (Test-Path $s.MaintenanceIsoPath)) {
    throw "Maintenance environment ISO not found at '$($s.MaintenanceIsoPath)'. Download it from the Azure portal (Azure Arc > Azure Local > Get started > Try provisioning (preview) > View Downloads) and set MaintenanceIsoPath in settings.psd1."
}

# --- Virtual switch -------------------------------------------------------
$switch = Get-VMSwitch -Name $s.SwitchName -ErrorAction SilentlyContinue
if (-not $switch) {
    Write-Step "Creating External switch '$($s.SwitchName)' on adapter '$($s.NetAdapterName)'"
    if (-not (Get-NetAdapter -Name $s.NetAdapterName -ErrorAction SilentlyContinue)) {
        throw "Network adapter '$($s.NetAdapterName)' not found. Pick one from Get-NetAdapter, or set SwitchName to an existing switch."
    }
    Write-Warning 'The host loses network connectivity for a few seconds while the switch is created.'
    $switch = New-VMSwitch -Name $s.SwitchName -NetAdapterName $s.NetAdapterName -AllowManagementOS $true
} else {
    Write-Step "Using existing switch '$($s.SwitchName)' ($($switch.SwitchType))"
    if ($switch.SwitchType -ne 'External') {
        Write-Warning 'The switch is not External. The VM needs outbound HTTPS to Azure, so make sure NAT/routing is in place.'
    }
}

# --- VM -------------------------------------------------------------------
$vm = Get-VM -Name $s.VmName -ErrorAction SilentlyContinue
if ($vm) {
    if (-not $Force) {
        throw "VM '$($s.VmName)' already exists. Use -Force to delete and re-create it."
    }
    Write-Step "Removing existing VM '$($s.VmName)'"
    $disks = Get-VMHardDiskDrive -VM $vm | Select-Object -ExpandProperty Path
    if ($vm.State -ne 'Off') { Stop-VM -VM $vm -TurnOff -Force }
    Remove-VM -VM $vm -Force
    foreach ($d in $disks) { Remove-Item -Path $d -Force -ErrorAction SilentlyContinue }
}

$vmDir = Join-Path $s.VmPath $s.VmName
$vhdPath = Join-Path $vmDir "$($s.VmName)-os.vhdx"
New-Item -ItemType Directory -Force -Path $vmDir | Out-Null
if (Test-Path $vhdPath) { Remove-Item $vhdPath -Force }

Write-Step "Creating VM '$($s.VmName)': $($s.VmProcessorCount) vCPU, $($s.VmMemoryGB) GB RAM, $($s.VmDiskGB) GB disk"
New-VHD -Path $vhdPath -SizeBytes ([int64]$s.VmDiskGB * 1GB) -Dynamic | Out-Null
$vm = New-VM -Name $s.VmName -Generation 2 -Path $s.VmPath `
    -MemoryStartupBytes ([int64]$s.VmMemoryGB * 1GB) `
    -VHDPath $vhdPath -SwitchName $s.SwitchName

Set-VM -VM $vm -ProcessorCount $s.VmProcessorCount -StaticMemory `
    -AutomaticCheckpointsEnabled $false -CheckpointType Disabled `
    -AutomaticStartAction Start -AutomaticStopAction ShutDown

# Network adapter: optional fixed MAC and VLAN.
$nic = Get-VMNetworkAdapter -VM $vm
if ($s.MacAddress) {
    Set-VMNetworkAdapter -VMNetworkAdapter $nic -StaticMacAddress ($s.MacAddress -replace '[:-]', '')
}
if ($s.VlanId -gt 0) {
    Set-VMNetworkAdapterVlan -VMNetworkAdapter $nic -Access -VlanId $s.VlanId
}

# Guest services / time sync are harmless and help with clock drift.
Enable-VMIntegrationService -VM $vm -Name 'Guest Service Interface' -ErrorAction SilentlyContinue

# Secure Boot + vTPM (both required by machine provisioning).
Write-Step "Enabling Secure Boot ($($s.SecureBootTemplate)) and virtual TPM"
Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate $s.SecureBootTemplate
Set-VMKeyProtector -VM $vm -NewLocalKeyProtector
Enable-VMTPM -VM $vm

# Boot from the maintenance environment ISO first.
Write-Step 'Attaching maintenance environment ISO'
$dvd = Add-VMDvdDrive -VM $vm -Path $s.MaintenanceIsoPath -Passthru
$osDisk = Get-VMHardDiskDrive -VM $vm
Set-VMFirmware -VM $vm -BootOrder $dvd, $osDisk

Write-Step "Starting VM '$($s.VmName)'"
Start-VM -VM $vm

Write-Host ''
Write-Host 'The VM is booting the maintenance environment. Watch it with:' -ForegroundColor Green
Write-Host "    vmconnect.exe localhost $($s.VmName)"
Write-Host 'When the console shows "Maintenance environment setup completed successfully",'
Write-Host 'run 2-Get-EdgeVmInfo.ps1 to get the serial number and IP for the voucher.'
