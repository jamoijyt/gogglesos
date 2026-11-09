# Send keyboard input to a Hyper-V VM (for scripted testing). Uses raw set-1 scancodes
# (US layout) because Msvm_Keyboard.TypeText arrives garbled in Linux guests.
#   .\hyperv-keys.ps1 -Text "ls -la`n"          type text (`n = Enter)
#   .\hyperv-keys.ps1 -Combo CtrlAltF3           switch to text console 3 (F1..F12)
param([string]$Name = "GogglesOS-Test", [string]$Text, [string]$Combo)
$ErrorActionPreference = "Stop"
$ns = "root\virtualization\v2"
$vm = Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "ElementName='$Name'"
$kb = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_Keyboard

$plain = @{}; $shift = @{}
$row = @{ 0x10='qwertyuiop'; 0x1E='asdfghjkl'; 0x2C='zxcvbnm' }
foreach ($start in $row.Keys) { $i = 0; foreach ($ch in $row[$start].ToCharArray()) { $plain[[string]$ch] = $start + $i; $shift[([string]$ch).ToUpper()] = $start + $i; $i++ } }
$i = 0; foreach ($ch in '1234567890'.ToCharArray()) { $plain[[string]$ch] = 0x02 + $i; $i++ }
$i = 0; foreach ($ch in '!@#$%^&*()'.ToCharArray()) { $shift[[string]$ch] = 0x02 + $i; $i++ }
$extra = @{ ' '=0x39; '-'=0x0C; '='=0x0D; '['=0x1A; ']'=0x1B; ';'=0x27; "'"=0x28; '`'=0x29; '\'=0x2B; ','=0x33; '.'=0x34; '/'=0x35 }
foreach ($k in $extra.Keys) { $plain[$k] = $extra[$k] }
$extraS = @{ '_'=0x0C; '+'=0x0D; '{'=0x1A; '}'=0x1B; ':'=0x27; '"'=0x28; '~'=0x29; '|'=0x2B; '<'=0x33; '>'=0x34; '?'=0x35 }
foreach ($k in $extraS.Keys) { $shift[$k] = $extraS[$k] }

function Send([byte[]]$codes) { Invoke-CimMethod -InputObject $kb -MethodName TypeScancodes -Arguments @{ scancodes = $codes } | Out-Null }

if ($Combo -match '^CtrlAltF(\d+)$') {
  $n = [int]$Matches[1]; $f = if ($n -le 10) { 0x3A + $n } else { 0x57 + ($n - 11) }
  Send @(0x1D, 0x38, $f, ($f -bor 0x80), 0xB8, 0x9D)
}
if ($Text) {
  foreach ($ch in $Text.ToCharArray()) {
    $c = [string]$ch
    if ($c -eq "`n") { Send @(0x1C, 0x9C) }
    elseif ($plain.ContainsKey($c) -and -not ($c -cmatch '[A-Z]')) { $s = $plain[$c]; Send @($s, ($s -bor 0x80)) }
    elseif ($shift.ContainsKey($c)) { $s = $shift[$c]; Send @(0x2A, $s, ($s -bor 0x80), 0xAA) }
    else { Write-Warning "no scancode for '$c'" }
  }
}
