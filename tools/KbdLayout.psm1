#Requires -Version 5.1
<#
.SYNOPSIS
    MSKLC (.klc) parser and keyboard layout DLL source generator.

.DESCRIPTION
    Reads a Microsoft Keyboard Layout Creator 1.4 source file and emits the C,
    resource and module-definition sources for a Windows keyboard layout DLL.
    The emitted tables follow the structure that MSKLC's kbdutool generates, so
    a layout built here behaves exactly like one built by MSKLC, but it can be
    compiled with a current MSVC toolset for ARM64, ARM64X, x64, x86 and WOW64,
    which MSKLC itself cannot do.

    Supported .klc features: KBD, COPYRIGHT, COMPANY, LOCALENAME, LOCALEID,
    VERSION, ATTRIBUTES (ALTGR, SHIFTLOCK, LRM_RLM), SHIFTSTATE, LAYOUT (Cap
    flags 0/1/4/5 and SGCap, dead keys "xxxx@", ligatures "%%"), DEADKEY,
    LIGATURE, KEYNAME, KEYNAME_EXT, KEYNAME_DEAD, DESCRIPTIONS, LANGUAGENAMES,
    ENDKBD. An SGCap key must be followed directly by one "-1 -1 ..." row that
    gives what the key types while Caps Lock is on; that row may only contain
    characters or -1, and an SGCap key cannot have dead keys or ligatures.
    Anything else that MSKLC would not compile is rejected rather than
    compiled incorrectly.
#>

Set-StrictMode -Version Latest

$script:Sections = @('KBD', 'COPYRIGHT', 'COMPANY', 'LOCALENAME', 'LOCALEID', 'VERSION', 'ATTRIBUTES',
    'SHIFTSTATE', 'LAYOUT', 'DEADKEY', 'LIGATURE', 'KEYNAME', 'KEYNAME_EXT', 'KEYNAME_DEAD',
    'DESCRIPTIONS', 'LANGUAGENAMES', 'ENDKBD')

# Keys that kbdutool always emits unless the LAYOUT section defines them.
$script:SpecialKeys = @(
    @{ Vk = 'TAB';      Values = @(0x09, 0x09) }
    @{ Vk = 'ADD';      Values = @(0x2B, 0x2B) }
    @{ Vk = 'DIVIDE';   Values = @(0x2F, 0x2F) }
    @{ Vk = 'MULTIPLY'; Values = @(0x2A, 0x2A) }
    @{ Vk = 'SUBTRACT'; Values = @(0x2D, 0x2D) }
    @{ Vk = 'BACK';     Values = @(0x08, 0x08, 0x7F) }
    @{ Vk = 'ESCAPE';   Values = @(0x1B, 0x1B, 0x1B) }
    @{ Vk = 'RETURN';   Values = @(0x0D, 0x0D, 0x0A) }
    @{ Vk = 'CANCEL';   Values = @(0x03, 0x03, 0x03) }
)

function Split-KlcLine {
    # Splits a .klc line into whitespace-separated tokens, honouring double
    # quotes and dropping "//" and ";" comments that appear outside quotes.
    param([string]$Line)
    $tokens = New-Object System.Collections.Generic.List[string]
    $i = 0
    while ($i -lt $Line.Length) {
        $c = $Line[$i]
        if ([char]::IsWhiteSpace($c)) { $i++; continue }
        if ($c -eq ';') { break }
        if ($c -eq '/' -and $i + 1 -lt $Line.Length -and $Line[$i + 1] -eq '/') { break }
        if ($c -eq '"') {
            $end = $Line.IndexOf('"', $i + 1)
            if ($end -lt 0) { throw "Unterminated string in line: $Line" }
            $tokens.Add($Line.Substring($i, $end - $i + 1))
            $i = $end + 1
            continue
        }
        $start = $i
        while ($i -lt $Line.Length -and -not [char]::IsWhiteSpace($Line[$i])) { $i++ }
        $tokens.Add($Line.Substring($start, $i - $start))
    }
    , $tokens.ToArray()
}

function Get-KlcText([string]$Line) {
    # DESCRIPTIONS / LANGUAGENAMES rows are "<lcid><TAB><free text>"; the text
    # may contain spaces and characters such as ';' so it is taken verbatim.
    $m = [regex]::Match($Line, '^\s*[0-9A-Fa-f]+\s+(.*?)\s*$')
    if (-not $m.Success) { throw "Invalid text row: $Line" }
    $m.Groups[1].Value
}

function Get-Unquoted([string]$Token) {
    if ($Token.Length -ge 2 -and $Token.StartsWith('"') -and $Token.EndsWith('"')) { return $Token.Substring(1, $Token.Length - 2) }
    $Token
}

function ConvertFrom-KlcValue {
    # Parses one LAYOUT cell: -1 | %% | xxxx[@] | c[@]
    param([string]$Token, [string]$Context)
    if ($Token -eq '-1') { return [pscustomobject]@{ Kind = 'None'; Code = $null } }
    if ($Token -eq '%%') { return [pscustomobject]@{ Kind = 'Ligature'; Code = $null } }
    $dead = $false
    if ($Token.Length -gt 1 -and $Token.EndsWith('@')) { $dead = $true; $Token = $Token.Substring(0, $Token.Length - 1) }
    if ($Token -match '^[0-9A-Fa-f]{4}$') { $code = [Convert]::ToInt32($Token, 16) }
    elseif ($Token.Length -eq 1) { $code = [int][char]$Token }
    else { throw "Invalid character value '$Token' ($Context)" }
    if ($code -ge 0xD800 -and $code -le 0xDFFF) { throw "Surrogate code points are not supported ($Context)" }
    $kind = 'Char'
    if ($dead) { $kind = 'Dead' }
    [pscustomobject]@{ Kind = $kind; Code = $code }
}

function ConvertFrom-KlcHex([string]$Token, [string]$Context) {
    if ($Token.Length -eq 1) { return [int][char]$Token }
    if ($Token -notmatch '^[0-9A-Fa-f]{1,4}$') { throw "Invalid hex value '$Token' ($Context)" }
    [Convert]::ToInt32($Token, 16)
}

function Read-KlcLayout {
    <#
    .SYNOPSIS
        Parses an MSKLC .klc file (UTF-16 or UTF-8) into a layout object.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).ProviderPath)
    $layout = [ordered]@{
        Name = $null; Description = $null; Copyright = ''; Company = ''; LocaleName = ''; LocaleId = $null
        Version = '1.0'; Attributes = New-Object System.Collections.Generic.List[string]
        ShiftStates = New-Object System.Collections.Generic.List[int]
        Keys = New-Object System.Collections.Generic.List[object]
        DeadKeys = [ordered]@{}
        Ligatures = New-Object System.Collections.Generic.List[object]
        KeyNames = New-Object System.Collections.Generic.List[object]
        KeyNamesExt = New-Object System.Collections.Generic.List[object]
        KeyNamesDead = New-Object System.Collections.Generic.List[object]
        Descriptions = [ordered]@{}
        LanguageNames = [ordered]@{}
    }
    $section = $null
    $deadKey = $null
    $lineNo = 0
    $ended = $false
    foreach ($rawLine in ($text -split "`r?`n")) {
        $lineNo++
        if ($ended) { break }
        $tokens = Split-KlcLine $rawLine
        if ($tokens.Count -eq 0) { continue }
        $ctx = "line $lineNo"
        $head = $tokens[0]
        if ($script:Sections -contains $head) {
            $section = $head
            switch ($head) {
                'KBD' {
                    if ($tokens.Count -lt 3) { throw "KBD needs a name and a description ($ctx)" }
                    $layout.Name = $tokens[1]
                    $layout.Description = Get-Unquoted $tokens[2]
                }
                'COPYRIGHT' { $layout.Copyright = Get-Unquoted $tokens[1] }
                'COMPANY' { $layout.Company = Get-Unquoted $tokens[1] }
                'LOCALENAME' { $layout.LocaleName = Get-Unquoted $tokens[1] }
                'LOCALEID' { $layout.LocaleId = [Convert]::ToUInt32((Get-Unquoted $tokens[1]), 16) }
                'VERSION' { $layout.Version = $tokens[1] }
                'DEADKEY' {
                    # Ordered dictionaries index by position when given an int,
                    # so every code-point keyed map uses 'xxxx' string keys.
                    $deadKey = '{0:x4}' -f (ConvertFrom-KlcHex $tokens[1] $ctx)
                    if ($layout.DeadKeys.Contains($deadKey)) { throw "Duplicate DEADKEY $($tokens[1]) ($ctx)" }
                    $layout.DeadKeys[$deadKey] = New-Object System.Collections.Generic.List[object]
                }
                'ENDKBD' { $ended = $true }
            }
            continue
        }
        switch ($section) {
            'ATTRIBUTES' { $layout.Attributes.Add($head.ToUpperInvariant()) }
            'SHIFTSTATE' { $layout.ShiftStates.Add([int]$head) }
            'LAYOUT' {
                $n = $layout.ShiftStates.Count
                if ($tokens.Count -lt 3 + $n) { throw "LAYOUT row needs $n shift-state columns ($ctx)" }
                $values = @()
                for ($c = 0; $c -lt $n; $c++) { $values += ConvertFrom-KlcValue $tokens[3 + $c] "$ctx, column $c" }
                if ($head -eq '-1') {
                    # SGCap continuation row: what the previous key types while Caps Lock is on.
                    $prev = $null
                    if ($layout.Keys.Count) { $prev = $layout.Keys[$layout.Keys.Count - 1] }
                    if (-not $prev -or -not $prev.SGCap -or $prev.CapsValues) { throw "Unexpected SGCap continuation row ($ctx)" }
                    if (@($values | Where-Object { $_.Kind -ne 'Char' -and $_.Kind -ne 'None' }).Count) { throw "SGCap rows may only contain characters ($ctx)" }
                    $prev.CapsValues = $values
                    continue
                }
                $sgcap = $tokens[2] -ieq 'SGCap'
                if ($sgcap) { $cap = 0 } else { $cap = [int]$tokens[2] }
                if (@(0, 1, 4, 5) -notcontains $cap) { throw "Unsupported Cap value $cap ($ctx)" }
                $layout.Keys.Add([pscustomobject]@{
                    Scancode = [Convert]::ToInt32($head, 16); Vk = $tokens[1].ToUpperInvariant(); Cap = $cap
                    SGCap = $sgcap; Values = $values; CapsValues = $null
                })
            }
            'DEADKEY' {
                $layout.DeadKeys[$deadKey].Add([pscustomobject]@{
                    Base = ConvertFrom-KlcHex $tokens[0] $ctx; Composed = ConvertFrom-KlcHex $tokens[1] $ctx
                })
            }
            'LIGATURE' {
                $chars = @()
                for ($c = 2; $c -lt $tokens.Count; $c++) { $chars += ConvertFrom-KlcHex $tokens[$c] $ctx }
                $layout.Ligatures.Add([pscustomobject]@{ Vk = $tokens[0].ToUpperInvariant(); Column = [int]$tokens[1]; Chars = $chars })
            }
            'KEYNAME' { $layout.KeyNames.Add([pscustomobject]@{ Scancode = [Convert]::ToInt32($head, 16); Name = Get-Unquoted $tokens[1] }) }
            'KEYNAME_EXT' { $layout.KeyNamesExt.Add([pscustomobject]@{ Scancode = [Convert]::ToInt32($head, 16); Name = Get-Unquoted $tokens[1] }) }
            'KEYNAME_DEAD' { $layout.KeyNamesDead.Add([pscustomobject]@{ Char = ConvertFrom-KlcHex $head $ctx; Name = Get-Unquoted $tokens[1] }) }
            'DESCRIPTIONS' { $layout.Descriptions['{0:x4}' -f [Convert]::ToInt32($head, 16)] = Get-KlcText $rawLine }
            'LANGUAGENAMES' { $layout.LanguageNames['{0:x4}' -f [Convert]::ToInt32($head, 16)] = Get-KlcText $rawLine }
            default { throw "Unexpected content outside a known section ($ctx): $rawLine" }
        }
    }
    if (-not $layout.Name) { throw 'Missing KBD line.' }
    if ($layout.Name.Length -gt 8) { throw "KBD name '$($layout.Name)' is longer than 8 characters (MSKLC limit)." }
    if ($null -eq $layout.LocaleId) { throw 'Missing LOCALEID.' }
    if ($layout.ShiftStates.Count -lt 2 -or $layout.ShiftStates[0] -ne 0 -or $layout.ShiftStates[1] -ne 1) { throw 'SHIFTSTATE must start with 0 and 1.' }
    foreach ($s in $layout.ShiftStates) { if ($s -lt 0 -or $s -gt 7 -or $s -eq 4 -or $s -eq 5) { throw "Unsupported shift state $s (Alt without Ctrl is not allowed)." } }
    if (-not $layout.ShiftStates.Contains(2)) { throw 'SHIFTSTATE must include 2 (Ctrl) so that Backspace/Esc/Enter/Break get their control characters.' }

    # Cross-checks that MSKLC also performs.
    $seenSc = @{}; $seenVk = @{}
    foreach ($k in $layout.Keys) {
        if ($seenSc.ContainsKey($k.Scancode)) { throw ('Scancode {0:x2} is defined twice.' -f $k.Scancode) }
        if ($seenVk.ContainsKey($k.Vk)) { throw "Virtual key $($k.Vk) is defined twice." }
        $seenSc[$k.Scancode] = $true; $seenVk[$k.Vk] = $true
        if ($k.SGCap) {
            if (-not $k.CapsValues) { throw "SGCap key $($k.Vk) has no continuation row." }
            if (@($k.Values | Where-Object { $_.Kind -eq 'Dead' -or $_.Kind -eq 'Ligature' }).Count) { throw "SGCap key $($k.Vk) cannot also have dead keys or ligatures." }
        }
        for ($c = 0; $c -lt $k.Values.Count; $c++) {
            $v = $k.Values[$c]
            if ($v.Kind -eq 'Dead' -and -not $layout.DeadKeys.Contains(('{0:x4}' -f $v.Code))) { throw ('Dead key {0:x4} on {1} has no DEADKEY table.' -f $v.Code, $k.Vk) }
            if ($v.Kind -eq 'Ligature' -and -not ($layout.Ligatures | Where-Object { $_.Vk -eq $k.Vk -and $_.Column -eq $c })) { throw "Ligature on $($k.Vk) column $c has no LIGATURE entry." }
        }
    }
    [pscustomobject]$layout
}

function Format-WChar {
    param([int]$Code)
    if ($Code -ge 0x20 -and $Code -le 0x7E -and $Code -ne 0x27 -and $Code -ne 0x5C -and $Code -ne 0x22) { return "'$([char]$Code)'" }
    switch ($Code) {
        0x27 { return "'\''" }
        0x5C { return "'\\'" }
        0x22 { return "'\`"'" }
    }
    '0x{0:x4}' -f $Code
}

function Format-CString([string]$Value) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Value.ToCharArray()) {
        $code = [int]$ch
        if ($code -ge 0x20 -and $code -le 0x7E -and $ch -ne '"' -and $ch -ne '\') { [void]$sb.Append($ch) }
        else { [void]$sb.Append(('\x{0:x4}" L"' -f $code)) }
    }
    'L"' + $sb.ToString() + '"'
}

function Format-RcString([string]$Value) {
    # .rc files are compiled as UTF-8 (#pragma code_page(65001)); only quotes need escaping.
    '"' + $Value.Replace('"', '""') + '"'
}

function Get-VkExpression([string]$Vk) {
    if ($Vk -match '^[0-9A-Z]$') { return "'$Vk'" }
    "VK_$Vk"
}

function Get-VersionParts([string]$Version, [int]$Build) {
    $parts = @($Version.Split('.') | ForEach-Object { [int]$_ })
    while ($parts.Count -lt 2) { $parts += 0 }
    @($parts[0], $parts[1], $Build, 0)
}

function Write-KbdSources {
    <#
    .SYNOPSIS
        Emits <name>.c, <name>.rc and <name>.def for a parsed layout.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Layout,
        [Parameter(Mandatory)][string]$OutDir,
        [int]$Build = 0,
        [string]$SourceName = ''
    )
    $null = New-Item -ItemType Directory -Force -Path $OutDir
    $name = $Layout.Name
    $nl = "`r`n"
    $states = @($Layout.ShiftStates)
    $nCols = $states.Count
    $c = New-Object System.Text.StringBuilder
    function Add([string]$s) { [void]$c.Append($s).Append($nl) }

    Add '/*'
    Add " * $name.c - keyboard layout tables for `"$($Layout.Description)`"."
    Add ' *'
    Add " * GENERATED by tools/KbdLayout.psm1 from $SourceName. Do not edit by hand."
    Add " * $($Layout.Copyright)"
    Add ' */'
    Add ''
    Add '#include <windows.h>'
    Add '#define KBD_TYPE 4'
    Add '#include <kbd.h>'
    Add ''
    Add '#if defined(_M_IA64)'
    Add '#pragma section(".data")'
    Add '#define ALLOC_SECTION_LDATA __declspec(allocate(".data"))'
    Add '#else'
    Add '#pragma data_seg(".data")'
    Add '#define ALLOC_SECTION_LDATA'
    Add '#endif'
    Add ''

    # Scancode -> VK overrides for the alphanumeric block (numpad scancodes keep
    # their KBDNUMPAD | KBDSPECIAL defaults, exactly as kbdutool does).
    $overrides = @($Layout.Keys | Where-Object { $_.Scancode -le 0x7E -and -not ($_.Scancode -ge 0x47 -and $_.Scancode -le 0x53) })
    if ($overrides.Count) {
        Add '/* Scancode to virtual key assignments from the LAYOUT section. */'
        foreach ($k in $overrides) {
            $t = 'T{0:X2}' -f $k.Scancode
            if ($k.Vk -match '^[0-9A-Z]$') { $vkName = "'$($k.Vk)'" } else { $vkName = $k.Vk }
            Add "#undef $t"
            Add "#define $t _EQ($vkName)"
        }
        Add ''
    }

    Add @'
static ALLOC_SECTION_LDATA USHORT ausVK[] = {
    T00, T01, T02, T03, T04, T05, T06, T07,
    T08, T09, T0A, T0B, T0C, T0D, T0E, T0F,
    T10, T11, T12, T13, T14, T15, T16, T17,
    T18, T19, T1A, T1B, T1C, T1D, T1E, T1F,
    T20, T21, T22, T23, T24, T25, T26, T27,
    T28, T29, T2A, T2B, T2C, T2D, T2E, T2F,
    T30, T31, T32, T33, T34, T35,
    T36 | KBDEXT,                   /* Right Shift */
    T37 | KBDMULTIVK,               /* numpad * + Shift/Alt -> SnapShot */
    T38, T39, T3A, T3B, T3C, T3D, T3E,
    T3F, T40, T41, T42, T43, T44,
    T45 | KBDEXT | KBDMULTIVK,      /* NumLock / Pause */
    T46 | KBDMULTIVK,
    T47 | KBDNUMPAD | KBDSPECIAL,   /* Numpad 7 (Home) */
    T48 | KBDNUMPAD | KBDSPECIAL,   /* Numpad 8 (Up) */
    T49 | KBDNUMPAD | KBDSPECIAL,   /* Numpad 9 (PgUp) */
    T4A,
    T4B | KBDNUMPAD | KBDSPECIAL,   /* Numpad 4 (Left) */
    T4C | KBDNUMPAD | KBDSPECIAL,   /* Numpad 5 (Clear) */
    T4D | KBDNUMPAD | KBDSPECIAL,   /* Numpad 6 (Right) */
    T4E,
    T4F | KBDNUMPAD | KBDSPECIAL,   /* Numpad 1 (End) */
    T50 | KBDNUMPAD | KBDSPECIAL,   /* Numpad 2 (Down) */
    T51 | KBDNUMPAD | KBDSPECIAL,   /* Numpad 3 (PgDn) */
    T52 | KBDNUMPAD | KBDSPECIAL,   /* Numpad 0 (Ins) */
    T53 | KBDNUMPAD | KBDSPECIAL,   /* Numpad . (Del) */
    T54, T55, T56, T57, T58, T59, T5A, T5B,
    T5C, T5D, T5E, T5F, T60, T61, T62, T63,
    T64, T65, T66, T67, T68, T69, T6A, T6B,
    T6C, T6D, T6E, T6F, T70, T71, T72, T73,
    T74, T75, T76, T77, T78, T79, T7A, T7B,
    T7C, T7D, T7E
};

static ALLOC_SECTION_LDATA VSC_VK aE0VscToVk[] = {
    { 0x10, X10 | KBDEXT },  /* Previous Track */
    { 0x19, X19 | KBDEXT },  /* Next Track */
    { 0x1D, X1D | KBDEXT },  /* RControl */
    { 0x20, X20 | KBDEXT },  /* Volume Mute */
    { 0x21, X21 | KBDEXT },  /* Launch App 2 */
    { 0x22, X22 | KBDEXT },  /* Media Play/Pause */
    { 0x24, X24 | KBDEXT },  /* Media Stop */
    { 0x2E, X2E | KBDEXT },  /* Volume Down */
    { 0x30, X30 | KBDEXT },  /* Volume Up */
    { 0x32, X32 | KBDEXT },  /* Browser Home */
    { 0x35, X35 | KBDEXT },  /* Numpad Divide */
    { 0x37, X37 | KBDEXT },  /* Snapshot */
    { 0x38, X38 | KBDEXT },  /* RMenu */
    { 0x47, X47 | KBDEXT },  /* Home */
    { 0x48, X48 | KBDEXT },  /* Up */
    { 0x49, X49 | KBDEXT },  /* Prior */
    { 0x4B, X4B | KBDEXT },  /* Left */
    { 0x4D, X4D | KBDEXT },  /* Right */
    { 0x4F, X4F | KBDEXT },  /* End */
    { 0x50, X50 | KBDEXT },  /* Down */
    { 0x51, X51 | KBDEXT },  /* Next */
    { 0x52, X52 | KBDEXT },  /* Insert */
    { 0x53, X53 | KBDEXT },  /* Delete */
    { 0x5B, X5B | KBDEXT },  /* Left Win */
    { 0x5C, X5C | KBDEXT },  /* Right Win */
    { 0x5D, X5D | KBDEXT },  /* Application */
    { 0x5F, X5F | KBDEXT },  /* Sleep */
    { 0x65, X65 | KBDEXT },  /* Browser Search */
    { 0x66, X66 | KBDEXT },  /* Browser Favorites */
    { 0x67, X67 | KBDEXT },  /* Browser Refresh */
    { 0x68, X68 | KBDEXT },  /* Browser Stop */
    { 0x69, X69 | KBDEXT },  /* Browser Forward */
    { 0x6A, X6A | KBDEXT },  /* Browser Back */
    { 0x6B, X6B | KBDEXT },  /* Launch App 1 */
    { 0x6C, X6C | KBDEXT },  /* Launch Mail */
    { 0x6D, X6D | KBDEXT },  /* Launch Media Selector */
    { 0x1C, X1C | KBDEXT },  /* Numpad Enter */
    { 0x46, X46 | KBDEXT },  /* Break (Ctrl + Pause) */
    { 0,    0 }
};

static ALLOC_SECTION_LDATA VSC_VK aE1VscToVk[] = {
    { 0x1D, Y1D },           /* Pause */
    { 0,    0 }
};

static ALLOC_SECTION_LDATA VK_TO_BIT aVkToBits[] = {
    { VK_SHIFT,   KBDSHIFT },
    { VK_CONTROL, KBDCTRL  },
    { VK_MENU,    KBDALT   },
    { 0,          0        }
};
'@

    $maxBits = ($states | Measure-Object -Maximum).Maximum
    $stateNames = @('Base', 'Shift', 'Ctrl', 'Shift+Ctrl', 'Alt', 'Shift+Alt', 'Ctrl+Alt (AltGr)', 'Shift+Ctrl+Alt (Shift+AltGr)')
    Add ''
    Add 'static ALLOC_SECTION_LDATA MODIFIERS CharModifiers = {'
    Add '    &aVkToBits[0],'
    Add "    $maxBits,"
    Add '    {'
    for ($bits = 0; $bits -le $maxBits; $bits++) {
        $col = $states.IndexOf($bits)
        $sep = ','
        if ($bits -eq $maxBits) { $sep = '' }
        if ($col -ge 0) { $val = "$col" } else { $val = 'SHFT_INVALID' }
        Add ('        {0}{1} /* {2} */' -f $val, $sep, $stateNames[$bits])
    }
    Add '    }'
    Add '};'
    Add ''

    # Group rows into VK_TO_WCHARS<n> tables the way kbdutool does.
    $tables = @{}
    function Add-Row([int]$n, [string]$row) {
        if (-not $tables.Contains($n)) { $tables[$n] = New-Object System.Collections.Generic.List[string] }
        $tables[$n].Add($row)
    }
    $defined = @{}
    foreach ($k in $Layout.Keys) { $defined[$k.Vk] = $true }
    foreach ($s in $script:SpecialKeys) {
        if ($defined.ContainsKey($s.Vk)) { continue }
        $cells = @($s.Values | ForEach-Object { Format-WChar $_ })
        Add-Row $cells.Count ('    {{ {0,-14}, 0, {1} }},' -f "VK_$($s.Vk)", ($cells -join ', '))
    }
    foreach ($k in $Layout.Keys) {
        $attrs = @()
        if ($k.Cap -band 1) { $attrs += 'CAPLOK' }
        if ($k.SGCap) { $attrs += 'SGCAPS' }
        if ($k.Cap -band 4) { $attrs += 'CAPLOKALTGR' }
        if ($attrs.Count) { $attr = $attrs -join ' | ' } else { $attr = '0' }
        $cells = @()
        $deadCells = @()
        $hasDead = $false
        foreach ($v in $k.Values) {
            switch ($v.Kind) {
                'None' { $cells += 'WCH_NONE'; $deadCells += 'WCH_NONE' }
                'Ligature' { $cells += 'WCH_LGTR'; $deadCells += 'WCH_NONE' }
                'Dead' { $cells += 'WCH_DEAD'; $deadCells += (Format-WChar $v.Code); $hasDead = $true }
                default { $cells += (Format-WChar $v.Code); $deadCells += 'WCH_NONE' }
            }
        }
        $label = ''
        if ($k.Vk -notmatch '^[0-9A-Z]$') { $label = '' }
        Add-Row $nCols ('    {{ {0,-14}, {1}, {2} }},{3}' -f (Get-VkExpression $k.Vk), $attr, ($cells -join ', '), $label)
        if ($hasDead) { Add-Row $nCols ('    {{ {0,-14}, 0, {1} }},' -f '0xff', ($deadCells -join ', ')) }
        if ($k.SGCap) {
            # Caps Lock row: same VK, read by win32k instead of the row above while Caps Lock is on.
            $capsCells = @($k.CapsValues | ForEach-Object { if ($_.Kind -eq 'None') { 'WCH_NONE' } else { Format-WChar $_.Code } })
            Add-Row $nCols ('    {{ {0,-14}, 0, {1} }},' -f (Get-VkExpression $k.Vk), ($capsCells -join ', '))
        }
    }
    foreach ($d in 0..9) { Add-Row 1 ('    {{ {0,-14}, 0, {1} }},' -f "VK_NUMPAD$d", (Format-WChar (0x30 + $d))) }

    # Table order: n >= 3 ascending, then 2, then the numpad table (1) last so
    # that VkKeyScan prefers the main keyboard for digits.
    $order = @($tables.Keys | Where-Object { $_ -ge 3 } | Sort-Object) + @($tables.Keys | Where-Object { $_ -eq 2 }) + @($tables.Keys | Where-Object { $_ -eq 1 })
    foreach ($n in $order) {
        Add "static ALLOC_SECTION_LDATA VK_TO_WCHARS$n aVkToWch$n[] = {"
        if ($n -eq $nCols -and $n -gt 1) {
            $hdr = @(); for ($i = 0; $i -lt $nCols; $i++) { $hdr += $stateNames[$states[$i]] }
            Add "    /* VK, attributes, $($hdr -join ' | ') */"
        }
        foreach ($row in $tables[$n]) { Add $row }
        $zeros = @(); for ($i = 0; $i -lt $n; $i++) { $zeros += '0' }
        Add ('    {{ 0, 0, {0} }}' -f ($zeros -join ', '))
        Add '};'
        Add ''
    }
    Add 'static ALLOC_SECTION_LDATA VK_TO_WCHAR_TABLE aVkToWcharTable[] = {'
    foreach ($n in $order) { Add "    { (PVK_TO_WCHARS1)aVkToWch$n, $n, sizeof(aVkToWch$n[0]) }," }
    Add '    { NULL, 0, 0 }'
    Add '};'
    Add ''

    foreach ($pair in @(@('aKeyNames', $Layout.KeyNames), @('aKeyNamesExt', $Layout.KeyNamesExt))) {
        Add "static ALLOC_SECTION_LDATA VSC_LPWSTR $($pair[0])[] = {"
        foreach ($kn in $pair[1]) { Add ('    {{ 0x{0:x2}, {1} }},' -f $kn.Scancode, (Format-CString $kn.Name)) }
        Add '    { 0, NULL }'
        Add '};'
        Add ''
    }

    $hasDeadKeys = $Layout.DeadKeys.Count -gt 0
    if ($hasDeadKeys) {
        Add 'static ALLOC_SECTION_LDATA DEADKEY_LPWSTR aKeyNamesDead[] = {'
        foreach ($kn in $Layout.KeyNamesDead) { Add ('    {0} {1},' -f (Format-CString ([string][char]$kn.Char)), (Format-CString $kn.Name)) }
        Add '    NULL'
        Add '};'
        Add ''
        Add 'static ALLOC_SECTION_LDATA DEADKEY aDeadKey[] = {'
        foreach ($accent in $Layout.DeadKeys.Keys) {
            foreach ($e in $Layout.DeadKeys[$accent]) {
                Add ('    DEADTRANS({0}, 0x{1}, {2}, 0x0000),' -f (Format-WChar $e.Base), $accent, (Format-WChar $e.Composed))
            }
            Add ''
        }
        Add '    0, 0'
        Add '};'
        Add ''
    }

    $hasLigatures = $Layout.Ligatures.Count -gt 0
    $lgMax = 0
    if ($hasLigatures) {
        $lgMax = ($Layout.Ligatures | ForEach-Object { $_.Chars.Count } | Measure-Object -Maximum).Maximum
        Add "static ALLOC_SECTION_LDATA LIGATURE$lgMax aLigature[] = {"
        foreach ($l in $Layout.Ligatures) {
            $chars = @($l.Chars | ForEach-Object { Format-WChar $_ })
            while ($chars.Count -lt $lgMax) { $chars += 'WCH_NONE' }
            Add ('    {{ {0}, {1}, {2} }},' -f (Get-VkExpression $l.Vk), $l.Column, ($chars -join ', '))
        }
        $zeros = @(); for ($i = 0; $i -lt $lgMax; $i++) { $zeros += '0' }
        Add ('    {{ 0, 0, {0} }}' -f ($zeros -join ', '))
        Add '};'
        Add ''
    }

    $flags = @()
    if ($Layout.Attributes.Contains('ALTGR') -or $states -contains 6 -or $states -contains 7) { $flags += 'KLLF_ALTGR' }
    if ($Layout.Attributes.Contains('SHIFTLOCK')) { $flags += 'KLLF_SHIFTLOCK' }
    if ($Layout.Attributes.Contains('LRM_RLM')) { $flags += 'KLLF_LRM_RLM' }
    if ($flags.Count) { $flagExpr = $flags -join ' | ' } else { $flagExpr = '0' }
    $deadPtr = 'NULL'; $deadNamesPtr = 'NULL'
    if ($hasDeadKeys) { $deadPtr = 'aDeadKey'; $deadNamesPtr = 'aKeyNamesDead' }
    if ($hasLigatures) { $lig = "    $lgMax,$nl    sizeof(aLigature[0]),$nl    (PLIGATURE1)aLigature" } else { $lig = "    0,$nl    0,$nl    NULL" }

    Add 'static ALLOC_SECTION_LDATA KBDTABLES KbdTables = {'
    Add '    &CharModifiers,'
    Add '    aVkToWcharTable,'
    Add "    $deadPtr,"
    Add '    aKeyNames,'
    Add '    aKeyNamesExt,'
    Add "    $deadNamesPtr,"
    Add '    ausVK,'
    Add '    sizeof(ausVK) / sizeof(ausVK[0]),'
    Add '    aE0VscToVk,'
    Add '    aE1VscToVk,'
    Add "    MAKELONG($flagExpr, KBD_VERSION),"
    Add $lig
    Add '};'
    Add ''
    Add 'PKBDTABLES KbdLayerDescriptor(VOID)'
    Add '{'
    Add '    return &KbdTables;'
    Add '}'
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $OutDir "$name.c"), $c.ToString(), $utf8)

    # Module definition file.
    $def = "LIBRARY $name$nl${nl}EXPORTS$nl    KbdLayerDescriptor @1$nl"
    [IO.File]::WriteAllText((Join-Path $OutDir "$name.def"), $def, $utf8)

    # Resources: version info plus the string ids MSKLC uses
    # (1000 = layout display name, 1100 = language name, 1200 = locale name).
    $v = Get-VersionParts $Layout.Version $Build
    $vComma = $v -join ','
    $vDot = $v -join '.'
    $lcid = $Layout.LocaleId -band 0xFFFF
    $desc = $Layout.Description
    if ($Layout.Descriptions.Contains('0409')) { $desc = $Layout.Descriptions['0409'] }
    $r = New-Object System.Text.StringBuilder
    function AddR([string]$s) { [void]$r.Append($s).Append($nl) }
    AddR '#pragma code_page(65001)'
    AddR '#include <winver.h>'
    AddR ''
    AddR 'VS_VERSION_INFO VERSIONINFO'
    AddR "  FILEVERSION    $vComma"
    AddR "  PRODUCTVERSION $vComma"
    AddR '  FILEFLAGSMASK  VS_FFI_FILEFLAGSMASK'
    AddR '  FILEFLAGS      0'
    AddR '  FILEOS         VOS_NT_WINDOWS32'
    AddR '  FILETYPE       VFT_DLL'
    AddR '  FILESUBTYPE    VFT2_DRV_KEYBOARD'
    AddR 'BEGIN'
    AddR '    BLOCK "StringFileInfo"'
    AddR '    BEGIN'
    AddR '        BLOCK "000004B0"'
    AddR '        BEGIN'
    AddR "            VALUE `"CompanyName`",      $(Format-RcString $Layout.Company)"
    AddR "            VALUE `"FileDescription`",  $(Format-RcString ($desc + ' Keyboard Layout'))"
    AddR "            VALUE `"FileVersion`",      $(Format-RcString $vDot)"
    AddR "            VALUE `"InternalName`",     $(Format-RcString $name.ToLowerInvariant())"
    AddR "            VALUE `"LegalCopyright`",   $(Format-RcString $Layout.Copyright)"
    AddR "            VALUE `"OriginalFilename`", $(Format-RcString ($name.ToLowerInvariant() + '.dll'))"
    AddR "            VALUE `"ProductName`",      $(Format-RcString $Layout.Description)"
    AddR "            VALUE `"ProductVersion`",   $(Format-RcString $vDot)"
    AddR '        END'
    AddR '    END'
    AddR '    BLOCK "VarFileInfo"'
    AddR '    BEGIN'
    AddR '        VALUE "Translation", 0x0000, 0x04B0'
    AddR '    END'
    AddR 'END'
    AddR ''
    $langs = @($Layout.Descriptions.Keys)
    if ($langs.Count -eq 0) { $langs = @('0409'); $Layout.Descriptions['0409'] = $Layout.Description }
    foreach ($ui in $langs) {
        $langId = [Convert]::ToInt32($ui, 16)
        AddR ('STRINGTABLE LANGUAGE 0x{0:x2}, 0x{1:x2}' -f ($langId -band 0x3FF), ($langId -shr 10))
        AddR 'BEGIN'
        AddR "    1000 $(Format-RcString $Layout.Descriptions[$ui])"
        if ($Layout.LanguageNames.Contains($ui)) { AddR "    1100 $(Format-RcString $Layout.LanguageNames[$ui])" }
        AddR "    1200 $(Format-RcString $Layout.LocaleName)"
        AddR 'END'
        AddR ''
    }
    [IO.File]::WriteAllText((Join-Path $OutDir "$name.rc"), $r.ToString(), $utf8)
    [pscustomobject]@{ Name = $name; C = (Join-Path $OutDir "$name.c"); Rc = (Join-Path $OutDir "$name.rc"); Def = (Join-Path $OutDir "$name.def"); LocaleId = $lcid }
}

Export-ModuleMember -Function Read-KlcLayout, Write-KbdSources
