#Requires -Version 5.1
<#
.SYNOPSIS
    Checks the layout key by key against Apple's macOS "Russian - QWERTY".

.DESCRIPTION
    tests\macos-russian-qwerty.json lists, for every Mac key, the PC scancode it
    is placed on and what macOS types in each modifier state (transcribed from
    Apple's own layout data, see docs\sources.md). It also lists the Windows
    control characters the layout must keep.

    -Mode Tables     (default) evaluates the tables dumped by Test-Tables.ps1
                     (out\test\tables.txt) with the rules win32k applies:
                     SGCAPS rows, CAPLOK/CAPLOKALTGR, modifier columns.
    -Mode Installed  asks Windows itself: loads the installed layout and calls
                     ToUnicodeEx for every key and modifier state.

    Apple state -> Windows keys: Option = AltGr (Right Alt, i.e. Ctrl+Alt),
    Caps = Caps Lock toggled on. Windows-only states that the spec does not
    list are checked too: Ctrl and Shift+Ctrl must type nothing (or, for
    letters, the control character Windows derives), and Alt / Shift+Alt must
    type the same as base / Shift (Windows ignores a lone Alt).
#>
[CmdletBinding()]
param(
    [ValidateSet('Tables', 'Installed')]
    [string]$Mode = 'Tables',
    [string]$Spec,
    [string]$Dump,
    [string]$LayoutFile = 'kbdrumph.dll'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Defaults are set here because $PSScriptRoot is empty in parameter defaults
# when Windows PowerShell runs a script with -File.
if (-not $Spec) { $Spec = Join-Path $PSScriptRoot 'macos-russian-qwerty.json' }
if (-not $Dump) { $Dump = Join-Path $PSScriptRoot '..\out\test\tables.txt' }

$SHIFT = 1; $CTRL = 2; $ALT = 4
# Apple modifier state -> Windows modifier bits and Caps Lock.
$States = [ordered]@{
    base            = @{ Bits = 0; Caps = $false }
    shift           = @{ Bits = $SHIFT; Caps = $false }
    caps            = @{ Bits = 0; Caps = $true }
    capsShift       = @{ Bits = $SHIFT; Caps = $true }
    option          = @{ Bits = $CTRL + $ALT; Caps = $false }
    shiftOption     = @{ Bits = $SHIFT + $CTRL + $ALT; Caps = $false }
    capsOption      = @{ Bits = $CTRL + $ALT; Caps = $true }
    capsShiftOption = @{ Bits = $SHIFT + $CTRL + $ALT; Caps = $true }
    ctrl            = @{ Bits = $CTRL; Caps = $false }
    shiftCtrl       = @{ Bits = $SHIFT + $CTRL; Caps = $false }
    alt             = @{ Bits = $ALT; Caps = $false }
    shiftAlt        = @{ Bits = $SHIFT + $ALT; Caps = $false }
}

function ConvertFrom-CodePoints([string]$Value) {
    # "U+0444 U+0445" -> string; "" -> no output
    if (-not $Value) { return '' }
    -join @($Value.Split(' ') | Where-Object { $_ } | ForEach-Object { [char][Convert]::ToInt32($_.Substring(2), 16) })
}

function Format-CodePoints($Text) {
    # Untyped on purpose: [string] would turn $null (a dead key) into ''.
    if ($null -eq $Text) { return '<dead>' }
    if ($Text.Length -eq 0) { return '(none)' }
    (@($Text.ToCharArray() | ForEach-Object { 'U+{0:X4}' -f [int]$_ }) -join ' ') + " '$Text'"
}

# ---------------------------------------------------------------- tables mode
function Read-Dump([string]$Path) {
    if (-not (Test-Path $Path)) { throw "Missing $Path - run tests\Test-Tables.ps1 first." }
    $d = @{ Mods = @{}; Vk = @{}; Tables = New-Object System.Collections.Generic.List[object]; Dead = @{} }
    $section = ''
    $table = $null
    foreach ($line in Get-Content $Path) {
        if ($line.StartsWith('[')) {
            $section = $line.Trim('[', ']')
            if ($section -like 'chars *') {
                $table = @{ N = [int]$section.Substring(6); Rows = New-Object System.Collections.Generic.List[object] }
                $d.Tables.Add($table)
                $section = 'chars'
            }
            continue
        }
        $f = $line.Split(' ')
        switch ($section) {
            'modifiers' { if ($f[0] -eq 'mod') { $d.Mods[[int]$f[1]] = [int]$f[3] } }
            'scancodes' { $d.Vk[[Convert]::ToInt32($f[0], 16)] = [Convert]::ToInt32($f[1], 16) -band 0xFF }
            'chars' {
                $table.Rows.Add(@{ Vk = [Convert]::ToInt32($f[0], 16); Attr = [Convert]::ToInt32($f[1], 16)
                        Wch = @($f[2..($f.Count - 1)] | ForEach-Object { [Convert]::ToInt32($_, 16) }) })
            }
            'deadkeys' { $d.Dead['{0}:{1}' -f $f[0], $f[1]] = [Convert]::ToInt32($f[3], 16) }
        }
    }
    $d
}

function Get-TableOutput($d, [int]$Scancode, [int]$Vk, [int]$Bits, [bool]$Caps) {
    # Mirrors win32k's character lookup for one key press, including its
    # fallback that turns Ctrl+letter (without Alt) into a control character
    # when the layout defines nothing for it.
    if ($Vk) { $vk = $Vk }
    elseif ($d.Vk.ContainsKey($Scancode)) { $vk = $d.Vk[$Scancode] }
    else { return '' }
    # win32k ignores Alt when it is the only modifier besides Shift.
    if (($Bits -band ($CTRL + $ALT)) -eq $ALT) { $Bits = $Bits -bxor $ALT }
    $char = Get-TableCharacter $d $vk $Bits $Caps
    if ($null -ne $char -and $char.Length -eq 0 -and ($Bits -band ($CTRL + $ALT)) -eq $CTRL -and $vk -ge 0x41 -and $vk -le 0x5A) {
        return [string][char]($vk - 0x40)
    }
    $char
}

function Get-TableCharacter($d, [int]$vk, [int]$Bits, [bool]$Caps) {
    foreach ($t in $d.Tables) {
        for ($i = 0; $i -lt $t.Rows.Count; $i++) {
            $row = $t.Rows[$i]
            if ($row.Vk -ne $vk) { continue }
            if (($row.Attr -band 2) -and $Caps) { $row = $t.Rows[$i + 1] }                     # SGCAPS
            elseif (($row.Attr -band 1) -and $Caps -and (($Bits -band (-bnot $SHIFT)) -eq 0)) { $Bits = $Bits -bxor $SHIFT }  # CAPLOK
            elseif (($row.Attr -band 4) -and $Caps -and (($Bits -band ($CTRL + $ALT)) -eq ($CTRL + $ALT))) { $Bits = $Bits -bxor $SHIFT }  # CAPLOKALTGR
            if (-not $d.Mods.ContainsKey($Bits)) { return '' }
            $col = $d.Mods[$Bits]
            if ($col -ge $t.N) { return '' }
            $w = $row.Wch[$col]
            if ($w -eq 0xF000) { return '' }                       # WCH_NONE
            if ($w -eq 0xF001) { return $null }                    # WCH_DEAD
            if ($w -eq 0xF002) { throw 'Ligatures are not expected in this layout.' }
            return [string][char]$w
        }
    }
    ''
}

# ------------------------------------------------------------- installed mode
function Initialize-Native {
    if ('KbdTest.Native' -as [type]) { return }
    Add-Type -Namespace KbdTest -Name Native -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr LoadKeyboardLayout(string klid, uint flags);
[DllImport("user32.dll")] public static extern int GetKeyboardLayoutList(int n, IntPtr[] list);
[DllImport("user32.dll")] public static extern bool UnloadKeyboardLayout(IntPtr hkl);
[DllImport("user32.dll")] public static extern uint MapVirtualKeyEx(uint code, uint mapType, IntPtr hkl);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int ToUnicodeEx(uint vk, uint sc, byte[] state, [Out, MarshalAs(UnmanagedType.LPArray)] char[] buf, int cch, uint flags, IntPtr hkl);
'@
}

function Get-WindowsOutput([IntPtr]$Hkl, [int]$Scancode, [int]$Vk, [int]$Bits, [bool]$Caps) {
    if ($Vk) { $vk = $Vk } else { $vk = [KbdTest.Native]::MapVirtualKeyEx($Scancode, 1, $Hkl) }  # MAPVK_VSC_TO_VK
    if ($vk -eq 0) { return '' }
    $state = New-Object byte[] 256
    if ($Bits -band $SHIFT) { $state[0x10] = 0x80; $state[0xA0] = 0x80 }
    if ($Bits -band $CTRL) { $state[0x11] = 0x80; $state[0xA2] = 0x80 }
    if ($Bits -band $ALT) { $state[0x12] = 0x80; $state[0xA5] = 0x80 }
    if ($Caps) { $state[0x14] = 0x01 }
    # A char[] rather than a StringBuilder: results such as Ctrl+Shift+2 are NUL.
    $buf = New-Object char[] 16
    # Flag 4: do not change the keyboard state (no dead-key side effects).
    $n = [KbdTest.Native]::ToUnicodeEx($vk, $Scancode, $state, $buf, $buf.Length, 4, $Hkl)
    if ($n -lt 0) { return $null }
    if ($n -eq 0) { return '' }
    New-Object string($buf, 0, $n)
}

# ----------------------------------------------------------------------- main
$specData = Get-Content -Raw -Encoding UTF8 $Spec | ConvertFrom-Json
$hkl = [IntPtr]::Zero
$unload = $false
if ($Mode -eq 'Tables') {
    $dumpData = Read-Dump $Dump
} else {
    Initialize-Native
    $klid = $null
    foreach ($key in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts') {
        if ("$($key.GetValue('Layout File'))" -ieq $LayoutFile) { $klid = $key.PSChildName }
    }
    if (-not $klid) { throw "$LayoutFile is not installed." }
    $before = New-Object IntPtr[] 64
    $count = [KbdTest.Native]::GetKeyboardLayoutList(64, $before)
    $hkl = [KbdTest.Native]::LoadKeyboardLayout($klid, 0x80)        # KLF_NOTELLSHELL
    if ($hkl -eq [IntPtr]::Zero) { throw "LoadKeyboardLayout($klid) failed." }
    $unload = -not (@($before[0..([Math]::Max(0, $count - 1))]) -contains $hkl)
    Write-Host "Testing installed layout $klid (HKL 0x$($hkl.ToString('x')))"
}

$failures = 0
$checks = 0
try {
    foreach ($k in $specData.keys) {
        foreach ($state in $States.Keys) {
            if ($k.PSObject.Properties.Name -contains $state) {
                $expected = ConvertFrom-CodePoints $k.$state
            } elseif ($state -like '*trl') {
                # Ctrl states the spec does not list must type nothing, except
                # that Windows itself turns Ctrl+letter into a control character.
                $expected = ''
                if ($k.key -cmatch '^[A-Z]$') { $expected = [string][char]([int][char]$k.key - 0x40) }
            } elseif ($state -eq 'alt') {
                $expected = ConvertFrom-CodePoints $k.base
            } elseif ($state -eq 'shiftAlt') {
                $expected = ConvertFrom-CodePoints $k.shift
            } else {
                throw "Spec entry '$($k.key)' has no '$state' value."
            }
            $s = $States[$state]
            $sc = [Convert]::ToInt32($k.scancode, 16)
            # Numpad keys are tested by VK: their scancodes map to navigation VKs.
            $vk = 0
            if ($k.PSObject.Properties.Name -contains 'vk') { $vk = [Convert]::ToInt32($k.vk, 16) }
            if ($Mode -eq 'Tables') { $actual = Get-TableOutput $dumpData $sc $vk $s.Bits $s.Caps }
            else { $actual = Get-WindowsOutput $hkl $sc $vk $s.Bits $s.Caps }
            $checks++
            # Ordinal comparison: -ne ignores case and treats U+20BD or U+0000 as
            # equal to ''. $null (a dead key) is checked separately because
            # PowerShell passes $null to .NET string parameters as ''.
            $same = ($null -eq $actual) -eq ($null -eq $expected)
            if ($same -and $null -ne $actual) { $same = [string]::Equals($actual, $expected, [StringComparison]::Ordinal) }
            if (-not $same) {
                $failures++
                Write-Host ('FAIL  {0,-6} sc {1} {2,-15} expected {3}, got {4}' -f $k.key, $k.scancode, $state, (Format-CodePoints $expected), (Format-CodePoints $actual)) -ForegroundColor Red
            }
        }
    }
} finally {
    if ($unload) { [void][KbdTest.Native]::UnloadKeyboardLayout($hkl) }
}

if ($failures) { throw "$failures of $checks checks failed ($Mode)." }
Write-Host "PASS: $checks key/modifier checks match macOS ($Mode)." -ForegroundColor Green
