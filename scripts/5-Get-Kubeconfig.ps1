<#
.SYNOPSIS
    Downloads a kubeconfig for the cluster and runs `kubectl get nodes`.

.DESCRIPTION
    Uses Entra ID (Azure RBAC) credentials, so you must be a member of the
    admin group. If the cluster's API server isn't reachable from where
    you run this, use -Proxy: it starts `az connectedk8s proxy` (keep that
    window open) and kubectl goes through Azure Arc instead.

    Don't run this from Azure Cloud Shell (MSI token audience error).
#>
[CmdletBinding()]
param(
    [string]$SettingsPath,
    [switch]$Proxy
)

. (Join-Path $PSScriptRoot 'common.ps1')
$s = Get-Settings $SettingsPath
Assert-AzCli
Set-AzSubscription $s | Out-Null

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-Step 'Installing kubectl and kubelogin'
    & az aks install-cli
    if ($LASTEXITCODE -ne 0) { throw 'az aks install-cli failed. Install kubectl manually: winget install -e --id Kubernetes.kubectl' }
    Write-Warning 'kubectl was just installed; open a new terminal if it is not found on PATH.'
}

$kubeconfig = Join-Path $s.OutputPath "$($s.ClusterName).kubeconfig"

if ($Proxy) {
    Write-Step 'Starting az connectedk8s proxy in a new window (leave it open)'
    $azArgs = "connectedk8s proxy --name $($s.ClusterName) --resource-group $($s.ResourceGroup) --file `"$kubeconfig`""
    Start-Process -FilePath 'az' -ArgumentList $azArgs
    Start-Sleep -Seconds 20
} else {
    Write-Step "Fetching kubeconfig to $kubeconfig"
    Invoke-Az aksarc get-credentials --resource-group $s.ResourceGroup --name $s.ClusterName `
        --file $kubeconfig --overwrite-existing | Out-Null
}

Write-Step 'kubectl get nodes'
& kubectl --kubeconfig $kubeconfig get nodes -o wide

Write-Host ''
Write-Host "Use the cluster with:  `$env:KUBECONFIG = '$kubeconfig'" -ForegroundColor Green
