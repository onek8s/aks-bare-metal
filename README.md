# aks-bare-metal

Scripts for trying **AKS on bare metal (preview)** with **Azure Linux 3.0** as
the host OS, using a Hyper-V VM as the "bare metal" edge machine.

The result is the smallest cluster the preview allows: **one VM, one
single-node cluster** (the preview doesn't support multi-node clusters or
more than one cluster per host).

> **Read this first.** AKS on bare metal with Azure Linux is documented for
> Microsoft-validated small form factor hardware (ASUS NUC, Lenovo ThinkEdge,
> OnLogic, ...). Microsoft's docs don't say whether a Hyper-V VM works as the
> edge machine. These scripts give the VM what the provisioning flow asks
> for (UEFI, Secure Boot, TPM 2.0, 256 GB disk, outbound HTTPS), but running
> it in a VM is an experiment, not a supported setup. The preview is East US
> only and not for production.

## How it works

```
Hyper-V host                                Azure (East US)
────────────                                ───────────────
1  VM boots maintenance ISO  ──voucher──▶   3  Site + voucher in portal
                                               (pick Azure Linux / AKS)
   VM calls home, installs   ◀──────────    edgeMachines resource
   Azure Linux, joins Arc                     → Provisioned
                                            4  ARM template: device pool,
                                               logical network, cluster
5  kubectl  ◀──────────── kubeconfig (Entra ID / Azure RBAC)
```

| Step | Script | Where | What |
|---|---|---|---|
| 0 | `scripts/0-Initialize-Azure.ps1` | any PC with Azure CLI | Preview features, resource providers, CLI extensions, resource group, Entra admin group |
| 1 | `scripts/1-New-EdgeVm.ps1` | Hyper-V host (admin) | Gen 2 VM with Secure Boot + vTPM, boots the maintenance environment ISO |
| 2 | `scripts/2-Get-EdgeVmInfo.ps1` | Hyper-V host (admin) | Serial number, MAC and IP for fetching the voucher; `-EjectIso` afterwards |
| 3 | portal + `scripts/3-Wait-EdgeMachine.ps1` | portal / any PC | Register the voucher, then wait for the machine to be Provisioned |
| 4 | `scripts/4-New-AksCluster.ps1` | any PC with Azure CLI | Deploys Microsoft's [ARM template](https://github.com/Azure/aksArc/tree/main/deploymentTemplates/aks-baremetal-arm) (~20 min) |
| 5 | `scripts/5-Get-Kubeconfig.ps1` | any PC with Azure CLI | kubeconfig + `kubectl get nodes` |
| – | `scripts/9-Remove-All.ps1` | either | Clean up the cluster, edge machine, resource group and/or VM |

All settings are in [`settings.psd1`](settings.psd1). Downloads, generated
parameter files and the kubeconfig go to `.\out\`.

## Prerequisites

- Windows Server or Windows 11 with Hyper-V, and PowerShell 5.1 or 7.x.
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli-windows) 2.90.0 or later (`winget install -e --id Microsoft.AzureCLI`).
- An Azure subscription where you are **Owner**, or **Contributor + User
  Access Administrator** (active, permanent assignments) on the resource group,
  and can create Entra ID groups (or have one already).
- Access to the preview. If feature registration stays pending, sign up at
  <https://aka.ms/aks-edge-baremetal>.
- A network for the VM with DHCP (ideally a reservation) or a static IP, and
  outbound HTTPS (TCP 443) to at least:
  `*.arc.azure.net`, `management.azure.com`, `login.microsoftonline.com`,
  `mcr.microsoft.com`, `*.data.mcr.microsoft.com`, `guestnotificationservice.azure.com`.
- About 4 vCPU, 16 GB RAM and 256 GB disk free for the VM (docs minimum is
  2 cores / 4 GB / 256 GB).

## Steps

Clone the repo on the Hyper-V host, then edit `settings.psd1` (at least
`NetAdapterName` or `SwitchName`, and `MaintenanceIsoPath`).

If script execution is blocked, run `Set-ExecutionPolicy -Scope Process Bypass`
in that PowerShell window first.

### 0. Prepare Azure

```powershell
.\scripts\0-Initialize-Azure.ps1
```

Copy the admin group object ID it prints into `AdminGroupObjectId` in
`settings.psd1`.

Then download the provisioning software: **Azure portal > Azure Arc > Azure
Local > Get started > Try provisioning (preview) > Download and install > View
Downloads**. It contains the **maintenance environment ISO**, the USB
preparation tool (not needed for a VM; the ISO is attached directly) and the
**Configurator App for Azure Local V2**. Put the ISO at `MaintenanceIsoPath`
and install the Configurator app on a Windows PC that can reach the VM's network.

### 1. Create the edge VM

```powershell
.\scripts\1-New-EdgeVm.ps1          # -Force re-creates it
vmconnect.exe localhost aksbm-edge01
```

Wait for the console to show **Maintenance environment setup completed
successfully**. The VM reboots about twice; it can take up to 30 minutes.

If the ISO doesn't boot (Secure Boot violation), set
`SecureBootTemplate = 'MicrosoftWindows'` and re-run with `-Force`.

### 2. Get the voucher

```powershell
.\scripts\2-Get-EdgeVmInfo.ps1 -EjectIso
```

It prints the VM's BIOS serial number, MAC and IP. Open **Configurator App
for Azure Local V2** as administrator, connect to `<serial>.local` or the IP,
sign in with the default `edgeuser` / `Password1`, and download the
ownership voucher (`<serial>.pem`). You can also set a static IP there.

### 3. Provision the machine with Azure Linux

In the portal: **Azure Arc > Azure Local > Get started > Try provisioning
(preview) > Provision**:

1. Create a site in your resource group and set time zone / time server.
2. Add the voucher, choose the **Azure Linux (AKS for Azure Local on Linux)**
   software version, and set local admin credentials (12+ characters, upper,
   lower, digit, special).
3. Edit the machine and set its Azure Arc resource name to `EdgeMachineName`
   from `settings.psd1` (default `aksbm-edge01`). Review + create.

The VM then downloads and installs Azure Linux and connects to Azure Arc.
Watch it in **Azure Arc > Operations > Provisioning (preview) > Provisioned
machines**, or:

```powershell
.\scripts\3-Wait-EdgeMachine.ps1
```

Continue when the machine shows **Provisioned**.

### 4. Create the cluster

```powershell
.\scripts\4-New-AksCluster.ps1
```

Creates an SSH key if needed, downloads Microsoft's ARM template, writes
`out\aks-baremetal-arm.parameters.json` and runs `az deployment group create`.
Azure Policy and Container Insights are off by default (`EnableAzurePolicy`,
`EnableContainerMonitoring`). Check supported `KubernetesVersion` values in
the [docs](https://learn.microsoft.com/azure/aks-hybrid-edge/bare-metal/aks-bare-metal-create-cluster-arm-template).

The portal route also works: **Azure Arc > Operations > Machine provisioning
(preview) > 3. Deploy cluster > Deploy > AKS for Azure Local on Linux**.

### 5. Use the cluster

```powershell
.\scripts\5-Get-Kubeconfig.ps1           # direct, via az aksarc get-credentials
.\scripts\5-Get-Kubeconfig.ps1 -Proxy    # through Azure Arc (az connectedk8s proxy)
$env:KUBECONFIG = "$PWD\out\aksbm-cluster01.kubeconfig"
kubectl get nodes
```

Use `-Proxy` when your PC can't reach the cluster's control plane IP directly.

### Clean up

```powershell
.\scripts\9-Remove-All.ps1                      # cluster resources only
.\scripts\9-Remove-All.ps1 -EdgeMachine -Vm     # also the Azure machine + Hyper-V VM
.\scripts\9-Remove-All.ps1 -ResourceGroup -Vm   # everything
```

Each step asks for confirmation (add `-Confirm:$false` to skip).

## BETA: multi-node cluster (experimental)

> The AKS on bare metal preview says multi-node clusters are **not
> supported**. This section is an experiment to see whether the resource
> provider accepts them anyway. It has not been run.

**How AKS on Azure Local does it.** The same API
(`Microsoft.HybridContainerService/provisionedClusterInstances`) describes
multi-node clusters with:

- `controlPlane.count`: 1, 3 or 5 (odd, for etcd quorum)
- `controlPlane.controlPlaneEndpoint.hostIP`: one control plane VIP per
  cluster, separate from the node IPs
- `agentPoolProfiles[]`: worker pools with `count`, `osType: Linux`,
  `osSKU: CBLMariner` (Azure Linux) and, on Azure Local, a `vmSize`

On Azure Local the nodes are VMs that the platform creates. On bare metal
each node is a whole machine, and the machines come from the device pool
(`Microsoft.AzureStackHCI/devicePools`, whose `devices[]` is a list). The
API has no field that maps a node to a machine, so which machine becomes a
control plane or a worker node is up to the resource provider.

**What the beta template changes.**
[`templates/aks-baremetal-multinode.json`](templates/aks-baremetal-multinode.json)
is Microsoft's template with these changes:

| | Microsoft's template | Beta template |
|---|---|---|
| Machines | `edgeMachineName` (one) | `edgeMachineNames` (array), all in one device pool |
| Role assignments | Edge Machine Contributor on one machine | the same, on every machine (copy loop) |
| `controlPlane.count` | hard-coded 1 | `controlPlaneCount` parameter (1/3/5, default 3) |
| `agentPoolProfiles` | `[]` | `nodepool1` with `count` = machines left after the control plane (`workerCount`, -1 = auto) |
| Control plane IP | optional, defaults to host IP | required with more than one machine (a VIP) |
| Pod CIDR | hard-coded | `podCidr` parameter |
| Device pool / custom location | named after the machine | `<cluster>-pool` / `<cluster>-cl` |

**Try it.**

1. Fill in `MultiNode` in `settings.psd1`. You need at least 3 VMs for 3
   control plane nodes, plus one per worker. Also set `ControlPlaneIp` to an
   unused IP in the VMs' subnet and reserve it in DHCP.
2. Create the VMs: `.\scripts\beta\New-EdgeVms.ps1`
3. For each VM, get its voucher with
   `.\scripts\2-Get-EdgeVmInfo.ps1 -VmName <name> -EdgeMachineName <name> -EjectIso`.
   Register all the vouchers in the same site, using the VM names as the
   Arc resource names. Then wait with
   `.\scripts\3-Wait-EdgeMachine.ps1 -EdgeMachineName <name>`.
4. Preview what ARM would deploy: `.\scripts\beta\New-AksMultiNodeCluster.ps1 -WhatIf`
5. Deploy: `.\scripts\beta\New-AksMultiNodeCluster.ps1`. It prints
   `kubectl get nodes` at the end.

Clean up with `.\scripts\9-Remove-All.ps1 -ResourceGroup -Vm`, then
delete the other VMs with `Remove-VM`. The single-node cleanup uses the
single-node resource names, so remove a beta cluster by deleting the
resource group.

**Likely outcomes**, from most to least likely:

- The deployment is rejected because the preview validates
  `controlPlane.count == 1` or allows only one device per pool.
- It succeeds but only one machine joins.
- It works. If so, please report it in
  [Azure/aksArc issues](https://github.com/Azure/aksArc/issues).

## Notes and limits (preview)

- East US only; single-node clusters only; Kubernetes 1.34 on Azure Linux;
  Cilium CNI; patch upgrades through the portal.
- The control plane IP defaults to the host's IP. To use a separate one, set
  `ControlPlaneIp` to an unused address in the VM's subnet and reserve it.
- AKS cluster meters are zero-rated during the preview, but Arc and other
  Azure services may still be billed.
- Preview clusters may not upgrade in place to GA.

## Status

Written from Microsoft's documentation as of November 2026. **Not yet run
end-to-end on Hyper-V.** Expect the provisioning step (3) to be the part most
likely to behave differently on a VM. Fixes welcome.

## References

- [What is AKS on bare metal?](https://learn.microsoft.com/azure/aks-hybrid-edge/bare-metal/aks-bare-metal-overview)
- [Preview limitations](https://learn.microsoft.com/azure/aks-hybrid-edge/bare-metal/aks-bare-metal-preview-limitations)
- [System requirements](https://learn.microsoft.com/azure/aks-hybrid-edge/bare-metal/aks-bare-metal-system-requirements)
- [Create a cluster with an ARM template](https://learn.microsoft.com/azure/aks-hybrid-edge/bare-metal/aks-bare-metal-create-cluster-arm-template)
- [Connect to the cluster](https://learn.microsoft.com/azure/aks-hybrid-edge/bare-metal/aks-bare-metal-connect-to-cluster)
- [Simplified machine provisioning](https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provisioning)
- [Azure Local small form factor](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-overview)
