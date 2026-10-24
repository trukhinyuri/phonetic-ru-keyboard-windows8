# Where the layout comes from

The goal is to type on Windows exactly as with macOS's **Russian – QWERTY**
layout (`com.apple.keylayout.Russian-Phonetic`, shown as *Russian – Phonetic*
until it was renamed in recent macOS releases; the identifier did not change).
This page lists the data the layout was taken from and every decision made
where Windows and macOS differ.

## Apple's data

| Source | What it gives |
|---|---|
| Unicode CLDR export of Apple's layouts, [`keyboards/osx/ru-t-k0-osx-qwerty.xml`](https://raw.githubusercontent.com/unicode-org/cldr/release-43/keyboards/osx/ru-t-k0-osx-qwerty.xml) (`platform="10.9"`, present in CLDR releases 25–43 and removed in 44) | Every key in every modifier state, plus the modifier rules ("keyMap" selection) |
| The same file for Mac OS X 10.4 ([CLDR release-24](https://raw.githubusercontent.com/unicode-org/cldr/release-24/keyboards/osx/ru-t-k0-osx-qwerty.xml)) | Shows the only difference between 10.4 and 10.9: Option+<kbd>-</kbd> was `–` and is now `-` |
| `.keylayout` dumps of the system layout made with Apple's `kluchrtoxml` (via Ukelele "New from current input source"), dated 2015–2025 | Confirm that the 10.9 data is still current, with one change: Option+<kbd>R</kbd> types `₽` (it was `®`, which remains on Shift+Option+<kbd>R</kbd>). Apple added the rouble sign in 2014–2015, when MacBooks started shipping with `₽` printed on the Р key. |

Each value that the sources disagreed on was checked again by two independent
reviews against the raw data: Option+<kbd>R</kbd>, Option and Shift+Option+<kbd>-</kbd>,
Option+<kbd>3</kbd>/<kbd>4</kbd>, the unshifted <kbd>'</kbd> key and the keypad
decimal key. [`tests/macos-russian-qwerty.json`](../tests/macos-russian-qwerty.json)
records the resulting value for each key and state, and the tests compare the
built layout against it.

Third-party sources were consulted only for cross-checking and are **not**
used: the xkeyboard-config `ru(phonetic_mac)` variant (its levels 3/4 add `№`,
`₽` and `_` where Apple has other characters), and other Windows ports, most of
which leave out the Option layer.

## Modifier behaviour

Apple's modifier rules for this layout differ from most Mac layouts:

- **Caps Lock** selects the *Shift* layer for every key, including digits and
  punctuation (Caps Lock + <kbd>1</kbd> = `!`), and Caps Lock + Shift still
  gives the Shift layer. Windows' usual Caps Lock only affects letters and is
  cancelled by Shift, so every key uses an `SGCap` row (a separate Caps Lock
  row) to reproduce the Mac exactly.
- **Caps Lock + Option** gives the Option layer unchanged (no capitals), and
  **Caps Lock + Shift + Option** the Shift+Option layer.
- There are **no dead keys**: every Option character is typed directly.

## Mapping to a PC keyboard

| Mac | Windows |
|---|---|
| Option | <kbd>AltGr</kbd> (right Alt). Windows reserves left Alt for menus, so it cannot be an Option key. As in every AltGr layout, <kbd>Ctrl</kbd>+<kbd>Alt</kbd> types the AltGr characters too. |
| Command | <kbd>Ctrl</kbd> shortcuts keep working, because the keys keep their Latin virtual-key codes. |
| <kbd>&#96;</kbd> key (kVK 50: `` щ Щ † ` ``) | Scancode `0x29`, the top-left key of every PC keyboard. |
| <kbd>§</kbd> key (kVK 10, ISO Macs only: `> <`) | Scancode `0x56`, the extra ISO key next to left Shift. |

Apple ISO keyboards put kVK 10 at the top left and kVK 50 next to left Shift,
while ANSI Macs have kVK 50 at the top left and no kVK 10 at all. The layout
follows the ANSI arrangement. It is exact for US-style keyboards, keeps `щ`
on a key that exists on every PC keyboard, and still gives ISO keyboards their
`> <` key. Chromium, CLDR and xkeyboard-config use the same correspondence
(Backquote ↔ `0x29`, IntlBackslash ↔ `0x56`).

## What Windows adds

macOS's Control layer only matters for shortcuts, so the Control columns
follow Microsoft's US and Russian layouts instead. They give the usual
terminal control characters:

| Keys | Character |
|---|---|
| <kbd>Ctrl</kbd>+<kbd>[</kbd> | Esc (U+001B) |
| <kbd>Ctrl</kbd>+<kbd>]</kbd> | U+001D |
| <kbd>Ctrl</kbd>+<kbd>\\</kbd> and <kbd>Ctrl</kbd> + the ISO key | U+001C |
| <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>2</kbd> | NUL (U+0000) |
| <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>6</kbd> | U+001E |
| <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>-</kbd> | U+001F |
| <kbd>Ctrl</kbd>+<kbd>Space</kbd> | Space |

<kbd>Ctrl</kbd>+letter control characters (<kbd>Ctrl</kbd>+<kbd>C</kbd> = U+0003, and so on)
come from Windows itself, as with every layout.

## Not reproduced

- The separate Command layers (Latin QWERTY with <kbd>Cmd</kbd>). They are
  shortcuts, which Windows handles through virtual-key codes.
- A quirk in the modifier rules: macOS maps Caps Lock + *right* Option alone
  to the base layer. In practice Option is a single modifier, and Windows has
  only one AltGr, so Caps Lock + AltGr always gives the Option layer.
- Keypad keys other than the decimal key, and function or editing keys. These
  are the same in every layout.
