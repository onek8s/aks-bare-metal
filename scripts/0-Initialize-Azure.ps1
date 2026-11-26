<#
.SYNOPSIS
    One-time Azure setup for AKS on bare metal (preview) with Azure Linux.

.DESCRIPTION
    - Registers the preview features and resource providers that machine
      provisioning and AKS on bare metal need.
    - Installs the aksarc and connectedk8s Azure CLI extensions.
    - Creates the resource group (East US).
    - Creates an Entra ID admin group and adds you to it, unless
      AdminGroupObjectId is already set in settings.psd1.

    Safe to re-run.
#>
[CmdletBinding()]
param([string]$SettingsPath)

. (Join-Path $PSScriptRoot 'common.ps1')
$s = Get-Settings $SettingsPath

Assert-AzCli
$acct = Set-AzSubscription $s

Write-Step 'Registering preview features'
$features = @(
    @{ Namespace = 'Microsoft.HybridContainerService'; Name = 'hiddenPreviewAccess' }
    @{ Namespace = 'Microsoft.HybridConnectivity';     Name = 'hiddenPreviewAccess' }
    @{ Namespace = 'Microsoft.DeviceOnboarding';       Name = 'AzureLocalZTP' }
)
foreach ($f in $features) {
    Invoke-Az feature register --namespace $f.Namespace --name $f.Name --output none | Out-Null
    Write-Host "    $($f.Namespace)/$($f.Name)"
}

Write-Step 'Waiting for features to show Registered (can take several minutes)'
foreach ($f in $features) {
    for ($i = 0; $i -lt 60; $i++) {
        $state = Invoke-Az feature show --namespace $f.Namespace --name $f.Name --query properties.state --output tsv
        if ($state -eq 'Registered') { break }
        Start-Sleep -Seconds 20
    }
    Write-Host "    $($f.Namespace)/$($f.Name): $state"
    if ($state -ne 'Registered') {
        Write-Warning "Feature $($f.Namespace)/$($f.Name) is '$state'. Some preview features need Microsoft approval; sign up at https://aka.ms/aks-edge-baremetal and re-run."
    }
}

Write-Step 'Registering resource providers'
$providers = @(
    'Microsoft.HybridCompute', 'Microsoft.HybridContainerService', 'Microsoft.HybridConnectivity',
    'Microsoft.Kubernetes', 'Microsoft.KubernetesConfiguration', 'Microsoft.ExtendedLocation',
    'Microsoft.AzureStackHCI', 'Microsoft.DeviceOnboarding', 'Microsoft.Edge',
    'Microsoft.GuestConfiguration', 'Microsoft.KeyVault', 'Microsoft.ManagedIdentity',
    'Microsoft.PolicyInsights', 'Microsoft.Storage', 'Microsoft.Insights'
)
foreach ($p in $providers) {
    Invoke-Az provider register --namespace $p --output none | Out-Null
    Write-Host "    $p"
}

Write-Step 'Installing Azure CLI extensions'
Invoke-Az extension add --name aksarc --upgrade --allow-preview true --output none | Out-Null
Invoke-Az extension add --name connectedk8s --upgrade --output none | Out-Null

Write-Step "Creating resource group $($s.ResourceGroup) in $($s.Location)"
Invoke-Az group create --name $s.ResourceGroup --location $s.Location --output none | Out-Null

if (-not $s.AdminGroupObjectId) {
    Write-Step "Creating Entra ID group $($s.AdminGroupName)"
    $existing = Invoke-Az ad group list --display-name $s.AdminGroupName --query '[0].id' --output tsv
    if ($existing) {
        $groupId = $existing
    } else {
        $groupId = Invoke-Az ad group create --display-name $s.AdminGroupName --mail-nickname $s.AdminGroupName --query id --output tsv
    }
    $me = Invoke-Az ad signed-in-user show --query id --output tsv
    $isMember = Invoke-Az ad group member check --group $groupId --member-id $me --query value --output tsv
    if ($isMember -ne 'true') {
        Invoke-Az ad group member add --group $groupId --member-id $me --output none | Out-Null
    }
    Write-Host ''
    Write-Host "    Admin group object ID: $groupId" -ForegroundColor Yellow
    Write-Host "    Put it into settings.psd1 as AdminGroupObjectId." -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Azure is ready. Next: run 1-New-EdgeVm.ps1 on the Hyper-V host.' -ForegroundColor Green
