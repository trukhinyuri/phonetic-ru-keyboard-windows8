#Requires -Version 5.1
<#
.SYNOPSIS
    Removes the "Russian - QWERTY (Mac)" keyboard layout.

.DESCRIPTION
    Removes the layout from the current user's input methods, under whichever
    language it was added. Then, with administrator rights requested through
    UAC, it deletes the layout's registration, its references in the
    logon-screen settings, and its DLLs. DLLs that are still in use are
    deleted at the next restart.

.PARAMETER MachineOnly
    Only perform the machine-wide part (used internally for the elevated step).

.PARAMETER UserOnly
    Only remove the layout from the current user's input methods.

.PARAMETER LogFile
    Where the elevated step writes its messages (used internally).
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
$KeyboardLayouts = 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts'

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

function Get-InstalledKlids {
    # Callers wrap the result in @(): PowerShell unrolls a single-item array
    # returned from a function, and .Count on a string fails in strict mode.
    # RegistryKey.GetValue returns $null for missing values, unlike
    # Get-ItemProperty under strict mode.
    foreach ($key in Get-ChildItem $KeyboardLayouts) {
        $file = $key.GetValue('Layout File')
        if ($file -and $file -ieq $LayoutFile) { $key.PSChildName.ToLowerInvariant() }
    }
}

function Uninstall-User([string[]]$Klids) {
    # InstallLayoutOrTip with ILOT_UNINSTALL removes exactly one input profile
    # (see Install.ps1 for why Set-WinUserLanguageList is avoided). Profiles
    # are matched by KLID, so the layout is also removed when the user added it
    # under a language other than Russian.
    if (-not ('KbdUninstall.Input' -as [type])) {
        Add-Type -Namespace KbdUninstall -Name Input -MemberDefinition '[DllImport("input.dll", CharSet = CharSet.Unicode)] public static extern bool InstallLayoutOrTip(string profile, uint flags);'
    }
    $tips = @(foreach ($lang in Get-WinUserLanguageList) { $lang.InputMethodTips })
    foreach ($tip in $tips) {
        $parts = "$tip".Split(':')
        if ($parts.Count -ne 2 -or $Klids -notcontains $parts[1].ToLowerInvariant()) { continue }
        if (-not [KbdUninstall.Input]::InstallLayoutOrTip($tip, 1)) { throw "InstallLayoutOrTip('$tip', ILOT_UNINSTALL) failed." }
        Write-Host "Removed $tip from the input methods of $env:USERNAME."
    }
}

function Remove-LogonScreenReference([string[]]$Klids) {
    # "Copy settings" in the Region control panel copies the user's input
    # methods to HKU\.DEFAULT (used by the logon screen): Preload lists KLIDs
    # or substitute names, Substitutes maps such names to KLIDs, and
    # Control Panel\International\User Profile holds "<lang>:<klid>" values.
    $base = 'Registry::HKEY_USERS\.DEFAULT'
    $names = @($Klids)
    $subs = "$base\Keyboard Layout\Substitutes"
    if (Test-Path $subs) {
        $key = Get-Item $subs
        foreach ($n in $key.GetValueNames()) {
            if ($Klids -contains "$($key.GetValue($n))".ToLowerInvariant()) {
                Remove-ItemProperty -Path $subs -Name $n
                $names += $n.ToLowerInvariant()
            }
        }
    }
    $preload = "$base\Keyboard Layout\Preload"
    if (Test-Path $preload) {
        $key = Get-Item $preload
        $entries = @($key.GetValueNames() | Where-Object { $_ -match '^\d+$' } | Sort-Object { [int]$_ } | ForEach-Object { "$($key.GetValue($_))" })
        $kept = @($entries | Where-Object { $names -notcontains $_.ToLowerInvariant() })
        if ($kept.Count -ne $entries.Count) {
            foreach ($n in $key.GetValueNames()) { if ($n -match '^\d+$') { Remove-ItemProperty -Path $preload -Name $n } }
            for ($i = 0; $i -lt $kept.Count; $i++) { Set-ItemProperty -Path $preload -Name "$($i + 1)" -Value $kept[$i] -Type String }
            Write-Step '  removed the layout from the logon screen keyboards'
        }
    }
    $profiles = "$base\Control Panel\International\User Profile"
    if (Test-Path $profiles) {
        foreach ($lang in Get-ChildItem $profiles) {
            foreach ($n in $lang.GetValueNames()) {
                $parts = $n.Split(':')
                if ($parts.Count -eq 2 -and $Klids -contains $parts[1].ToLowerInvariant()) {
                    Remove-ItemProperty -Path $lang.PSPath -Name $n
                }
            }
        }
    }
}

function Remove-LayoutFile([string]$Directory) {
    $target = Join-Path $Directory $LayoutFile
    if (-not (Test-Path -LiteralPath $target)) { return }
    try {
        Remove-Item -LiteralPath $target -Force
        Write-Step "  deleted $target"
    } catch {
        if (-not ('KbdUninstall.Native' -as [type])) {
            Add-Type -Namespace KbdUninstall -Name Native -MemberDefinition '[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool MoveFileEx(string existing, string replacement, int flags);'
        }
        if (-not [KbdUninstall.Native]::MoveFileEx($target, $null, 4)) { throw "Cannot delete $target." } # MOVEFILE_DELAY_UNTIL_REBOOT
        Write-Step "  $target is in use and will be deleted at the next restart"
    }
}

function Uninstall-Machine {
    $klids = @(Get-InstalledKlids)
    if ($klids.Count) { Remove-LogonScreenReference $klids }
    foreach ($klid in $klids) {
        Remove-Item -Recurse -Force (Join-Path $KeyboardLayouts $klid)
        Write-Step "  unregistered $klid"
    }
    $system = Join-Path $env:windir 'System32'
    if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) { $system = Join-Path $env:windir 'Sysnative' }
    Remove-LayoutFile $system
    if ([Environment]::Is64BitOperatingSystem) { Remove-LayoutFile (Join-Path $env:windir 'SysWOW64') }
}

function Invoke-ElevatedStep {
    # Runs this script with -MachineOnly through UAC, from a copy in the local
    # temp folder (the elevated session may not see network or SUBST drives),
    # always with the console host.
    $stage = Join-Path ([IO.Path]::GetTempPath()) ('kbdrumph-setup-' + [Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $stage
    try {
        Copy-Item -LiteralPath $PSCommandPath -Destination $stage
        $script = Join-Path $stage (Split-Path -Leaf $PSCommandPath)
        $log = Join-Path $stage 'machine.log'
        $exe = 'powershell.exe'
        if ($PSVersionTable.PSEdition -eq 'Core') { $exe = 'pwsh.exe' }
        $proc = Start-Process -FilePath (Join-Path $PSHOME $exe) -Verb RunAs -Wait -PassThru -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"", '-MachineOnly', '-LogFile', "`"$log`"")
        if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log | ForEach-Object { Write-Host $_ } }
        if ($proc.ExitCode -ne 0) { throw "The elevated uninstall step failed (exit code $($proc.ExitCode))." }
    } finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($MachineOnly) {
    try {
        if (-not (Test-Administrator)) { throw 'Administrator rights are required.' }
        Uninstall-Machine
    } catch {
        Write-Step ($_ | Out-String)
        throw
    }
    return
}

$klids = @(Get-InstalledKlids)
if ($klids.Count) { Uninstall-User $klids }
if ($UserOnly) { return }
if (Test-Administrator) { Uninstall-Machine } else { Invoke-ElevatedStep }
Write-Host 'Done. Sign out and back in to unload the layout from running applications.'
