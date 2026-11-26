<#
.SYNOPSIS
    BETA. Tries to create one AKS on bare metal cluster across several
    provisioned edge machines: N control plane nodes + a worker pool.

.DESCRIPTION
    Uses templates\aks-baremetal-multinode.json, a modified copy of
    Microsoft's single-node template. Changes compared with the original:

      - all edge machines go into one device pool (devices[] loop) and the
        device pool identity gets Edge Machine Contributor on each of them
      - controlPlane.count comes from MultiNode.ControlPlaneCount (1/3/5)
      - agentPoolProfiles gets one Linux pool (osSKU CBLMariner = Azure Linux)
        sized to the remaining machines, the same shape AKS on Azure Local uses
      - controlPlaneEndpoint.hostIP is a separate VIP, required here
      - pod CIDR is a parameter

    The AKS on bare metal preview documents multi-node as NOT supported, so
    expect the resource provider to reject this or to ignore the extra
    machines. Run with -WhatIf first to see what ARM thinks of it.

.PARAMETER WhatIf
    Runs `az deployment group what-if` instead of deploying.
#>
[CmdletBinding()]
param(
    [string]$SettingsPath,
    [switch]$WhatIf
)

. (Join-Path $PSScriptRoot '..\common.ps1')
$s = Get-Settings $SettingsPath
if (-not $s.ContainsKey('MultiNode')) { throw 'settings.psd1 has no MultiNode section.' }
$m = $s.MultiNode
$machines = @($m.VmNames)

# --- Validation -----------------------------------------------------------
if ($m.ControlPlaneCount -notin 1, 3, 5) {
    throw 'MultiNode.ControlPlaneCount must be 1, 3 or 5 (etcd needs an odd number for quorum).'
}
if ($machines.Count -lt $m.ControlPlaneCount) {
    throw "ControlPlaneCount is $($m.ControlPlaneCount) but only $($machines.Count) machines are listed."
}
if ($machines.Count -gt 1 -and -not $m.ControlPlaneIp) {
    throw 'MultiNode.ControlPlaneIp is required with more than one machine: pick an unused IP in the machines'' subnet and reserve it.'
}
if (-not $s.AdminGroupObjectId) {
    throw 'AdminGroupObjectId is empty in settings.psd1. Run 0-Initialize-Azure.ps1 first.'
}
$workers = if ($m.WorkerCount -lt 0) { $machines.Count - $m.ControlPlaneCount } else { $m.WorkerCount }
if ($m.ControlPlaneCount + $workers -gt $machines.Count) {
    Write-Warning "Asking for $($m.ControlPlaneCount + $workers) nodes on $($machines.Count) machines. Bare metal has one node per machine, so this will likely fail."
}

Assert-AzCli
Set-AzSubscription $s | Out-Null

Write-Step 'Checking edge machines'
foreach ($name in $machines) {
    & az resource show --resource-group $s.ResourceGroup --name $name `
        --resource-type 'Microsoft.AzureStackHCI/edgeMachines' --output none 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Edge machine '$name' not found in '$($s.ResourceGroup)'. Provision it first (3-Wait-EdgeMachine.ps1 -EdgeMachineName $name)."
    }
    Write-Host "    $name found"
}

# --- SSH key --------------------------------------------------------------
if (-not (Test-Path $s.SshPublicKeyPath)) {
    throw "SSH public key not found at $($s.SshPublicKeyPath). Run 4-New-AksCluster.ps1 once, or create it with ssh-keygen."
}
$sshKey = (Get-Content -Raw $s.SshPublicKeyPath).Trim()

# --- Parameters -----------------------------------------------------------
$templatePath = Join-Path $PSScriptRoot '..\..\templates\aks-baremetal-multinode.json'
$params = [ordered]@{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters     = [ordered]@{
        location                  = @{ value = $s.Location }
        clusterName               = @{ value = $m.ClusterName }
        kubernetesVersion         = @{ value = $s.KubernetesVersion }
        controlPlaneIp            = @{ value = $m.ControlPlaneIp }
        controlPlaneCount         = @{ value = [int]$m.ControlPlaneCount }
        workerCount               = @{ value = [int]$m.WorkerCount }
        podCidr                   = @{ value = $m.PodCidr }
        adminGroupObjectIds       = @{ value = @($s.AdminGroupObjectId) }
        sshPublicKey              = @{ value = $sshKey }
        enableAzurePolicy         = @{ value = [bool]$s.EnableAzurePolicy }
        enableContainerMonitoring = @{ value = [bool]$s.EnableContainerMonitoring }
        logAnalyticsWorkspaceId   = @{ value = $s.LogAnalyticsWorkspaceId }
        edgeMachineNames          = @{ value = $machines }
    }
}
$paramsPath = Join-Path $s.OutputPath 'aks-baremetal-multinode.parameters.json'
$params | ConvertTo-Json -Depth 10 | Set-Content -Path $paramsPath -Encoding UTF8
Write-Host "    Parameters: $paramsPath"
Write-Host "    $($m.ControlPlaneCount) control plane + $workers worker node(s) on $($machines.Count) machine(s), VIP $($m.ControlPlaneIp)"

# --- Deploy ---------------------------------------------------------------
$deploymentName = "aksbm-$($m.ClusterName)-$(Get-Date -Format yyyyMMddHHmm)"
$verb = if ($WhatIf) { 'what-if' } else { 'create' }
Write-Step "az deployment group $verb ($deploymentName)"
& az deployment group $verb `
    --resource-group $s.ResourceGroup `
    --name $deploymentName `
    --template-file $templatePath `
    --parameters "@$paramsPath"
if ($LASTEXITCODE -ne 0) {
    throw "Deployment failed. Details: az deployment operation group list -g $($s.ResourceGroup) -n $deploymentName -o table"
}
if ($WhatIf) { return }

Write-Step 'Nodes'
$kubeconfig = Join-Path $s.OutputPath "$($m.ClusterName).kubeconfig"
Invoke-Az aksarc get-credentials --resource-group $s.ResourceGroup --name $m.ClusterName `
    --file $kubeconfig --overwrite-existing | Out-Null
& kubectl --kubeconfig $kubeconfig get nodes -o wide
Write-Host ''
Write-Host "If fewer nodes than expected joined, the preview ignored the extra machines. Kubeconfig: $kubeconfig" -ForegroundColor Yellow
