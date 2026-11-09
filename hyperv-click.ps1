# Click at a position on a Hyper-V VM's screen (coordinates in the guest's 1920x1080 frame,
# or scale from a 1280x720 screenshot with -FromShot).
param([int]$X, [int]$Y, [string]$Name = "GogglesOS-Test", [switch]$FromShot, [switch]$Double)
$ErrorActionPreference = "Stop"
if ($FromShot) { $X = [int]($X * 1920 / 1280); $Y = [int]($Y * 1080 / 720) }
$ns = "root\virtualization\v2"
$vm = Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "ElementName='$Name'"
$mouse = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_SyntheticMouse
Invoke-CimMethod -InputObject $mouse -MethodName SetAbsolutePosition -Arguments @{ horizontalPosition = $X; verticalPosition = $Y } | Out-Null
Invoke-CimMethod -InputObject $mouse -MethodName ClickButton -Arguments @{ buttonIndex = 1 } | Out-Null
if ($Double) { Invoke-CimMethod -InputObject $mouse -MethodName ClickButton -Arguments @{ buttonIndex = 1 } | Out-Null }
