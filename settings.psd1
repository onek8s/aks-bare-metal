@{
    # ---------------------------------------------------------------------
    # Azure
    # ---------------------------------------------------------------------
    # Leave SubscriptionId empty to use the current `az account` subscription.
    SubscriptionId      = ''
    # The AKS on bare metal preview only supports East US.
    Location            = 'eastus'
    ResourceGroup       = 'rg-aks-bare-metal'

    # Entra ID group whose members get cluster-admin through Azure RBAC.
    # Leave empty and 0-Initialize-Azure.ps1 creates one and adds you to it.
    AdminGroupObjectId  = ''
    AdminGroupName      = 'aks-bare-metal-admins'

    # ---------------------------------------------------------------------
    # Hyper-V edge machine (one VM = one single-node cluster in the preview)
    # ---------------------------------------------------------------------
    VmName              = 'aksbm-edge01'
    # Where the VM files and its OS disk are stored.
    VmPath              = 'C:\Hyper-V\aks-bare-metal'
    # Maintenance environment ISO downloaded from the Azure portal
    # (Azure Arc > Azure Local > Get started > Try provisioning > View Downloads).
    MaintenanceIsoPath  = 'C:\Hyper-V\iso\maintenance-environment.iso'

    # Sizing. Docs minimum is 2 cores / 4 GB / 256 GB; these are the recommended values.
    VmProcessorCount    = 4
    VmMemoryGB          = 16
    VmDiskGB            = 256

    # Virtual switch. If it doesn't exist, an External switch is created on
    # NetAdapterName (find it with Get-NetAdapter). The VM needs outbound
    # HTTPS to Azure and a stable IP, so use a network with a DHCP reservation
    # for the VM's MAC address, or set a static IP in the Configurator app.
    SwitchName          = 'aksbm-external'
    NetAdapterName      = 'Ethernet'
    # Optional VLAN ID for the VM NIC. 0 = untagged.
    VlanId              = 0
    # Optional fixed MAC (for a DHCP reservation), e.g. '00155D0A0B01'. Empty = dynamic.
    MacAddress          = ''

    # Secure Boot template. Azure Linux is signed through the Microsoft UEFI CA.
    # If the maintenance ISO doesn't boot, try 'MicrosoftWindows'.
    SecureBootTemplate  = 'MicrosoftUEFICertificateAuthority'

    # ---------------------------------------------------------------------
    # AKS cluster
    # ---------------------------------------------------------------------
    # Name of the edge machine as it appears in Azure after provisioning
    # (the "Azure Arc resource name" you enter when adding the voucher).
    EdgeMachineName     = 'aksbm-edge01'
    ClusterName         = 'aksbm-cluster01'
    # Format Major.Minor.Patch-YYYYMMDD. See the docs for currently supported values.
    KubernetesVersion   = '1.34.3-20260204'
    # Optional. Unused IP in the edge machine's subnet; empty = auto/host IP.
    # Reserve it in DHCP so nothing else takes it.
    ControlPlaneIp      = ''
    # SSH public key used by the cluster. Empty = ~\.ssh\aksbm_ed25519.pub,
    # created with ssh-keygen if missing.
    SshPublicKeyPath    = ''
    # Extras are off to keep the cluster minimal.
    EnableAzurePolicy         = $false
    EnableContainerMonitoring = $false
    LogAnalyticsWorkspaceId   = ''

    # ARM template from Microsoft's Azure/aksArc repository.
    ArmTemplateUrl      = 'https://raw.githubusercontent.com/Azure/aksArc/main/deploymentTemplates/aks-baremetal-arm/aks-baremetal-arm.json'

    # ---------------------------------------------------------------------
    # BETA: multi-node cluster (scripts\beta). Not supported by the preview.
    # ---------------------------------------------------------------------
    MultiNode = @{
        # One Hyper-V VM per node. Edge machine names in Azure default to the
        # same names (set the Arc resource name to these when adding vouchers).
        VmNames           = @('aksbm-node01', 'aksbm-node02', 'aksbm-node03', 'aksbm-node04')
        ClusterName       = 'aksbm-multi01'
        # 1, 3 or 5. With 4 machines and 3 control plane nodes you get 1 worker.
        ControlPlaneCount = 3
        # -1 = every machine not used for the control plane becomes a worker.
        WorkerCount       = -1
        # REQUIRED for more than one machine: unused, reserved IP in the
        # machines' subnet, not equal to any machine's own IP.
        ControlPlaneIp    = ''
        PodCidr           = '10.244.0.0/16'
    }

    # Where kubeconfig and downloaded files are written.
    OutputPath          = '.\out'
}
