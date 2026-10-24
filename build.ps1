#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the keyboard layout DLLs for every Windows architecture.

.DESCRIPTION
    1. Parses layout\kbdrumph.klc, the MSKLC source of truth.
    2. Generates C / RC / DEF sources with tools\KbdLayout.psm1.
    3. Compiles them with the MSVC toolset found through vswhere for:
         arm64  ARM64 Windows (System32); an ARM64X image like Windows' own
                layouts, loadable by native ARM64 and emulated x64 processes
         amd64  x64 Windows (System32)
         x86    32-bit Windows (System32)
         wow64  32-bit DLL with 64-bit table pointers (SysWOW64 on x64 and ARM64)
    4. With -Package, stages out\package and zips it with the installer.

    Requirements: Visual Studio 2022 or newer (Build Tools are enough) with the
    "MSVC x64/x86 build tools" and "MSVC ARM64 build tools" components and a
    Windows SDK. Builds work on both x64 and ARM64 hosts.

.EXAMPLE
    .\build.ps1
.EXAMPLE
    .\build.ps1 -Package -BuildNumber 42
#>
[CmdletBinding()]
param(
    [ValidateSet('arm64', 'amd64', 'x86', 'wow64')]
    [string[]]$Target = @('arm64', 'amd64', 'x86', 'wow64'),
    [string]$Layout,
    [string]$OutDir,
    [int]$BuildNumber = 0,
    [switch]$Package,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'tools\KbdLayout.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'tools\Msvc.psm1') -Force

# Defaults are set here because $PSScriptRoot is empty in parameter defaults
# when Windows PowerShell runs a script with -File; paths are made absolute
# because .NET file APIs resolve relative paths against the process directory.
if (-not $Layout) { $Layout = Join-Path $PSScriptRoot 'layout\kbdrumph.klc' }
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'out' }
$Layout = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Layout)
$OutDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)

if ($Clean -and (Test-Path -LiteralPath $OutDir)) {
    # Delete only what the build and the tests create, never a whole folder
    # that a mistyped -OutDir points at.
    foreach ($sub in 'obj', 'bin', 'package', 'test') {
        $d = Join-Path $OutDir $sub
        if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force }
    }
    Get-ChildItem -LiteralPath $OutDir -File | Where-Object { $_.Name -match '^[A-Za-z0-9_]+-\d+\.\d+\.\d+\.zip(\.sha256)?$' } | Remove-Item -Force
}
Write-Host "Host: $(Get-HostArch); toolset: $(Find-VcVarsAll)"

$klc = Read-KlcLayout -Path $Layout
$sources = Write-KbdSources -Layout $klc -OutDir (Join-Path $OutDir 'obj\src') -Build $BuildNumber -SourceName ('layout/' + (Split-Path $Layout -Leaf))
$name = $sources.Name.ToLowerInvariant()
Write-Host ('Layout: {0} "{1}", locale {2:x8}, version {3}.{4}' -f $klc.Name, $klc.Description, $klc.LocaleId, $klc.Version, $BuildNumber)

# Compile like Microsoft's own layout DLLs: optimized, no CRT, no security
# cookie or other runtime hooks, so KbdLayerDescriptor stays a plain
# "return &KbdTables" whose code win32k recognises on every architecture.
$cflags = @('/nologo', '/c', '/W4', '/WX', '/O1', '/GS-', '/Zl', '/Brepro', '/utf-8',
    '/DUNICODE', '/D_UNICODE', '/D_WIN32_WINNT=0x0A00', '/DWINVER=0x0A00')

foreach ($t in $Target) {
    $def = Get-BuildTarget $t
    $objDir = Join-Path $OutDir "obj\$t"
    $binDir = Join-Path $OutDir "bin\$t"
    $null = New-Item -ItemType Directory -Force -Path $objDir, $binDir
    $obj = Join-Path $objDir "$name.obj"
    $res = Join-Path $objDir "$name.res"
    $pdb = Join-Path $objDir "$name.pdb"
    $dll = Join-Path $binDir "$name.dll"
    $objects = @($obj)
    $hybrid = @()

    Write-Host "[$t] compile"
    Invoke-VcTool -Target $t -Tool 'cl.exe' -Arguments ($cflags + $def.Defines + @("/Fo$obj", $sources.C))
    if ($def.Hybrid) {
        # ARM64X: the same tables compiled again as ARM64EC for x64 callers.
        $ecObj = Join-Path $objDir "$name.arm64ec.obj"
        Invoke-VcTool -Target $t -Tool 'cl.exe' -Arguments ($cflags + $def.Defines + @('/arm64EC', "/Fo$ecObj", $sources.C))
        $objects += $ecObj
        # libcmt.lib only supplies the load configuration and CHPE metadata that
        # ARM64X images require; the DLL still has no imports and no entry point.
        $hybrid = @("/DEFARM64NATIVE:$($sources.Def)", 'libcmt.lib')
    }
    Invoke-VcTool -Target $t -Tool 'rc.exe' -Arguments @('/nologo', "/fo$res", $sources.Rc)

    # Link with no entry point, no default libraries and no imports, as a
    # native-subsystem DLL whose tables, string literals and export directory
    # all live in one read-only .data section - the section win32k reads.
    Write-Host "[$t] link"
    Invoke-VcTool -Target $t -Tool 'link.exe' -Arguments (@(
        '/nologo', '/DLL', '/NOENTRY', '/NODEFAULTLIB', '/INCREMENTAL:NO', '/RELEASE', '/Brepro',
        "/MACHINE:$($def.Machine)", '/SUBSYSTEM:NATIVE', '/DYNAMICBASE', '/NXCOMPAT',
        '/MERGE:.rdata=.data', '/MERGE:.edata=.data', '/MERGE:.bss=.data', '/SECTION:.data,R', '/IGNORE:4254',
        '/OPT:REF', '/OPT:ICF', '/DEBUG', "/PDB:$pdb", '/PDBALTPATH:%_PDB%',
        "/DEF:$($sources.Def)", "/OUT:$dll") + $objects + @($res) + $hybrid)
    Write-Host "[$t] -> $dll"
}

if ($Package) {
    foreach ($t in 'arm64', 'amd64', 'x86', 'wow64') {
        if ($Target -notcontains $t) { throw "-Package needs every target; $t was not built." }
    }
    $parts = @($klc.Version.Split('.')) + @('0', '0')
    $version = '{0}.{1}.{2}' -f $parts[0], $parts[1], $BuildNumber
    $pkg = Join-Path $OutDir 'package'
    if (Test-Path -LiteralPath $pkg) { Remove-Item -LiteralPath $pkg -Recurse -Force }
    $null = New-Item -ItemType Directory -Force -Path $pkg
    foreach ($t in $Target) {
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $pkg $t)
        Copy-Item (Join-Path $OutDir "bin\$t\$name.dll") (Join-Path $pkg $t)
    }
    Copy-Item (Join-Path $PSScriptRoot 'installer\*') $pkg
    Copy-Item $Layout $pkg
    Copy-Item (Join-Path $PSScriptRoot 'LICENSE'), (Join-Path $PSScriptRoot 'NOTICE') $pkg

    # Zip under a top-level folder, so "Extract here" does not scatter files,
    # with '/' separators as the ZIP format requires. (Compress-Archive in
    # Windows PowerShell 5.1 writes '\', which macOS and Linux unzip tools
    # turn into flat file names.)
    $zip = Join-Path $OutDir "$name-$version.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $rootLength = (Resolve-Path $pkg).ProviderPath.TrimEnd('\').Length + 1
        foreach ($file in Get-ChildItem -LiteralPath $pkg -Recurse -File | Sort-Object FullName) {
            $entry = "$name-$version/" + $file.FullName.Substring($rootLength).Replace('\', '/')
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $entry, [IO.Compression.CompressionLevel]::Optimal)
        }
    } finally {
        $archive.Dispose()
    }
    $hash = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText("$zip.sha256", "$hash  $(Split-Path $zip -Leaf)`n")
    Write-Host "Package: $zip"
}
