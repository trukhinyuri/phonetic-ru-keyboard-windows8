#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the "Russian - QWERTY (Mac)" keyboard layout on Windows 10/11
    (ARM64, x64 or x86) and adds it to your input methods.

.DESCRIPTION
    Machine part (needs administrator rights, requested through UAC):
      * copies the native DLL to System32 and, on 64-bit Windows, the WOW64
        DLL to SysWOW64, exactly where Windows keeps its own layouts;
      * registers the layout under
        HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layouts\<KLID>
        reusing the KLID of a previous installation, or picking the first free
        A0xx0419 identifier and a unique "Layout Id" the way MSKLC does.
    User part (runs as you, not as the elevated administrator):
      * adds the layout to your input methods under Russian, adding the
        Russian language if needed; your other languages and keyboards are
        not touched.

    Re-running the script upgrades an existing installation in place.

.PARAMETER MachineOnly
    Only perform the machine-wide part (used internally for the elevated step).

.PARAMETER UserOnly
    Only add the already-installed layout to the current user's input methods.

.PARAMETER LogFile
    Where the elevated step writes its messages (used internally).

.EXAMPLE
    .\Install.ps1
#>
[CmdletBinding()]
param(
    [switch]$MachineOnly,
    [switch]$UserOnly,
    [string]$LogFile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$LayoutFile = 'kbdrumph.dll'
$LayoutText = 'Russian - QWERTY (Mac)'
$LangId = 0x0419
$KeyboardLayouts = 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts'
# Layout DLLs installed by the 1.x releases of this project.
$LegacyFiles = @('rtrukhin.dll', 'rtruk16.dll', 'ruphon.dll')
$Architectures = @('arm64', 'amd64', 'x86', 'wow64')

function Write-Step([string]$Message) {
    # The elevated window closes when it is done, so its messages are also
    # written to the log that the non-elevated script shows afterwards.
    Write-Host $Message
    if ($LogFile) { [IO.File]::AppendAllText($LogFile, $Message + [Environment]::NewLine) }
}

function Test-Administrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-OsArch {
    # IsWow64Process2 reports the real machine even to emulated x86/x64
    # processes on ARM64, where GetNativeSystemInfo reports x64.
    if (-not ('KbdInstall.Machine' -as [type])) {
        Add-Type -Namespace KbdInstall -Name Machine -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess(); [DllImport("kernel32.dll", SetLastError = true)] public static extern bool IsWow64Process2(IntPtr process, out ushort processMachine, out ushort nativeMachine);'
    }
    [uint16]$processMachine = 0
    [uint16]$nativeMachine = 0
    try { $ok = [KbdInstall.Machine]::IsWow64Process2([KbdInstall.Machine]::GetCurrentProcess(), [ref]$processMachine, [ref]$nativeMachine) }
    catch [System.EntryPointNotFoundException] { $ok = $false }   # Windows 10 before 1709
    if (-not $ok) {
        if ([Environment]::Is64BitOperatingSystem) { $nativeMachine = 0x8664 } else { $nativeMachine = 0x014C }
    }
    switch ([int]$nativeMachine) {
        0xAA64 { 'arm64' }
        0x8664 { 'amd64' }
        0x014C { 'x86' }
        default { throw ('Unsupported Windows architecture (machine 0x{0:X4}).' -f [int]$nativeMachine) }
    }
}

function Get-NativeSystemDirectory {
    # A 32-bit PowerShell on 64-bit Windows sees SysWOW64 as System32;
    # Sysnative is the alias for the real System32 in that case.
    if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
        return Join-Path $env:windir 'Sysnative'
    }
    Join-Path $env:windir 'System32'
}

function Get-InstalledKlid {
    # RegistryKey.GetValue returns $null for missing values (many system
    # layouts have no "Layout Id"), which Get-ItemProperty does not allow
    # under strict mode.
    foreach ($key in Get-ChildItem $KeyboardLayouts) {
        $file = $key.GetValue('Layout File')
        if ($file -and $file -ieq $LayoutFile) { return $key.PSChildName }
    }
    $null
}

function Install-LayoutFile([string]$Source, [string]$Directory) {
    if (-not (Test-Path -LiteralPath $Source)) { throw "Missing $Source - is the package complete?" }
    $target = Join-Path $Directory $LayoutFile
    if (Test-Path -LiteralPath $target) {
        try { Remove-Item -LiteralPath $target -Force }
        catch {
            # The layout is loaded by the system: move the old file aside and
            # let Windows delete it on the next restart.
            $old = "$target.$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss')).old"
            Move-Item -LiteralPath $target -Destination $old -Force
            if (-not ('KbdInstall.Native' -as [type])) {
                Add-Type -Namespace KbdInstall -Name Native -MemberDefinition '[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool MoveFileEx(string existing, string replacement, int flags);'
            }
            [void][KbdInstall.Native]::MoveFileEx($old, $null, 4) # MOVEFILE_DELAY_UNTIL_REBOOT
            Write-Step "  the previous $LayoutFile was in use; restart Windows to finish replacing it"
        }
    }
    Copy-Item -LiteralPath $Source -Destination $target -Force
    Unblock-File -LiteralPath $target   # drop any "downloaded from the Internet" mark copied with the file
    Write-Step "  $target"
}

function Install-Machine {
    $arch = Get-OsArch
    Write-Step "Installing $LayoutText ($arch)"
    Install-LayoutFile (Join-Path $PSScriptRoot "$arch\$LayoutFile") (Get-NativeSystemDirectory)
    if ($arch -ne 'x86') {
        Install-LayoutFile (Join-Path $PSScriptRoot "wow64\$LayoutFile") (Join-Path $env:windir 'SysWOW64')
    }

    $layouts = @(Get-ChildItem $KeyboardLayouts)
    $klid = Get-InstalledKlid
    $layoutId = $null
    if ($klid) {
        Write-Step "  upgrading the existing registration $klid"
        $layoutId = (Get-Item (Join-Path $KeyboardLayouts $klid)).GetValue('Layout Id')
    } else {
        # First free A<nnn>0419 identifier, as MSKLC assigns them. An empty key
        # left behind by an interrupted installation counts as free.
        $taken = @{}
        foreach ($k in $layouts) {
            if ($k.ValueCount -gt 0 -or $k.SubKeyCount -gt 0) { $taken[$k.PSChildName.ToLowerInvariant()] = $true }
        }
        for ($i = 0; $i -lt 0x1000 -and -not $klid; $i++) {
            $candidate = 'a{0:x3}{1:x4}' -f $i, $LangId
            if (-not $taken.ContainsKey($candidate)) { $klid = $candidate }
        }
        if (-not $klid) { throw 'No free keyboard layout identifier is left.' }
    }
    if (-not $layoutId) {
        # "Layout Id" must be unique across all layouts that have one.
        $ids = @($layouts | ForEach-Object { $_.GetValue('Layout Id') } |
            Where-Object { $_ -match '^[0-9A-Fa-f]{1,4}$' } | ForEach-Object { [Convert]::ToInt32($_, 16) })
        $next = 1
        if ($ids.Count) { $next = [int](($ids | Measure-Object -Maximum).Maximum) + 1 }
        $layoutId = '{0:x4}' -f $next
    }
    $key = Join-Path $KeyboardLayouts $klid
    if (-not (Test-Path $key)) { $null = New-Item -Path $key }
    Set-ItemProperty -Path $key -Name 'Layout File' -Value $LayoutFile -Type String
    Set-ItemProperty -Path $key -Name 'Layout Text' -Value $LayoutText -Type String
    Set-ItemProperty -Path $key -Name 'Layout Display Name' -Value "@%SystemRoot%\system32\$LayoutFile,-1000" -Type ExpandString
    Set-ItemProperty -Path $key -Name 'Layout Id' -Value $layoutId -Type String
    Write-Step "  registered $klid (Layout Id $layoutId)"
}

function Install-User([string]$Klid) {
    # InstallLayoutOrTip (input.dll, also used by MSKLC's own installer) adds
    # exactly one input profile, adding the language if needed, and leaves the
    # rest of the user's languages alone. Set-WinUserLanguageList rewrites the
    # whole list and can drop or alter other languages, so it is not used.
    if (-not ('KbdInstall.Input' -as [type])) {
        Add-Type -Namespace KbdInstall -Name Input -MemberDefinition '[DllImport("input.dll", CharSet = CharSet.Unicode)] public static extern bool InstallLayoutOrTip(string profile, uint flags);'
    }
    $inputProfile = '{0:x4}:{1}' -f $LangId, $Klid.ToLowerInvariant()
    if (-not [KbdInstall.Input]::InstallLayoutOrTip($inputProfile, 0)) { throw "InstallLayoutOrTip('$inputProfile') failed." }
    Write-Host "Added $LayoutText ($inputProfile) to the input methods of $env:USERNAME."
}

function Show-LegacyLayout {
    foreach ($key in Get-ChildItem $KeyboardLayouts) {
        $file = "$($key.GetValue('Layout File'))".ToLowerInvariant()
        if ($LegacyFiles -contains $file) {
            Write-Warning ("An older version of this layout is still installed: '{0}' ({1}, {2}). See 'Upgrading from 1.x' in README.md to remove it." -f $key.GetValue('Layout Text'), $key.PSChildName, $file)
        }
    }
}

function Invoke-ElevatedStep {
    # Runs this script with -MachineOnly through UAC. It runs from a copy of
    # the package in the local temp folder, because the elevated session may
    # not see network or SUBST drives, and it always uses the console host.
    $stage = Join-Path ([IO.Path]::GetTempPath()) ('kbdrumph-setup-' + [Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $stage
    try {
        Copy-Item -LiteralPath $PSCommandPath -Destination $stage
        foreach ($a in $Architectures) {
            $dir = Join-Path $PSScriptRoot $a
            if (Test-Path -LiteralPath $dir) { Copy-Item -LiteralPath $dir -Destination $stage -Recurse }
        }
        $script = Join-Path $stage (Split-Path -Leaf $PSCommandPath)
        $log = Join-Path $stage 'machine.log'
        $exe = 'powershell.exe'
        if ($PSVersionTable.PSEdition -eq 'Core') { $exe = 'pwsh.exe' }
        $proc = Start-Process -FilePath (Join-Path $PSHOME $exe) -Verb RunAs -Wait -PassThru -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"", '-MachineOnly', '-LogFile', "`"$log`"")
        if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log | ForEach-Object { Write-Host $_ } }
        if ($proc.ExitCode -ne 0) { throw "The elevated installation step failed (exit code $($proc.ExitCode))." }
    } finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($MachineOnly) {
    try {
        if (-not (Test-Administrator)) { throw 'Administrator rights are required.' }
        Install-Machine
    } catch {
        Write-Step ($_ | Out-String)
        throw
    }
    return
}

if ($UserOnly) {
    $klid = Get-InstalledKlid
    if (-not $klid) { throw 'The layout is not installed yet; run Install.ps1 without -UserOnly.' }
    Install-User $klid
    return
}

# Elevate only the machine-wide step, then configure the current user here, so
# that the layout is added to *your* profile even when the administrator
# account is a different one.
if (Test-Administrator) { Install-Machine } else { Invoke-ElevatedStep }
$klid = Get-InstalledKlid
if (-not $klid) { throw 'The elevated installation step did not register the layout.' }
Install-User $klid
Show-LegacyLayout
Write-Host 'Done. Switch layouts with Win+Space. If an application does not offer the layout yet, sign out and back in.'
