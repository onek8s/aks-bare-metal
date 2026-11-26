<#
.SYNOPSIS
    Tears the lab down: the AKS cluster resources in Azure and, optionally,
    the edge machine registration, the resource group and the Hyper-V VM.

.DESCRIPTION
    Azure Linux clusters use "ordered Azure resource deletion": resources are
    deleted in reverse order of how the ARM template created them.

    -Cluster        delete the cluster resources only (default when nothing is given)
    -EdgeMachine    also delete the edge machine resource in Azure
    -ResourceGroup  delete the whole resource group (after the cluster)
    -Vm             delete the Hyper-V VM and its disk (run on the Hyper-V host, elevated)
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$SettingsPath,
    [switch]$Cluster,
    [switch]$EdgeMachine,
    [switch]$ResourceGroup,
    [switch]$Vm
)

. (Join-Path $PSScriptRoot 'common.ps1')
$s = Get-Settings $SettingsPath
if (-not ($Cluster -or $EdgeMachine -or $ResourceGroup -or $Vm)) { $Cluster = $true }
if ($EdgeMachine -or $ResourceGroup) { $Cluster = $true }

function Remove-AzResourceIfExists([string]$Id, [string]$Label) {
    & az resource show --ids $Id --output none 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Host "    $Label not found, skipping"; return }
    Write-Host "    deleting $Label"
    Invoke-Az resource delete --ids $Id | Out-Null
}

if ($Cluster -or $EdgeMachine -or $ResourceGroup) {
    Assert-AzCli
    $acct = Set-AzSubscription $s
    $rg = "/subscriptions/$($acct.id)/resourceGroups/$($s.ResourceGroup)"
    $cc = "$rg/providers/Microsoft.Kubernetes/connectedClusters/$($s.ClusterName)"
    # Names follow the defaults in Microsoft's ARM template.
    $ids = [ordered]@{
        'Azure Policy extension'     = "$cc/providers/Microsoft.KubernetesConfiguration/extensions/azure-policy"
        'Monitoring extension'       = "$cc/providers/Microsoft.KubernetesConfiguration/extensions/azuremonitor-containers"
        'provisioned cluster'        = "$cc/providers/Microsoft.HybridContainerService/provisionedClusterInstances/default"
        'connected cluster'          = $cc
        'logical network'            = "$rg/providers/Microsoft.AzureStackHCI/logicalNetworks/$($s.ClusterName)-lnet"
        'device pool'                = "$rg/providers/Microsoft.AzureStackHCI/devicePools/$($s.EdgeMachineName)"
        'custom location'            = "$rg/providers/Microsoft.ExtendedLocation/customLocations/$($s.EdgeMachineName)"
    }
    if ($PSCmdlet.ShouldProcess($s.ClusterName, 'Delete AKS cluster resources')) {
        Write-Step "Deleting cluster '$($s.ClusterName)'"
        foreach ($k in $ids.Keys) { Remove-AzResourceIfExists $ids[$k] $k }
    }

    if ($EdgeMachine -and $PSCmdlet.ShouldProcess($s.EdgeMachineName, 'Delete edge machine resource')) {
        Write-Step "Deleting edge machine '$($s.EdgeMachineName)'"
        Remove-AzResourceIfExists "$rg/providers/Microsoft.AzureStackHCI/edgeMachines/$($s.EdgeMachineName)" 'edge machine'
    }

    if ($ResourceGroup -and $PSCmdlet.ShouldProcess($s.ResourceGroup, 'Delete resource group')) {
        Write-Step "Deleting resource group '$($s.ResourceGroup)'"
        Invoke-Az group delete --name $s.ResourceGroup --yes | Out-Null
    }
}

if ($Vm) {
    Assert-Admin
    $vmObj = Get-VM -Name $s.VmName -ErrorAction SilentlyContinue
    if (-not $vmObj) {
        Write-Host "    VM '$($s.VmName)' not found, skipping"
    } elseif ($PSCmdlet.ShouldProcess($s.VmName, 'Delete Hyper-V VM and its disks')) {
        Write-Step "Deleting VM '$($s.VmName)'"
        $disks = Get-VMHardDiskDrive -VM $vmObj | Select-Object -ExpandProperty Path
        if ($vmObj.State -ne 'Off') { Stop-VM -VM $vmObj -TurnOff -Force }
        Remove-VM -VM $vmObj -Force
        foreach ($d in $disks) { Remove-Item -Path $d -Force -ErrorAction SilentlyContinue }
        Remove-Item -Path (Join-Path $s.VmPath $s.VmName) -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host 'Done.' -ForegroundColor Green
