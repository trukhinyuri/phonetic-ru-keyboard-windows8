#Requires -Version 5.1
<#
.SYNOPSIS
    Locates the MSVC toolset and runs its tools for a given target architecture.
#>

Set-StrictMode -Version Latest

# Build targets: MSVC target architecture, linker machine and extra defines.
$script:Targets = @{
    # ARM64X, like Windows' own ARM64 layouts: one DLL that both native ARM64
    # and emulated x64 processes can load (LoadKeyboardLayout loads the DLL in
    # the calling process; a pure ARM64 DLL fails there with error 193).
    arm64 = @{ VcTarget = 'arm64'; Machine = 'ARM64X'; Defines = @(); Hybrid = $true }
    amd64 = @{ VcTarget = 'amd64'; Machine = 'X64'; Defines = @(); Hybrid = $false }
    x86   = @{ VcTarget = 'x86'; Machine = 'X86'; Defines = @(); Hybrid = $false }
    # 32-bit DLL whose tables use 64-bit pointers, for SysWOW64 (same defines as MSKLC's -o).
    wow64 = @{ VcTarget = 'x86'; Machine = 'X86'; Defines = @('/DBUILD_WOW6432', '/D_WOW6432_'); Hybrid = $false }
}
$script:EnvCache = @{}
$script:VcVarsAll = $null

function Get-HostArch {
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    switch ($arch) {
        'Arm64' { 'arm64' }
        'X64' { 'amd64' }
        'X86' { 'x86' }
        default { throw "Unsupported host architecture: $arch" }
    }
}

function Get-BuildTarget([string]$Name) {
    if (-not $script:Targets.ContainsKey($Name)) { throw "Unknown target '$Name'." }
    $script:Targets[$Name]
}

function Find-VcVarsAll {
    if ($script:VcVarsAll) { return $script:VcVarsAll }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { throw 'vswhere.exe not found. Install Visual Studio 2022+ or its Build Tools with the MSVC x64/x86 and ARM64 build tools.' }
    $path = & $vswhere -latest -products * -prerelease -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $path) { throw 'No Visual Studio installation with the MSVC C++ build tools was found.' }
    $vcvars = Join-Path $path 'VC\Auxiliary\Build\vcvarsall.bat'
    if (-not (Test-Path $vcvars)) { throw "vcvarsall.bat not found under $path" }
    $script:VcVarsAll = $vcvars
    $vcvars
}

function Get-VcEnvironment {
    # Returns the environment that vcvarsall.bat sets up for building $Target on this host.
    param([Parameter(Mandatory)][string]$Target)
    $hostArch = Get-HostArch
    $vcTarget = (Get-BuildTarget $Target).VcTarget
    if ($hostArch -eq $vcTarget) { $arg = $hostArch } else { $arg = "${hostArch}_$vcTarget" }
    if ($script:EnvCache.ContainsKey($arg)) { return $script:EnvCache[$arg] }
    $vcvars = Find-VcVarsAll
    $out = & cmd.exe /d /s /c "`"$vcvars`" $arg >nul 2>&1 && set"
    if ($LASTEXITCODE -ne 0) { throw "vcvarsall.bat $arg failed. Is the matching MSVC build tools component installed?" }
    $envTable = @{}
    foreach ($line in $out) {
        $i = $line.IndexOf('=')
        if ($i -gt 0) { $envTable[$line.Substring(0, $i).ToUpperInvariant()] = $line.Substring($i + 1) }
    }
    $script:EnvCache[$arg] = $envTable
    $envTable
}

function Invoke-VcTool {
    # Runs cl.exe / link.exe / rc.exe with the toolset environment for $Target.
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $envTable = Get-VcEnvironment $Target
    $names = 'PATH', 'INCLUDE', 'LIB', 'LIBPATH'
    $saved = @{}
    foreach ($k in $names) { $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process') }
    try {
        foreach ($k in $names) { if ($envTable.ContainsKey($k)) { [Environment]::SetEnvironmentVariable($k, $envTable[$k], 'Process') } }
        $output = & $Tool @Arguments 2>&1
        $code = $LASTEXITCODE
        foreach ($line in $output) { Write-Verbose "$line" }
        if ($code -ne 0) {
            foreach ($line in $output) { Write-Host "$line" }
            throw "$Tool failed with exit code $code"
        }
    }
    finally {
        foreach ($k in $names) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
    }
}

Export-ModuleMember -Function Get-HostArch, Get-BuildTarget, Find-VcVarsAll, Get-VcEnvironment, Invoke-VcTool
