#Requires -Version 5.1
<#
.SYNOPSIS
    Regression tests for the .klc parser and source generator.

.DESCRIPTION
    Each case writes a small .klc file, runs tools\KbdLayout.psm1 on it and
    checks the generated sources (or the error). The expected results are
    what MSKLC 1.4's kbdutool produces for the same input; they were checked
    with kbdutool when the cases were written. No compiler is needed, so the
    tests also run where MSKLC cannot be installed, such as CI.
#>
[CmdletBinding()]
param([string]$WorkDir)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
Import-Module (Join-Path $root 'tools\KbdLayout.psm1') -Force
if (-not $WorkDir) { $WorkDir = Join-Path $root 'out\test\generator' }
$WorkDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkDir)
$null = New-Item -ItemType Directory -Force -Path $WorkDir

$script:failures = 0
$script:checks = 0

function New-Klc([string]$Name, [string]$ShiftStates, [string[]]$Rows, [string]$Extra = '') {
    $text = "KBD`t$Name`t`"Test $Name`"`r`n`r`nLOCALEID`t`"00000409`"`r`n`r`nSHIFTSTATE`r`n`r`n" +
        (($ShiftStates.Split(' ') | ForEach-Object { $_ }) -join "`r`n") + "`r`n`r`nLAYOUT`r`n`r`n" +
        ($Rows -join "`r`n") + "`r`n`r`n$Extra`r`nENDKBD`r`n"
    $path = Join-Path $WorkDir "$Name.klc"
    [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UnicodeEncoding($false, $true)))
    $path
}

function Get-Generated([string]$Path) {
    $layout = Read-KlcLayout -Path $Path
    $out = Join-Path $WorkDir ([IO.Path]::GetFileNameWithoutExtension($Path))
    $src = Write-KbdSources -Layout $layout -OutDir $out
    [pscustomobject]@{ Layout = $layout; C = [IO.File]::ReadAllText($src.C); Rc = [IO.File]::ReadAllText($src.Rc) }
}

function Assert([string]$Name, [bool]$Condition, [string]$Detail = '') {
    $script:checks++
    if ($Condition) { Write-Host "PASS: $Name" -ForegroundColor Green }
    else { $script:failures++; Write-Host "FAIL: $Name $Detail" -ForegroundColor Red }
}

function Assert-Throws([string]$Name, [scriptblock]$Block, [string]$Pattern) {
    try { & $Block; Assert $Name $false '(no error)' }
    catch { Assert $Name ($_.Exception.Message -match $Pattern) "(error: $($_.Exception.Message))" }
}

# 1. MSKLC saves SGCap rows with only the Caps and Shift+Caps columns. Such a
#    copy of the real layout must give exactly the same sources.
$klc = Join-Path $root 'layout\kbdrumph.klc'
$lines = [IO.File]::ReadAllText($klc) -split "`r`n"
$short = foreach ($l in $lines) {
    if ($l -match '^-1\t-1\t+0\t') {
        $cells = @(($l -replace '//.*$', '').Trim() -split '\s+')
        "-1`t-1`t`t0`t$($cells[3])`t$($cells[4])"
    } else { $l }
}
$shortPath = Join-Path $WorkDir 'msklc-saved.klc'
[IO.File]::WriteAllText($shortPath, ($short -join "`r`n"), (New-Object System.Text.UnicodeEncoding($false, $true)))
$full = Get-Generated $klc
$saved = Get-Generated $shortPath
Assert 'MSKLC-saved SGCap rows give the same tables' ($full.C -ceq $saved.C)

# 2. SHIFTSTATE 0 1 2: the default Backspace/Esc/Enter/Break rows follow the
#    layout rows in the shared 3-column table, as in kbdutool's output.
$g = Get-Generated (New-Klc 'three' '0 1 2' @("10`tQ`t1`tq`tQ`t-1", "1a`tOEM_4`t0`t005b`t007b`t001b"))
$iQ = $g.C.IndexOf("{ 'Q'"); $iBack = $g.C.IndexOf('{ VK_BACK')
Assert 'special rows follow layout rows in a 3-column table' ($iQ -ge 0 -and $iBack -gt $iQ) "(Q at $iQ, BACK at $iBack)"

# 3. Chained dead keys ("xxxx@" in a DEADKEY table) get DKF_DEAD.
$g = Get-Generated (New-Klc 'chain' '0 1 2' @("10`tQ`t0`t00b4@`t-1`t-1") "DEADKEY`t00b4`r`n`r`n0061`t00e1`r`n00b4`t02dd@`r`n`r`nDEADKEY`t02dd`r`n`r`n006f`t0151`r`n")
Assert 'chained dead key is emitted with DKF_DEAD' ($g.C.Contains('DEADTRANS(0x00b4, 0x00b4, 0x02dd, 0x0001)'))
Assert 'plain dead key entry keeps flags 0' ($g.C.Contains("DEADTRANS('a', 0x00b4, 0x00e1, 0x0000)"))
Assert-Throws 'chained dead key without a table is rejected' { Read-KlcLayout (New-Klc 'chain2' '0 1 2' @("10`tQ`t0`t00b4@`t-1`t-1") "DEADKEY`t00b4`r`n`r`n00b4`t02dd@`r`n") } 'no DEADKEY table'

# 4. Key names: escaped quotes in quoted names; unquoted names are the rest of the row.
$g = Get-Generated (New-Klc 'names' '0 1 2' @("10`tQ`t1`tq`tQ`t-1") "KEYNAME`r`n`r`n01`t`"Esc \`"x\`" y`"`r`n1c`te f`r`n")
$names = @($g.Layout.KeyNames | ForEach-Object { $_.Name })
Assert 'escaped quotes in a key name are unescaped' ($names -ccontains 'Esc "x" y') "(names: $($names -join ' / '))"
Assert 'an unquoted key name is the rest of the row' ($names -ccontains 'e f') "(names: $($names -join ' / '))"

# 5. A numpad scancode with a VK other than its NumLock VK is overridden;
#    the NumLock VK itself (DECIMAL on 53) keeps kbd.h's default.
$g = Get-Generated (New-Klc 'numpad' '0 1 2' @("53`tSEPARATOR`t0`t002c`t002c`t-1", "4a`tDECIMAL`t0`t002e`t002e`t-1"))
Assert 'numpad remap is overridden' ($g.C.Contains('#define T53 _EQ(SEPARATOR)'))
$g = Get-Generated (New-Klc 'numpad2' '0 1 2' @("53`tDECIMAL`t0`t002c`t002c`t-1"))
Assert 'numpad NumLock VK keeps the default' (-not $g.C.Contains('#define T53'))

# 6. Extended scancodes are rejected instead of being ignored.
Assert-Throws 'e0 scancodes are rejected' { Read-KlcLayout (New-Klc 'ext' '0 1 2' @("e035`tOEM_2`t0`t003a`t003a`t-1")) } 'not supported'

# 7. A language named only in LANGUAGENAMES still gets its string table.
$g = Get-Generated (New-Klc 'langs' '0 1 2' @("10`tQ`t1`tq`tQ`t-1") "DESCRIPTIONS`r`n`r`n0409`tTest`r`n`r`nLANGUAGENAMES`r`n`r`n0409`tEnglish`r`n040c`tAnglais`r`n")
Assert 'LANGUAGENAMES-only language gets a string table' ($g.Rc.Contains("STRINGTABLE LANGUAGE 0x0c, 0x01`r`nBEGIN`r`n    1100 `"Anglais`""))

# 8. Short normal rows type nothing in the missing columns.
$g = Get-Generated (New-Klc 'shortrow' '0 1 2 6' @("10`tQ`t1`tq`tQ"))
Assert 'missing trailing columns are WCH_NONE' ($g.C.Contains("{ 'Q'           , CAPLOK, 'q', 'Q', WCH_NONE, WCH_NONE }"))

if ($script:failures) { throw "$script:failures of $script:checks generator checks failed." }
Write-Host "PASS: $script:checks generator checks." -ForegroundColor Green
