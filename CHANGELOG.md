# Changelog

## 2.0.0 – 2026-10-25

A rewrite. One layout, *Russian - QWERTY (Mac)* (`kbdrumph.dll`), replaces all
the earlier per-MacBook layouts.

### Layout

- Every key and modifier state now matches Apple's macOS *Russian – QWERTY*
  (*Russian – Phonetic*) data. `h` is `ч`, `x` is `х`, `v` is `в`, `[` is `ю`,
  `]` is `ж`, `\` is `э`, the <kbd>&#96;</kbd> key is `щ`, `-` and `=` are `ь`
  and `ъ`, and `'` types `'` again.
- The full Mac Option layer is on AltGr and Shift+AltGr. It includes `ё Ё`
  (AltGr+E or AltGr+2), `₽`, Ukrainian, Belarusian, Serbian and Macedonian
  letters, `« » „ “ ” ‘ ’`, `[ ] { } \`, and a no-break space. `ё` is typed
  directly again: after the dead keys were removed in July 2026 it could not
  be typed at all, and before that it needed the AltGr+<kbd>&#96;</kbd> dead key.
- Caps Lock behaves as on the Mac: it selects the whole Shift layer, and Shift
  does not undo it.
- The ISO key next to left Shift types `> <`, like the Mac's § key.
- Fixed: the Latin `x` on the Х key in the Retina 15 layout; Caps Lock did not
  capitalise `ь ъ э щ`; leftover dead-key names; Ctrl+[ and Ctrl+] did not give
  Esc and U+001D.

### Platforms and installation

- Native DLLs for ARM64 (an ARM64X image, as Windows' own ARM64 layouts are),
  x64 and x86, plus the WOW64 DLL that 32-bit applications on 64-bit Windows
  need. These replace the 2025 ARM64 workaround, which used a third-party
  layout and a DLL linked to the C runtime.
- A new PowerShell installer with double-click `.cmd` wrappers. It installs and
  upgrades in place, and leaves other languages and keyboards untouched. There
  is a matching uninstaller. MSKLC's MSI installers cannot target ARM64.
- 2.0 installs next to the 1.x layouts rather than replacing them, because
  those use other DLL names. The installer warns when one is present; see
  [Upgrading from 1.x](README.md#upgrading-from-1x).

### Project

- The `.klc` source (MSKLC 1.4 format) is compiled by a current MSVC through
  `build.ps1`, and produces the same tables as MSKLC's own compiler.
- New tests check that all architectures have identical tables and that every
  key and modifier state matches macOS, both from the tables and through
  Windows' `ToUnicodeEx`. GitHub Actions runs them on x64 and ARM64 runners. A
  local check (`Test-Tables.ps1 -KbdUtool`) also requires the tables to match
  an MSKLC build.
- Removed from the repository:
  - the vendored copy of Microsoft Keyboard Layout Creator, whose licence does
    not allow redistribution (it remains in the history of the 1.x commits);
  - committed build output;
  - a broken submodule;
  - a file whose name is invalid on Windows (`...:Zone.Identifier`), which made
    plain `git clone` fail;
  - a third-party layout that was included without attribution;
  - the obsolete per-MacBook folders, with their Itanium and Windows 8 MSIs.
- Added the Apache-2.0 `LICENSE` (the README carried this licence until 2025),
  `NOTICE`, `.gitattributes` (`.klc` files are stored as UTF-8 so diffs work),
  `.gitignore`, `.editorconfig` and `.mailmap`.

## 1.x – 2012–2026

- 2012-10-26: First MSKLC phonetic layout.
- 2013-09-26: Layouts and MSKLC installers for MacBook Pro 13 (2011) and
  MacBook Pro Retina 15 (2013) under Boot Camp, for Windows 8.1.
- 2025-02-02: ARM64 workaround: a DLL built by hand plus the third-party
  installer `kli`.
- 2026-07-02: Dead keys removed and a MacBook Pro 16 variant added (x64 and
  WOW64 DLLs only).
