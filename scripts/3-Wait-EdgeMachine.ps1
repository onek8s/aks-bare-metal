<#
.SYNOPSIS
    Waits until the edge machine resource in Azure finishes provisioning.

.DESCRIPTION
    After you add the voucher in the portal, the VM calls home, downloads
    Azure Linux, installs it and connects to Azure Arc. That shows up as a
    Microsoft.AzureStackHCI/edgeMachines resource. This script polls it and
    prints whatever status fields it exposes, until it reports a finished
    state or the timeout passes.

    The exact status field names for this preview resource aren't documented,
    so the script looks at provisioningState and any property whose name
    contains "status" or "state". Cross-check in the portal:
    Azure Arc > Operations > Provisioning (preview) > Provisioned machines.
#>
[CmdletBinding()]
param(
    [string]$SettingsPath,
    [string]$EdgeMachineName,
    [int]$TimeoutMinutes = 120,
    [int]$PollSeconds = 60
)

. (Join-Path $PSScriptRoot 'common.ps1')
$s = Get-Settings $SettingsPath
if ($EdgeMachineName) { $s.EdgeMachineName = $EdgeMachineName }
Assert-AzCli
Set-AzSubscription $s | Out-Null

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$done = $false
Write-Step "Waiting for edge machine '$($s.EdgeMachineName)' in '$($s.ResourceGroup)'"

while ((Get-Date) -lt $deadline) {
    $json = & az resource show --resource-group $s.ResourceGroup --name $s.EdgeMachineName `
        --resource-type 'Microsoft.AzureStackHCI/edgeMachines' --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) {
        Write-Host "    $(Get-Date -Format T)  not found yet"
    } else {
        $res = ($json -join "`n") | ConvertFrom-Json
        $props = $res.properties
        $states = @()
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -match 'state|status' -and $p.Value -isnot [System.Management.Automation.PSCustomObject]) {
                $states += "$($p.Name)=$($p.Value)"
            }
        }
        Write-Host "    $(Get-Date -Format T)  $($states -join '  ')"
        $values = @($props.PSObject.Properties | Where-Object { $_.Name -match 'state|status' } | ForEach-Object { "$($_.Value)" })
        if ($values -match '^(Provisioned|ReadyToCluster|Ready to cluster)$') { $done = $true; break }
        if ($values -match '^Failed$') { throw "Edge machine reports Failed. Check the portal for details." }
    }
    Start-Sleep -Seconds $PollSeconds
}

if ($done) {
    Write-Host ''
    Write-Host 'Edge machine is provisioned. Next: run 4-New-AksCluster.ps1.' -ForegroundColor Green
} else {
    Write-Warning "Timed out after $TimeoutMinutes minutes. If the portal already shows the machine as Provisioned, continue with 4-New-AksCluster.ps1."
}
