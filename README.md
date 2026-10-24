# Russian – QWERTY (Mac) keyboard layout for Windows

[![build](https://github.com/trukhinyuri/phonetic-ru-keyboard-windows8/actions/workflows/build.yml/badge.svg)](https://github.com/trukhinyuri/phonetic-ru-keyboard-windows8/actions/workflows/build.yml)

Apple's macOS **Russian – QWERTY** layout (called **Russian – Phonetic** before
macOS renamed it; `com.apple.keylayout.Russian-Phonetic`) for Windows 10 and
Windows 11 on **ARM64**, **x64** and **x86**. Every key, every Shift and Option
combination and the Mac Caps Lock behaviour come from Apple's own layout data,
and automated tests check them against Windows itself.

![Russian – QWERTY (Mac) layout](docs/layout.svg)

*Left: Shift / base. Right, coloured: Shift+AltGr / AltGr, the Mac Option layer.*

[Русская версия ниже](#по-русски).

## Install

1. Download `kbdrumph-<version>.zip` from the
   [latest release](https://github.com/trukhinyuri/phonetic-ru-keyboard-windows8/releases/latest)
   (or the `package` artifact of the latest
   [build](https://github.com/trukhinyuri/phonetic-ru-keyboard-windows8/actions/workflows/build.yml)).
2. Extract it to a folder on a local disk and double-click **`install.cmd`**.
   Approve the administrator prompt.
3. Switch layouts with **Win+Space**. The layout is listed under Russian as
   *Russian - QWERTY (Mac)*. If an already running application does not pick it
   up, sign out and back in.

To remove it, run **`uninstall.cmd`** from the same folder.

The installer works on every Windows architecture and only touches what it
installs. It places the native DLL in `System32` and the 32-bit (WOW64) DLL in
`SysWOW64`, and registers the layout under
`HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layouts`, picking a free
`A0xx0419` identifier the way MSKLC does. It then adds the layout to your input
methods with `InstallLayoutOrTip`, the same API that MSKLC's installer uses.
Your other languages and keyboards are left as they are. Running it again
upgrades an installed copy in place. From PowerShell you can also run
`powershell -ExecutionPolicy Bypass -File .\Install.ps1` (or `Uninstall.ps1`).

The DLLs are not code-signed, like every layout made with MSKLC. If
[Smart App Control](https://support.microsoft.com/topic/what-is-smart-app-control-285ea03d-fa88-4d56-882e-6698afdb7003)
is turned on, Windows may refuse to load them.

### Upgrading from 1.x

The 1.x layouts use other DLL names, so 2.0 installs next to them instead of
replacing them, and `install.cmd` warns when one is still present. To remove an
old one:

1. Remove the old keyboard under *Settings > Time & language > Language &
   region > Russian > Keyboards*.
2. If it came from one of the 2013 installers ("Russian - Phonetic - Trukhin
   ..."), uninstall it from *Settings > Apps > Installed apps*.
3. The 2025 ARM64 workaround ("Russian Phonetic (QWERTY)", `RuPhon.dll`) and the
   MacBook Pro 16 DLLs (`RTruk16.dll`) have no uninstaller. As administrator,
   delete the key under
   `HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layouts` whose `Layout File`
   is that DLL, then delete the DLL from `System32` (and `SysWOW64`).

## The layout

| | macOS | Windows |
|---|---|---|
| Letters, digits, punctuation | as on the Mac (`я ш е р т ы у и о п ю ж э`, `а с д ф г ч й к л`, `з х ц в б н м`, `щ` on <kbd>&#96;</kbd>, `ь ъ` on <kbd>-</kbd> <kbd>=</kbd>) | identical |
| Option layer (`ё`, `є ї і ґ ў`, `ђ љ њ ћ џ ѕ ј`, `« » „ “ ” ’`, `₽ № § ¶ • ° ≈ ≤ ≥ …`, `[ ] { } \`) | <kbd>Option</kbd> and <kbd>Shift</kbd>+<kbd>Option</kbd> | <kbd>AltGr</kbd> (right <kbd>Alt</kbd>) and <kbd>Shift</kbd>+<kbd>AltGr</kbd> |
| Caps Lock | selects the whole Shift layer, digits and punctuation too; <kbd>Shift</kbd> does not undo it | identical |
| Option+Space | no-break space | <kbd>AltGr</kbd>+<kbd>Space</kbd> |
| Keypad decimal key | `,` | `,` |

Some practical notes:

- **ё** is <kbd>AltGr</kbd>+<kbd>E</kbd> or <kbd>AltGr</kbd>+<kbd>2</kbd>, and
  **Ё** adds <kbd>Shift</kbd>, just like Option on the Mac. **₽** is
  <kbd>AltGr</kbd>+<kbd>R</kbd>.
- Brackets are on <kbd>AltGr</kbd>+<kbd>9</kbd>/<kbd>0</kbd> (`[` `]`) and
  <kbd>Shift</kbd>+<kbd>AltGr</kbd>+<kbd>9</kbd>/<kbd>0</kbd> (`{` `}`), and
  backslash is on <kbd>Shift</kbd>+<kbd>AltGr</kbd>+<kbd>/</kbd>. As on the Mac,
  `_ | ~` are not part of this layout, so type them in your English layout.
- Shortcuts are not affected: <kbd>Ctrl</kbd>+<kbd>C</kbd>, <kbd>Ctrl</kbd>+<kbd>V</kbd>
  and the rest work as in English layouts. Terminal control keys behave as in
  the US layout: <kbd>Ctrl</kbd>+<kbd>[</kbd> is Esc, and so on.
- Left <kbd>Alt</kbd> stays a normal Alt key. Windows cannot turn it into an
  Option key, because Alt combinations are reserved for menus. As with every
  AltGr layout, <kbd>Ctrl</kbd>+<kbd>Alt</kbd> also produces the AltGr characters.
- **ANSI vs ISO keyboards.** The Mac <kbd>&#96;</kbd> key (`щ`) is the top-left key
  on ANSI (US-style) keyboards, which is where this layout puts it. ISO
  keyboards have an extra key next to left <kbd>Shift</kbd>, and it types `>` and
  `<`, like the Mac's <kbd>§</kbd> key.

[docs/sources.md](docs/sources.md) lists the data sources and explains each
decision, including the few places where Windows differs from macOS.

## Build from source

You need Windows 10 or 11 (x64 or ARM64) and Visual Studio 2022 or newer. The
free *Build Tools* are enough, with the **MSVC x64/x86** and **MSVC ARM64**
build tools and a **Windows SDK**.

```powershell
.\build.ps1 -Package              # out\bin\<arch>\kbdrumph.dll and out\kbdrumph-<version>.zip
.\tests\Test-Tables.ps1           # all architectures contain identical tables
.\tests\Test-Layout.ps1           # every key and modifier state matches macOS
.\tests\Test-Layout.ps1 -Mode Installed   # the same, asked from Windows (after installing)
```

| Path | What it is |
|---|---|
| [`layout/kbdrumph.klc`](layout/kbdrumph.klc) | The layout source, in Microsoft Keyboard Layout Creator 1.4 format. It opens in MSKLC. |
| [`tools/KbdLayout.psm1`](tools/KbdLayout.psm1) | Turns the `.klc` file into the C tables, resources and exports of a layout DLL, with the same tables MSKLC's own compiler produces. |
| [`build.ps1`](build.ps1) | Builds `arm64` (ARM64X, like Windows' own ARM64 layouts), `amd64`, `x86` and `wow64` DLLs with MSVC. |
| [`installer/`](installer) | `Install.ps1` / `Uninstall.ps1` and the double-click `.cmd` wrappers. |
| [`tests/`](tests) | Table comparison across architectures, plus key-by-key checks against [`macos-russian-qwerty.json`](tests/macos-russian-qwerty.json), Apple's layout transcribed per key and modifier state. |
| [`tools/kbddump/`](tools/kbddump) | A small tool that prints all tables of a layout DLL. |
| [`tools/New-LayoutChart.ps1`](tools/New-LayoutChart.ps1) | Draws `docs/layout.svg` from the `.klc` file. |

**Why not just MSKLC?** Microsoft Keyboard Layout Creator 1.4 cannot build
ARM64 DLLs, and the ones it builds for other platforms come from a 2005
toolchain. Here the `.klc` file stays the source and MSKLC can still edit it,
but the DLLs are built by a current MSVC the way Windows builds its own
layouts. They have no entry point, no C runtime and no imports, and every
table lives in one read-only `.data` section, which is the section the kernel
reads. The table test compiles the same file with MSKLC's `kbdutool` (pass
`-KbdUtool <path>`) and requires identical tables.

GitHub Actions runs on every push to `master`, every pull request and every
`v*` tag, on x64 and on native ARM64 Windows. It builds all architectures,
compares their tables, checks every key against macOS, installs the layout,
checks it again through `ToUnicodeEx`, uninstalls it, and publishes a release
for every `v*` tag. The MSKLC comparison does not run in CI, because MSKLC
cannot be redistributed. After changing `tools/KbdLayout.psm1`, install MSKLC
from Microsoft and run `tests\Test-Tables.ps1 -KbdUtool <path to kbdutool.exe>`
locally.

## History

This repository started in 2012 with MSKLC layouts for Boot Camp on a MacBook
Pro 13 (2011) and later a MacBook Pro Retina 15 (2013) under Windows 8. In 2025
an ARM64 workaround was added for a Surface Pro. Version 2.0 (2026) replaces
all of them with a single layout taken from Apple's data and built for every
architecture; the old files remain in the git history. See
[CHANGELOG.md](CHANGELOG.md).

## License

[Apache License 2.0](LICENSE). Copyright 2012–2026 Yuri Trukhin. Apple and macOS
are trademarks of Apple Inc. This project is not affiliated with Apple or
Microsoft.

---

## По-русски

Раскладка **«Русская – QWERTY»** из macOS (раньше она называлась
**«Русская – фонетическая»**) для Windows 10 и 11 на **ARM64**, **x64** и
**x86**. Она повторяет Mac полностью. Все буквы на тех же местах. Слой Option
доступен через правый <kbd>Alt</kbd> (<kbd>AltGr</kbd>): там `ё` (<kbd>AltGr</kbd>+<kbd>E</kbd>
или <kbd>AltGr</kbd>+<kbd>2</kbd>), `₽` (<kbd>AltGr</kbd>+<kbd>R</kbd>), украинские,
белорусские, сербские и македонские буквы, кавычки «ёлочки». Caps Lock
работает, как на Mac: включает весь слой Shift.

**Установка:** скачайте `kbdrumph-<версия>.zip` из раздела
[Releases](https://github.com/trukhinyuri/phonetic-ru-keyboard-windows8/releases/latest)
(или артефакт `package` последней
[сборки](https://github.com/trukhinyuri/phonetic-ru-keyboard-windows8/actions/workflows/build.yml)),
распакуйте его в папку на локальном диске, запустите `install.cmd` и
подтвердите запрос администратора. Переключение раскладок:
<kbd>Win</kbd>+<kbd>Пробел</kbd>. Удаление: `uninstall.cmd`. Старые версии 1.x
устанавливаются отдельно, как их удалить, описано в разделе
[Upgrading from 1.x](#upgrading-from-1x).
