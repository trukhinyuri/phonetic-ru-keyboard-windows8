#Requires -Version 5.1
<#
.SYNOPSIS
    Verifies that every built layout DLL contains exactly the same tables.

.DESCRIPTION
    Builds tools\kbddump for each target architecture, loads each built layout
    DLL with it and compares the dumps. On ARM64 hosts all four targets can be
    checked (x64 and x86 run under emulation); on x64 hosts the ARM64 DLL is
    skipped because it cannot be loaded there.

    With -KbdUtool pointing at MSKLC 1.4's kbdutool.exe, the same .klc is also
    compiled by MSKLC itself (amd64 and wow64) and those DLLs must dump to the
    same text, which proves the generator is equivalent to MSKLC.

    The dumps are written to out\test\<target>\tables.txt; the first one is
    also copied to out\test\tables.txt for Test-Layout.ps1.
#>
[CmdletBinding()]
param(
    [string]$Layout,
    [string]$OutDir,
    [ValidateSet('arm64', 'amd64', 'x86', 'wow64')]
    [string[]]$Target = @('arm64', 'amd64', 'x86', 'wow64'),
    [string]$KbdUtool
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
Import-Module (Join-Path $root 'tools\Msvc.psm1') -Force
Import-Module (Join-Path $root 'tools\KbdLayout.psm1') -Force

# Defaults are set here because $PSScriptRoot is empty in parameter defaults
# under "powershell -File"; paths are made absolute because .NET file APIs and
# Push-Location below would otherwise resolve them differently.
if (-not $Layout) { $Layout = Join-Path $root 'layout\kbdrumph.klc' }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$Layout = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Layout)
$OutDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)
if ($KbdUtool) { $KbdUtool = (Resolve-Path -LiteralPath $KbdUtool).ProviderPath }

$klc = Read-KlcLayout -Path $Layout
$name = $klc.Name.ToLowerInvariant()
$hostArch = Get-HostArch
$runnable = @{ arm64 = @('arm64', 'amd64', 'x86', 'wow64'); amd64 = @('amd64', 'x86', 'wow64'); x86 = @('x86') }[$hostArch]
$testDir = Join-Path $OutDir 'test'
$source = Join-Path $root 'tools\kbddump\kbddump.c'

function Build-KbdDump([string]$t) {
    $dir = Join-Path $testDir $t
    $null = New-Item -ItemType Directory -Force -Path $dir
    $exe = Join-Path $dir 'kbddump.exe'
    $def = Get-BuildTarget $t
    Invoke-VcTool -Target $t -Tool 'cl.exe' -Arguments (@('/nologo', '/W4', '/WX', '/O1', '/MT', '/utf-8', '/DUNICODE', '/D_UNICODE') +
        $def.Defines + @("/Fo$dir\", "/Fe$exe", $source))
    $exe
}

function Get-Dump([string]$exe, [string]$dll) {
    $text = & $exe $dll
    if ($LASTEXITCODE -ne 0) { throw "kbddump failed for $dll" }
    ($text -join "`n") + "`n"
}

function Get-TablesOnly([string]$dump) {
    # MSKLC writes its own version and string resources, so only the tables
    # are compared with its build.
    $i = $dump.IndexOf("[resources]`n")
    if ($i -lt 0) { return $dump }
    $dump.Substring(0, $i)
}

$dumps = [ordered]@{}
$dumpers = @{}
foreach ($t in $Target) {
    if ($runnable -notcontains $t) { Write-Warning "[$t] skipped: a $hostArch host cannot load $t DLLs"; continue }
    $dll = Join-Path $OutDir "bin\$t\$name.dll"
    if (-not (Test-Path $dll)) { throw "Missing $dll - run build.ps1 first." }
    $dumpers[$t] = Build-KbdDump $t
    $dumps[$t] = Get-Dump $dumpers[$t] $dll
    [IO.File]::WriteAllText((Join-Path $testDir "$t\tables.txt"), $dumps[$t])
    Write-Host "[$t] dumped $(($dumps[$t] -split "`n").Count) lines"
}
if ($dumps.Count -eq 0) { throw 'Nothing could be checked on this host.' }

# The ARM64 DLL is ARM64X: an emulated x64 process must be able to load it
# too and see the same tables (its ARM64EC half).
if ($dumpers.ContainsKey('arm64') -and $dumpers.ContainsKey('amd64')) {
    $dumps['arm64 (x64 view)'] = Get-Dump $dumpers['amd64'] (Join-Path $OutDir "bin\arm64\$name.dll")
    Write-Host "[arm64] loaded by the x64 dumper (ARM64X)"
}

$failed = $false
$first = @($dumps.Keys)[0]
[IO.File]::WriteAllText((Join-Path $testDir 'tables.txt'), $dumps[$first])
foreach ($t in $dumps.Keys) {
    if ($dumps[$t] -cne $dumps[$first]) {
        $failed = $true
        Write-Host "FAIL: $t tables differ from $first" -ForegroundColor Red
        Compare-Object ($dumps[$first] -split "`n") ($dumps[$t] -split "`n") | Select-Object -First 20 | Format-Table -AutoSize | Out-String | Write-Host
    } else {
        Write-Host "PASS: $t tables identical to $first" -ForegroundColor Green
    }
}

# The registry's "Layout Display Name" points at string 1000, and the version
# resource must identify a keyboard driver DLL (VFT_DLL / VFT2_DRV_KEYBOARD).
$description = $klc.Description
if ($klc.Descriptions.Contains('0409')) { $description = $klc.Descriptions['0409'] }
$expectedName = 'string 1000 lang 0409 "' + $description + '"'
$resourceLines = @($dumps[$first] -split "`n")
foreach ($expectedLine in @($expectedName, 'version type 2 subtype 2 os 00040004')) {
    if ($resourceLines -ccontains $expectedLine) { Write-Host "PASS: resources contain $expectedLine" -ForegroundColor Green }
    else { $failed = $true; Write-Host "FAIL: resources lack $expectedLine" -ForegroundColor Red }
}

if ($KbdUtool) {
    # MSKLC writes its output next to the .klc, so work on a copy.
    $msklcDir = Join-Path $testDir 'msklc'
    if (Test-Path $msklcDir) { Remove-Item -Recurse -Force $msklcDir }
    foreach ($pair in @(@('amd64', '-m'), @('wow64', '-o'), @('x86', '-x'))) {
        $t = $pair[0]
        if (-not $dumpers.ContainsKey($t)) { continue }
        $dir = Join-Path $msklcDir $t
        $null = New-Item -ItemType Directory -Force -Path $dir
        Copy-Item $Layout (Join-Path $dir 'layout.klc')
        Push-Location $dir
        try { $log = & $KbdUtool -n -u $pair[1] 'layout.klc' 2>&1 } finally { Pop-Location }
        $dll = Get-ChildItem -Path $dir -Filter '*.dll' -Recurse | Select-Object -First 1
        if (-not $dll) { $log | Write-Host; throw "kbdutool did not produce a $t DLL" }
        $ref = Get-Dump $dumpers[$t] $dll.FullName
        [IO.File]::WriteAllText((Join-Path $dir 'tables.txt'), $ref)
        $ours = Get-TablesOnly $dumps[$t]
        $ref = Get-TablesOnly $ref
        if ($ref -cne $ours) {
            $failed = $true
            Write-Host "FAIL: $t tables differ from the MSKLC build" -ForegroundColor Red
            Compare-Object ($ref -split "`n") ($ours -split "`n") | Select-Object -First 40 | Format-Table -AutoSize | Out-String | Write-Host
        } else {
            Write-Host "PASS: $t tables identical to the MSKLC (kbdutool) build" -ForegroundColor Green
        }
    }
}

if ($failed) { throw 'Table comparison failed.' }
