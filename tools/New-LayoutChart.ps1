#Requires -Version 5.1
<#
.SYNOPSIS
    Draws the layout as an SVG keyboard chart (docs\layout.svg) from the .klc.

.DESCRIPTION
    Each key shows: Shift (top left), base (bottom left), Shift+AltGr (top
    right, accent colour) and AltGr (bottom right, accent colour). Letters show
    only their capital, as on a keycap. The ISO key next to Left Shift is drawn
    dashed because ANSI keyboards do not have it.
#>
[CmdletBinding()]
param(
    [string]$Layout,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'KbdLayout.psm1') -Force

# Defaults are set here because $PSScriptRoot is empty in parameter defaults
# when Windows PowerShell runs a script with -File.
if (-not $Layout) { $Layout = Join-Path $PSScriptRoot '..\layout\kbdrumph.klc' }
if (-not $OutFile) { $OutFile = Join-Path $PSScriptRoot '..\docs\layout.svg' }
$OutFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)

$klc = Read-KlcLayout -Path $Layout
$states = @($klc.ShiftStates)
$byScancode = @{}
foreach ($k in $klc.Keys) { $byScancode[$k.Scancode] = $k }

# Rows of [scancode or label, width in key units].
$rows = @(
    @(@(0x29, 1), @(0x02, 1), @(0x03, 1), @(0x04, 1), @(0x05, 1), @(0x06, 1), @(0x07, 1), @(0x08, 1), @(0x09, 1), @(0x0a, 1), @(0x0b, 1), @(0x0c, 1), @(0x0d, 1), @('Backspace', 2)),
    @(@('Tab', 1.5), @(0x10, 1), @(0x11, 1), @(0x12, 1), @(0x13, 1), @(0x14, 1), @(0x15, 1), @(0x16, 1), @(0x17, 1), @(0x18, 1), @(0x19, 1), @(0x1a, 1), @(0x1b, 1), @(0x2b, 1.5)),
    @(@('Caps Lock', 1.75), @(0x1e, 1), @(0x1f, 1), @(0x20, 1), @(0x21, 1), @(0x22, 1), @(0x23, 1), @(0x24, 1), @(0x25, 1), @(0x26, 1), @(0x27, 1), @(0x28, 1), @('Enter', 2.25)),
    @(@('Shift', 1.25), @(0x56, 1), @(0x2c, 1), @(0x2d, 1), @(0x2e, 1), @(0x2f, 1), @(0x30, 1), @(0x31, 1), @(0x32, 1), @(0x33, 1), @(0x34, 1), @(0x35, 1), @('Shift', 2.75)),
    @(@('Ctrl', 1.25), @('Win', 1.25), @('Alt', 1.25), @(0x39, 6.25), @('AltGr', 1.25), @('Win', 1.25), @('Menu', 1.25), @('Ctrl', 1.25))
)

$u = 56; $gap = 4; $pad = 16
$width = [int](15 * $u + 2 * $pad)
$height = [int](5 * $u + 2 * $pad + 34)

function Get-Text([object]$v) {
    if ($null -eq $v -or $v.Kind -ne 'Char') { return '' }
    $c = $v.Code
    if ($c -lt 0x20) { return '' }
    if ($c -eq 0x20) { return '' }
    if ($c -eq 0xA0) { return 'nbsp' }
    $s = [string][char]$c
    [Security.SecurityElement]::Escape($s)
}

function Get-Column([object]$Key, [int]$State) {
    $i = $states.IndexOf($State)
    if ($i -lt 0) { return $null }
    $Key.Values[$i]
}

$sb = New-Object System.Text.StringBuilder
function Add-Line([string]$s) { [void]$sb.Append($s).Append("`n") }
Add-Line "<svg xmlns=`"http://www.w3.org/2000/svg`" viewBox=`"0 0 $width $height`" width=`"$width`" height=`"$height`" role=`"img`" aria-label=`"$([Security.SecurityElement]::Escape($klc.Description)) keyboard layout`">"
Add-Line '<style>'
Add-Line '  svg { --bg: #ffffff; --key: #f3f4f6; --edge: #c9ccd1; --ink: #1f2328; --dim: #6e7781; --accent: #b4235a; }'
Add-Line '  @media (prefers-color-scheme: dark) { svg { --bg: #0d1117; --key: #1c2128; --edge: #3d444d; --ink: #e6edf3; --dim: #8b949e; --accent: #f778ba; } }'
Add-Line '  .bg { fill: var(--bg); } .key { fill: var(--key); stroke: var(--edge); stroke-width: 1; } .iso { stroke-dasharray: 4 3; }'
Add-Line '  text { font-family: "Segoe UI", system-ui, -apple-system, sans-serif; fill: var(--ink); }'
Add-Line '  .big { font-size: 20px; } .mid { font-size: 15px; } .alt { font-size: 13px; fill: var(--accent); } .lbl { font-size: 11px; fill: var(--dim); }'
Add-Line '</style>'
Add-Line "<rect class=`"bg`" x=`"0`" y=`"0`" width=`"$width`" height=`"$height`" rx=`"10`"/>"

$y = $pad
foreach ($row in $rows) {
    $x = $pad
    foreach ($cell in $row) {
        $w = $cell[1] * $u - $gap
        $h = $u - $gap
        $id = $cell[0]
        $cls = 'key'
        if ($id -is [int] -and $id -eq 0x56) { $cls = 'key iso' }
        Add-Line ('<rect class="{0}" x="{1}" y="{2}" width="{3}" height="{4}" rx="6"/>' -f $cls, $x, $y, $w, $h)
        if ($id -is [string]) {
            Add-Line ('<text class="lbl" x="{0}" y="{1}">{2}</text>' -f ($x + 7), ($y + $h - 9), [Security.SecurityElement]::Escape($id))
        } elseif ($byScancode.ContainsKey($id)) {
            $k = $byScancode[$id]
            $base = Get-Text (Get-Column $k 0)
            $shift = Get-Text (Get-Column $k 1)
            $alt = Get-Text (Get-Column $k 6)
            $shiftAlt = Get-Text (Get-Column $k 7)
            $isLetter = $base -and $shift -and ($base -cne $shift) -and ($base.ToUpperInvariant() -ceq $shift)
            if ($isLetter) {
                Add-Line ('<text class="big" x="{0}" y="{1}">{2}</text>' -f ($x + 8), ($y + 30), $shift)
            } else {
                if ($shift -and $shift -cne $base) { Add-Line ('<text class="mid" x="{0}" y="{1}">{2}</text>' -f ($x + 8), ($y + 20), $shift) }
                if ($base) { Add-Line ('<text class="mid" x="{0}" y="{1}">{2}</text>' -f ($x + 8), ($y + $h - 10), $base) }
            }
            if ($shiftAlt -and $shiftAlt -cne $alt) { Add-Line ('<text class="alt" x="{0}" y="{1}" text-anchor="end">{2}</text>' -f ($x + $w - 7), ($y + 19), $shiftAlt) }
            if ($alt) { Add-Line ('<text class="alt" x="{0}" y="{1}" text-anchor="end">{2}</text>' -f ($x + $w - 7), ($y + $h - 10), $alt) }
            if ($id -eq 0x39) { Add-Line ('<text class="lbl" x="{0}" y="{1}">Space</text>' -f ($x + 8), ($y + $h - 9)) }
            if ($id -eq 0x56) { Add-Line ('<text class="lbl" x="{0}" y="{1}" text-anchor="end">ISO</text>' -f ($x + $w - 6), ($y + 14)) }
        }
        $x += $cell[1] * $u
    }
    $y += $u
}
$legendY = $y + 18
Add-Line ('<text class="lbl" x="{0}" y="{1}">Left: Shift / base.  <tspan class="alt">Right, coloured: Shift+AltGr / AltGr (Mac Option).</tspan>  Dashed key: ISO keyboards only.  Caps Lock = Shift Lock, as on the Mac.</text>' -f $pad, $legendY)
Add-Line '</svg>'

$null = New-Item -ItemType Directory -Force -Path (Split-Path $OutFile)
[IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Wrote $OutFile"
