# Shared helpers, dot-sourced by the numbered scripts.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Settings {
    param([string]$Path)
    if (-not $Path) { $Path = Join-Path $PSScriptRoot '..\settings.psd1' }
    if (-not (Test-Path $Path)) { throw "Settings file not found: $Path" }
    $s = Import-PowerShellDataFile -Path $Path
    if (-not $s.SshPublicKeyPath) {
        $s.SshPublicKeyPath = Join-Path $HOME '.ssh\aksbm_ed25519.pub'
    }
    if (-not [System.IO.Path]::IsPathRooted($s.OutputPath)) {
        $s.OutputPath = Join-Path (Split-Path $Path -Parent) $s.OutputPath
    }
    New-Item -ItemType Directory -Force -Path $s.OutputPath | Out-Null
    return $s
}

function Write-Step([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

# Runs the Azure CLI and throws if it fails. Returns parsed JSON when the
# output is JSON, otherwise the raw text.
# (Simple function using $args on purpose, so --flags pass straight through.)
function Invoke-Az {
    $out = & az @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az $($args -join ' ') failed:`n$(($out | ForEach-Object { "$_" }) -join "`n")"
    }
    $text = ($out | Where-Object { $_ -is [string] }) -join "`n"
    if ($text -match '^\s*[\[{]') {
        try { return $text | ConvertFrom-Json } catch { }
    }
    return $text
}

function Assert-AzCli {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) not found. Install it: winget install -e --id Microsoft.AzureCLI'
    }
    & az account show --output none 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Step 'Signing in to Azure'
        & az login --output none
        if ($LASTEXITCODE -ne 0) { throw 'az login failed' }
    }
}

function Set-AzSubscription($Settings) {
    if ($Settings.SubscriptionId) {
        Invoke-Az account set --subscription $Settings.SubscriptionId | Out-Null
    }
    $acct = Invoke-Az account show --output json
    Write-Host "    Subscription: $($acct.name) ($($acct.id))"
    return $acct
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script from an elevated PowerShell (Run as administrator).'
    }
}
