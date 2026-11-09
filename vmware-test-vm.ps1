# Create (or reuse) a VMware Workstation test VM that boots the Goggles OS ISO, then start it.
#   .\vmware-test-vm.ps1                 # default ISO, reuse VM if it exists
#   .\vmware-test-vm.ps1 -Recreate       # delete the VM and its disk first
#   .\vmware-test-vm.ps1 -Iso D:\x.iso
param(
  [string]$Iso    = "D:\GogglesOS\output\gogglesos-26.04-nvidia-amd64.iso",
  [string]$Name   = "GogglesOS-Test",
  [string]$VmRoot = "D:\GogglesOS\vmware",
  [int]$Cpus      = 4,
  [int]$MemoryMB  = 6144,
  [int]$DiskGB    = 64,
  [switch]$Recreate
)
$ErrorActionPreference = "Stop"
$ws = @("${env:ProgramFiles(x86)}\VMware\VMware Workstation", "$env:ProgramFiles\VMware\VMware Workstation") |
      Where-Object { Test-Path "$_\vmrun.exe" } | Select-Object -First 1
if (-not $ws) { throw "VMware Workstation not found" }
if (-not (Test-Path $Iso)) { throw "ISO not found: $Iso" }

$dir = Join-Path $VmRoot $Name
$vmx = Join-Path $dir "$Name.vmx"
$vmdk = Join-Path $dir "$Name.vmdk"

if ($Recreate -and (Test-Path $dir)) {
  & "$ws\vmrun.exe" -T ws stop $vmx hard 2>$null | Out-Null
  Remove-Item -Recurse -Force $dir
}

if (-not (Test-Path $vmx)) {
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  & "$ws\vmware-vdiskmanager.exe" -c -s "${DiskGB}GB" -a lsilogic -t 0 $vmdk | Out-Null
  @"
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "21"
displayName = "$Name"
guestOS = "ubuntu-64"
firmware = "efi"
uefi.secureBoot.enabled = "TRUE"
numvcpus = "$Cpus"
cpuid.coresPerSocket = "$Cpus"
memsize = "$MemoryMB"
mks.enable3d = "TRUE"
svga.graphicsMemoryKB = "4194304"
scsi0.present = "TRUE"
scsi0.virtualDev = "pvscsi"
scsi0:0.present = "TRUE"
scsi0:0.fileName = "$Name.vmdk"
sata0.present = "TRUE"
sata0:1.present = "TRUE"
sata0:1.deviceType = "cdrom-image"
sata0:1.fileName = "$Iso"
sata0:1.startConnected = "TRUE"
ethernet0.present = "TRUE"
ethernet0.connectionType = "nat"
ethernet0.virtualDev = "vmxnet3"
ethernet0.addressType = "generated"
usb.present = "TRUE"
ehci.present = "TRUE"
usb_xhci.present = "TRUE"
sound.present = "TRUE"
sound.virtualDev = "hdaudio"
sound.autoDetect = "TRUE"
tools.syncTime = "TRUE"
"@ | Set-Content -Encoding UTF8 $vmx
} else {
  # point the CD at the (possibly rebuilt) ISO and make sure it's connected
  $c = Get-Content $vmx | Where-Object { $_ -notmatch '^sata0:1\.(fileName|startConnected)' }
  $c + "sata0:1.fileName = `"$Iso`"" + 'sata0:1.startConnected = "TRUE"' | Set-Content -Encoding UTF8 $vmx
}

& "$ws\vmrun.exe" -T ws start $vmx gui
Write-Host "Started $Name ($vmx)"
