# Save a screenshot of a running Hyper-V VM's screen to a PNG (uses the Hyper-V thumbnail API).
param([string]$Name = "GogglesOS-Test", [string]$Out = "preview\hyperv.png", [int]$Width = 1280, [int]$Height = 720)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$ns  = "root\virtualization\v2"
$vm  = Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "ElementName='$Name'"
$set = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_VirtualSystemSettingData |
       Where-Object { $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' }
$svc = Get-CimInstance -Namespace $ns -ClassName Msvm_VirtualSystemManagementService
$r = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage `
       -Arguments @{ TargetSystem = $set; WidthPixels = [uint16]$Width; HeightPixels = [uint16]$Height }
if ($r.ReturnValue -ne 0) { throw "thumbnail failed: $($r.ReturnValue)" }
# Image data is RGB565
$bytes = [byte[]]$r.ImageData
$bmp = New-Object System.Drawing.Bitmap $Width, $Height, ([System.Drawing.Imaging.PixelFormat]::Format16bppRgb565)
$rect = New-Object System.Drawing.Rectangle 0, 0, $Width, $Height
$data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, $bmp.PixelFormat)
[System.Runtime.InteropServices.Marshal]::Copy($bytes, 0, $data.Scan0, [Math]::Min($bytes.Length, $data.Stride * $Height))
$bmp.UnlockBits($data)
$full = [IO.Path]::GetFullPath((Join-Path (Get-Location) $Out))
New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null
$bmp.Save($full, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
Write-Host "saved $full"
