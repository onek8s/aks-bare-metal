<#
.SYNOPSIS
    Creates a single-node AKS on bare metal cluster on the provisioned edge
    machine, using Microsoft's ARM template from github.com/Azure/aksArc.

.DESCRIPTION
    The template creates (in order) a device pool + custom location for the
    edge machine, the role assignments it needs, a logical network, the
    connected cluster and the provisioned cluster instance. Azure Policy and
    Container Insights are off by default to keep things minimal.

    Takes roughly 20 minutes.
#>
[CmdletBinding()]
param([string]$SettingsPath)

. (Join-Path $PSScriptRoot 'common.ps1')
$s = Get-Settings $SettingsPath
Assert-AzCli
Set-AzSubscription $s | Out-Null

if (-not $s.AdminGroupObjectId) {
    throw 'AdminGroupObjectId is empty in settings.psd1. Run 0-Initialize-Azure.ps1 and copy the group ID it prints.'
}

# --- SSH key --------------------------------------------------------------
if (-not (Test-Path $s.SshPublicKeyPath)) {
    Write-Step "Creating SSH key $($s.SshPublicKeyPath)"
    $priv = $s.SshPublicKeyPath -replace '\.pub$', ''
    New-Item -ItemType Directory -Force -Path (Split-Path $priv -Parent) | Out-Null
    # Empty passphrase. PowerShell 7.3+ passes '' as-is; Windows PowerShell 5.1 needs '""'.
    $emptyPass = if ($PSVersionTable.PSVersion -ge [version]'7.3') { '' } else { '""' }
    & ssh-keygen -t ed25519 -f $priv -N $emptyPass -C 'aks-bare-metal' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'ssh-keygen failed. Install the OpenSSH client, or set SshPublicKeyPath to an existing key.' }
}
$sshKey = (Get-Content -Raw $s.SshPublicKeyPath).Trim()

# --- Template -------------------------------------------------------------
$templatePath = Join-Path $s.OutputPath 'aks-baremetal-arm.json'
Write-Step "Downloading ARM template"
Invoke-WebRequest -Uri $s.ArmTemplateUrl -OutFile $templatePath -UseBasicParsing

$params = [ordered]@{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters     = [ordered]@{
        location                  = @{ value = $s.Location }
        clusterName               = @{ value = $s.ClusterName }
        kubernetesVersion         = @{ value = $s.KubernetesVersion }
        controlPlaneIp            = @{ value = $s.ControlPlaneIp }
        adminGroupObjectIds       = @{ value = @($s.AdminGroupObjectId) }
        sshPublicKey              = @{ value = $sshKey }
        enableAzurePolicy         = @{ value = [bool]$s.EnableAzurePolicy }
        enableContainerMonitoring = @{ value = [bool]$s.EnableContainerMonitoring }
        logAnalyticsWorkspaceId   = @{ value = $s.LogAnalyticsWorkspaceId }
        edgeMachineName           = @{ value = $s.EdgeMachineName }
    }
}
$paramsPath = Join-Path $s.OutputPath 'aks-baremetal-arm.parameters.json'
$params | ConvertTo-Json -Depth 10 | Set-Content -Path $paramsPath -Encoding UTF8

# --- Deploy ---------------------------------------------------------------
$deploymentName = "aksbm-$($s.ClusterName)-$(Get-Date -Format yyyyMMddHHmm)"
Write-Step "Deploying cluster '$($s.ClusterName)' (deployment $deploymentName, ~20 minutes)"
& az deployment group create `
    --resource-group $s.ResourceGroup `
    --name $deploymentName `
    --template-file $templatePath `
    --parameters "@$paramsPath" `
    --output table
if ($LASTEXITCODE -ne 0) {
    throw "Deployment failed. Inspect it with: az deployment operation group list -g $($s.ResourceGroup) -n $deploymentName -o table"
}

Write-Step 'Cluster status'
& az aksarc show --resource-group $s.ResourceGroup --name $s.ClusterName `
    --query properties.provisioningState --output tsv

Write-Host ''
Write-Host 'Cluster created. Next: run 5-Get-Kubeconfig.ps1.' -ForegroundColor Green
