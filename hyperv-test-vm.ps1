# Create (or recreate) a Hyper-V test VM that boots the Goggles OS ISO, then open its window.
# Needs Hyper-V enabled and membership of "Hyper-V Administrators" (or an admin shell).
#   .\hyperv-test-vm.ps1                      # default ISO
#   .\hyperv-test-vm.ps1 -Iso D:\path\x.iso   # another ISO
#   .\hyperv-test-vm.ps1 -Recreate            # wipe the VM and its disk first
param(
  [string]$Iso    = "D:\GogglesOS\output\gogglesos-26.04-nvidia-amd64.iso",
  [string]$Name   = "GogglesOS-Test",
  [string]$VmDir  = "D:\GogglesOS\vm",
  [int]$Cpus      = 4,
  [long]$MemoryGB = 6,
  [long]$DiskGB   = 64,
  [switch]$Recreate
)
$ErrorActionPreference = "Stop"
if (-not (Test-Path $Iso)) { throw "ISO not found: $Iso" }

$vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
if ($vm -and $Recreate) {
  if ($vm.State -ne 'Off') { Stop-VM -Name $Name -TurnOff -Force }
  $disks = (Get-VMHardDiskDrive -VMName $Name).Path
  Remove-VM -Name $Name -Force
  $disks | Where-Object { $_ } | ForEach-Object { Remove-Item $_ -Force -ErrorAction SilentlyContinue }
  $vm = $null
}

if (-not $vm) {
  New-Item -ItemType Directory -Force -Path $VmDir | Out-Null
  $switch = (Get-VMSwitch -Name "Default Switch" -ErrorAction SilentlyContinue).Name
  $vhd = Join-Path $VmDir "$Name.vhdx"
  $args = @{ Name = $Name; Generation = 2; MemoryStartupBytes = $MemoryGB * 1GB; Path = $VmDir
             NewVHDPath = $vhd; NewVHDSizeBytes = $DiskGB * 1GB }
  if ($switch) { $args.SwitchName = $switch }
  New-VM @args | Out-Null
  Set-VMProcessor -VMName $Name -Count $Cpus
  Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false
  # Ubuntu's shim is signed by the Microsoft UEFI CA (not the Windows CA)
  Set-VMFirmware -VMName $Name -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority
  Set-VM -Name $Name -AutomaticCheckpointsEnabled $false
  Set-VMVideo -VMName $Name -ResolutionType Single -HorizontalResolution 1920 -VerticalResolution 1080 -ErrorAction SilentlyContinue
  Add-VMDvdDrive -VMName $Name -Path $Iso
} else {
  if ($vm.State -ne 'Off') { Stop-VM -Name $Name -TurnOff -Force }
  Set-VMDvdDrive -VMName $Name -Path $Iso
}
# Boot from the DVD first
Set-VMFirmware -VMName $Name -FirstBootDevice (Get-VMDvdDrive -VMName $Name)

Start-VM -Name $Name
Start-Process vmconnect.exe -ArgumentList "localhost", "`"$Name`""
Write-Host "Started $Name from $Iso"
