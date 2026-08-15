#Requires -RunAsAdministrator
#Requires -Modules Hyper-V

<#
.SYNOPSIS
    Creates the Talos VM on Hyper-V, ready for talosctl.

.DESCRIPTION
    Run this from an elevated PowerShell prompt on the Windows host. It creates an
    external virtual switch if one does not exist, downloads the Talos ISO built from
    this repository's Image Factory schematic, and creates a Generation 2 VM sized for a
    single-node cluster.

    It stops short of applying any Talos configuration. When it finishes, the VM is
    sitting in maintenance mode waiting for `talosctl apply-config` from the workstation.

.PARAMETER NetAdapterName
    Physical network adapter to bind the external switch to. Only needed the first time,
    or if you have more than one. Run Get-NetAdapter to see the options.

.EXAMPLE
    .\New-TalosVM.ps1
    Uses an existing external switch if there is exactly one.

.EXAMPLE
    .\New-TalosVM.ps1 -NetAdapterName "Ethernet" -MemoryGB 24
#>

[CmdletBinding()]
param(
    [string] $VMName = "talos-1",
    [string] $SwitchName = "talos-external",
    [string] $NetAdapterName,
    [int]    $CpuCount = 4,
    [int]    $MemoryGB = 20,
    [int]    $BootDiskGB = 100,
    [int]    $DataDiskGB = 200,
    [string] $TalosVersion = "v1.13.8",
    [string] $SchematicId = "4a0d65c669d46663f377e7161e50cfd570c401f26fd9e7bda34a0216b6f1922b",
    [string] $VMPath,
    [switch] $Force
)

$ErrorActionPreference = "Stop"

function Write-Step { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Note { param($m) Write-Host "    $m" -ForegroundColor DarkGray }
function Write-Ok   { param($m) Write-Host "    $m" -ForegroundColor Green }

Write-Step "Checking Hyper-V"
$feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
if ($feature.State -ne "Enabled") {
    throw "Hyper-V is not enabled. Run: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All, then reboot."
}
Write-Ok "Hyper-V is enabled"

if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    if (-not $Force) {
        throw "A VM named '$VMName' already exists. Re-run with -Force to delete and recreate it, or pass a different -VMName."
    }
    Write-Step "Removing the existing '$VMName'"
    Stop-VM -Name $VMName -TurnOff -Force -ErrorAction SilentlyContinue
    $old = Get-VMHardDiskDrive -VMName $VMName -ErrorAction SilentlyContinue
    Remove-VM -Name $VMName -Force
    foreach ($d in $old) { Remove-Item -LiteralPath $d.Path -Force -ErrorAction SilentlyContinue }
    Write-Ok "Removed"
}

# The Default Switch is deliberately not an option here: it NATs, and it renumbers its
# subnet across host reboots, which breaks the API endpoint and the gateway IP together.
Write-Step "Setting up the external virtual switch"
$switch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
if (-not $switch) {
    $external = @(Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue)
    if ($external.Count -eq 1 -and -not $NetAdapterName) {
        $switch = $external[0]
        Write-Ok "Reusing the existing external switch '$($switch.Name)'"
    }
    else {
        if (-not $NetAdapterName) {
            Write-Host "`n    No external switch to reuse. Available adapters:" -ForegroundColor Yellow
            Get-NetAdapter | Where-Object Status -eq "Up" |
                Format-Table -AutoSize Name, InterfaceDescription, LinkSpeed | Out-String | Write-Host
            throw "Re-run with -NetAdapterName '<name from the list above>'."
        }
        Write-Note "Creating '$SwitchName' on '$NetAdapterName'"
        Write-Note "The host network drops for a few seconds while this binds."
        $switch = New-VMSwitch -Name $SwitchName -NetAdapterName $NetAdapterName -AllowManagementOS $true
        Write-Ok "Created"
    }
}
else {
    if ($switch.SwitchType -ne "External") {
        throw "Switch '$SwitchName' exists but is $($switch.SwitchType), not External. An internal or private switch cannot give the VM a LAN address."
    }
    Write-Ok "Using the existing '$SwitchName'"
}

if (-not $VMPath) { $VMPath = (Get-VMHost).VirtualMachinePath }
$vmDir  = Join-Path $VMPath $VMName
$isoDir = Join-Path $VMPath "iso"
New-Item -ItemType Directory -Force -Path $vmDir, $isoDir | Out-Null

Write-Step "Fetching the Talos ISO"
$isoName = "talos-$TalosVersion-$($SchematicId.Substring(0,12)).iso"
$isoPath = Join-Path $isoDir $isoName
if (Test-Path $isoPath) {
    Write-Ok "Already downloaded: $isoPath"
}
else {
    $isoUrl = "https://factory.talos.dev/image/$SchematicId/$TalosVersion/metal-amd64.iso"
    Write-Note $isoUrl
    Write-Note "This image has the Tailscale system extension baked in, which is how the"
    Write-Note "node stays reachable when the cluster itself is broken."
    $progress = $ProgressPreference
    $ProgressPreference = "SilentlyContinue"
    try   { Invoke-WebRequest -Uri $isoUrl -OutFile $isoPath -UseBasicParsing }
    finally { $ProgressPreference = $progress }
    Write-Ok "Downloaded to $isoPath"
}

Write-Step "Creating the VM"
$bootVhd = Join-Path $vmDir "$VMName-boot.vhdx"
$dataVhd = Join-Path $vmDir "$VMName-data.vhdx"

New-VM -Name $VMName -Generation 2 -MemoryStartupBytes ($MemoryGB * 1GB) `
       -NewVHDPath $bootVhd -NewVHDSizeBytes ($BootDiskGB * 1GB) `
       -SwitchName $switch.Name -Path $VMPath | Out-Null

New-VHD -Path $dataVhd -SizeBytes ($DataDiskGB * 1GB) -Dynamic | Out-Null
Add-VMHardDiskDrive -VMName $VMName -Path $dataVhd

# Fixed, not dynamic. Kubernetes handles memory being taken away underneath it badly.
Set-VMMemory   -VMName $VMName -DynamicMemoryEnabled $false -StartupBytes ($MemoryGB * 1GB)
Set-VMProcessor -VMName $VMName -Count $CpuCount

# Talos images are not signed for the Microsoft UEFI CA that Hyper-V trusts by default.
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off

Add-VMDvdDrive -VMName $VMName -Path $isoPath
$dvd = Get-VMDvdDrive -VMName $VMName
Set-VMFirmware -VMName $VMName -FirstBootDevice $dvd

# So a Windows Update reboot brings the cluster back without anyone noticing.
Set-VM -Name $VMName -AutomaticStartAction Start -AutomaticStartDelay 30 `
       -AutomaticStopAction ShutDown -CheckpointType Production

Write-Ok "Created '$VMName': $CpuCount vCPU, ${MemoryGB}GB fixed, ${BootDiskGB}GB boot, ${DataDiskGB}GB data"

Write-Step "Starting it"
Start-VM -Name $VMName
Write-Note "Waiting for an address. Talos boots into maintenance mode with no disk install."
Write-Note "Talos doesn't run the Hyper-V KVP daemon, so this almost always times out below."
Write-Note "That's expected, not a fault. See the fallback instructions once it does."

$ip = $null
foreach ($i in 1..40) {
    Start-Sleep -Seconds 5
    $ip = (Get-VMNetworkAdapter -VMName $VMName).IPAddresses |
          Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' } |
          Select-Object -First 1
    if ($ip) { break }
}

Write-Host ""
if ($ip) {
    Write-Ok "VM is up at $ip"
    Write-Host @"

Next, from the workstation (not here):

  1. Note the address:            $ip
  2. Give it a DHCP reservation on your router so it does not move.
  3. Generate and apply the machine config:

       talosctl apply-config --insecure --nodes $ip --file talos/clusterconfig/talos-1.yaml

  4. Then bootstrap etcd. This runs once, ever:

       talosctl bootstrap --nodes $ip

See docs/bootstrap.md for the full sequence and what each step is for.
"@ -ForegroundColor White
}
else {
    Write-Host "    No address reported yet." -ForegroundColor Yellow
    Write-Host @"

This is a known false negative, not a sign anything went wrong. Hyper-V learns guest
addresses through integration services (KVP), and Talos doesn't run that daemon, so
this branch fires on effectively every boot regardless of whether the VM is healthy.
Confirmed 2026-08-15: a VM that hit this exact message was reachable over the LAN and
answering talosctl within a minute of boot. Check the real address by either:

  - Opening the console:  vmconnect.exe localhost $VMName
    Talos prints its address on the boot screen.
  - Looking at your router's DHCP lease table for a new client.

Once you have the address, carry on from step 2 in docs/bootstrap.md.
"@ -ForegroundColor White
}
