Russian - QWERTY (Mac) keyboard layout for Windows
==================================================

Apple's macOS "Russian - QWERTY" (formerly "Russian - Phonetic") layout for
Windows 10 and 11 on ARM64, x64 and x86.

Install
  1. Extract this zip to a folder on a local disk.
  2. Double-click install.cmd and approve the administrator prompt.
  3. Switch layouts with Win+Space. If an application does not offer the
     layout yet, sign out and back in.

Uninstall
  Double-click uninstall.cmd.

Using it
  * The Mac Option key is AltGr (the right Alt key): AltGr+E or AltGr+2
    types the Cyrillic letter yo, AltGr+R the rouble sign, AltGr+9/0 and
    Shift+AltGr+9/0 the brackets [ ] { }.
  * Caps Lock works as on the Mac: it selects the whole Shift layer.
  * The top-left key types the Cyrillic letter shcha, as the Mac's ` key.

Upgrading from 1.x
  Older versions of this layout (RTrukhin.dll, RTruk16.dll or RuPhon.dll,
  shown as "Russian - Phonetic - Trukhin ..." or "Russian Phonetic
  (QWERTY)") are separate layouts. install.cmd warns when one is present.
  Remove it under Settings > Time & language > Language & region >
  Russian > Keyboards, then uninstall it from Settings > Apps > Installed
  apps if it is listed there.

Contents
  install.cmd, Install.ps1      installer
  uninstall.cmd, Uninstall.ps1  uninstaller
  arm64, amd64, x86, wow64      the layout DLLs (wow64 = for 32-bit apps)
  kbdrumph.klc                  layout source (Microsoft Keyboard Layout Creator)
  LICENSE, NOTICE               Apache License 2.0

The layout DLLs are not code-signed. If Smart App Control is turned on,
Windows may refuse to load them.

Project page, layout chart and source:
https://github.com/trukhinyuri/phonetic-ru-keyboard-windows8
