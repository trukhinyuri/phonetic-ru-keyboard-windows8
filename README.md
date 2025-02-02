#Phonetic Russian Qwerty Keyboard for Windows (including ARM64)
Copyright 2012-2025 Yuri Trukhin

Phonetic russian keyboard for Windows 7, Windows 8 and Windows 8.1.
Setup files for Macbook Pro Retina 15 2013: "MacBook Pro Retina 15 2013/Setup"
Setup files for Macbook Pro 13 2011: "MacBook Pro 13 2011/Setup"


###Current status
Fab 01, 2025: Added durty workaround for Windows ARM64 (ONLY FOR ARM64, tested on Surface 11 Pro with Qualcomm Snapdragon X Elite).
For adding keyboard, use
./WindowsARM64Workaround/build/Release/kli.exe

To my great regret, Microsoft Keyboard Layout Creator 1.4 does not support ARM64, and Windows requires that the layout be installed via a binary file (utter madness!). Microsoft, please fix this—at the very least, add ARM64 support to MKLC, and even better, simply allow keyboard layouts to be described in text form, as is done in Linux.

Thanks https://github.com/davidebeatrici/kli , https://github.com/benhoyt/inih .

Sep 26, 2013: Added support for Macbook Pro Retina 15 2013, support for Windows 8.1 Release
