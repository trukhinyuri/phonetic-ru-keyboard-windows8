/*
 * kbddump - prints every table of a keyboard layout DLL in a stable text form.
 *
 * Used by the test suite to prove that the ARM64, x64, x86 and WOW64 builds
 * contain identical tables, and that they match an MSKLC (kbdutool) build of
 * the same .klc file.
 *
 * Build it for the architecture of the DLL you want to inspect; for a WOW64
 * layout DLL build it as x86 with /DBUILD_WOW6432 so that kbd.h uses the
 * 64-bit table pointers that such DLLs contain.
 *
 * Usage: kbddump <layout.dll>
 */

#include <windows.h>
#include <kbd.h>
#include <stdio.h>
#include <wchar.h>

typedef PKBDTABLES (*KBDLAYERDESCRIPTOR)(VOID);

static void PrintString(const WCHAR *KBD_LONG_POINTER s)
{
    putchar('"');
    for (; s && *s; s++) {
        if (*s >= 0x20 && *s < 0x7f && *s != '"' && *s != '\\') {
            putchar((int)*s);
        } else {
            printf("\\u%04x", (unsigned)*s);
        }
    }
    putchar('"');
}

static void PrintKeyNames(const char *title, PVSC_LPWSTR names)
{
    printf("[%s]\n", title);
    for (; names && names->vsc; names++) {
        printf("%02x ", names->vsc);
        PrintString(names->pwsz);
        putchar('\n');
    }
}

/* Prints string <id> of every language it exists in (MSKLC's ids: 1000 =
 * layout display name, 1100 = language name, 1200 = locale name). */
static BOOL CALLBACK PrintStringLanguage(HMODULE module, LPCWSTR type, LPCWSTR name, WORD lang, LONG_PTR id)
{
    HRSRC info = FindResourceExW(module, type, name, lang);
    HGLOBAL data = info ? LoadResource(module, info) : NULL;
    const WCHAR *p = data ? (const WCHAR *)LockResource(data) : NULL;
    UINT i;

    if (!p) {
        return TRUE;
    }
    /* A string block holds 16 counted strings. */
    for (i = 0; i < (UINT)(id % 16); i++) {
        p += 1 + *p;
    }
    printf("string %u lang %04x \"", (UINT)id, lang);
    for (i = 1; i <= *p; i++) {
        if (p[i] >= 0x20 && p[i] < 0x7f && p[i] != '"' && p[i] != '\\') {
            putchar((int)p[i]);
        } else {
            printf("\\u%04x", (unsigned)p[i]);
        }
    }
    printf("\"\n");
    return TRUE;
}

static void PrintResources(HMODULE module)
{
    static const UINT ids[] = { 1000, 1100, 1200 };
    HRSRC info;
    UINT i;

    printf("[resources]\n");
    for (i = 0; i < sizeof(ids) / sizeof(ids[0]); i++) {
        EnumResourceLanguagesW(module, RT_STRING, MAKEINTRESOURCEW(ids[i] / 16 + 1), PrintStringLanguage, (LONG_PTR)ids[i]);
    }
    info = FindResourceW(module, MAKEINTRESOURCEW(1), RT_VERSION);
    if (info) {
        const BYTE *data = (const BYTE *)LockResource(LoadResource(module, info));
        DWORD size = SizeofResource(module, info);
        DWORD off;
        for (off = 0; data && off + sizeof(VS_FIXEDFILEINFO) <= size; off += 4) {
            const VS_FIXEDFILEINFO *fixed = (const VS_FIXEDFILEINFO *)(data + off);
            if (fixed->dwSignature == 0xFEEF04BD) {
                printf("version type %lu subtype %lu os %08lx\n", fixed->dwFileType, fixed->dwFileSubtype, fixed->dwFileOS);
                break;
            }
        }
    }
}

int wmain(int argc, wchar_t **argv)
{
    HMODULE module;
    KBDLAYERDESCRIPTOR descriptor;
    PKBDTABLES t;
    PVK_TO_WCHAR_TABLE table;
    PMODIFIERS mods;
    UINT i;

    if (argc != 2) {
        fwprintf(stderr, L"usage: %ls <layout.dll>\n", argv[0]);
        return 2;
    }
    module = LoadLibraryExW(argv[1], NULL, 0);
    if (!module) {
        fwprintf(stderr, L"cannot load %ls (error %lu)\n", argv[1], GetLastError());
        return 1;
    }
    descriptor = (KBDLAYERDESCRIPTOR)GetProcAddress(module, "KbdLayerDescriptor");
    if (!descriptor) {
        fwprintf(stderr, L"%ls does not export KbdLayerDescriptor\n", argv[1]);
        return 1;
    }
    t = descriptor();

    printf("[layout]\nflags %04x version %u\n", LOWORD(t->fLocaleFlags), HIWORD(t->fLocaleFlags));

    mods = t->pCharModifiers;
    printf("[modifiers]\n");
    for (i = 0; mods->pVkToBit[i].Vk; i++) {
        printf("bit %02x %02x\n", mods->pVkToBit[i].Vk, mods->pVkToBit[i].ModBits);
    }
    printf("maxbits %u\n", mods->wMaxModBits);
    for (i = 0; i <= mods->wMaxModBits; i++) {
        printf("mod %u -> %u\n", i, mods->ModNumber[i]);
    }

    printf("[scancodes]\n");
    for (i = 0; i < t->bMaxVSCtoVK; i++) {
        printf("%02x %04x\n", i, t->pusVSCtoVK[i]);
    }
    printf("[scancodes-e0]\n");
    for (i = 0; t->pVSCtoVK_E0[i].Vsc; i++) {
        printf("%02x %04x\n", t->pVSCtoVK_E0[i].Vsc, t->pVSCtoVK_E0[i].Vk);
    }
    printf("[scancodes-e1]\n");
    for (i = 0; t->pVSCtoVK_E1[i].Vsc; i++) {
        printf("%02x %04x\n", t->pVSCtoVK_E1[i].Vsc, t->pVSCtoVK_E1[i].Vk);
    }

    for (table = t->pVkToWcharTable; table->pVkToWchars; table++) {
        BYTE *KBD_LONG_POINTER row = (BYTE *KBD_LONG_POINTER)table->pVkToWchars;
        printf("[chars %u]\n", table->nModifications);
        for (;; row += table->cbSize) {
            PVK_TO_WCHARS1 entry = (PVK_TO_WCHARS1)row;
            UINT c;
            if (entry->VirtualKey == 0) {
                break;
            }
            printf("%02x %02x", entry->VirtualKey, entry->Attributes);
            for (c = 0; c < table->nModifications; c++) {
                printf(" %04x", entry->wch[c]);
            }
            putchar('\n');
        }
    }

    printf("[deadkeys]\n");
    if (t->pDeadKey) {
        PDEADKEY dk;
        for (dk = t->pDeadKey; dk->dwBoth; dk++) {
            printf("%04x %04x -> %04x flags %04x\n", HIWORD(dk->dwBoth), LOWORD(dk->dwBoth), dk->wchComposed, dk->uFlags);
        }
    }

    printf("[ligatures]\n");
    if (t->pLigature) {
        BYTE *KBD_LONG_POINTER row = (BYTE *KBD_LONG_POINTER)t->pLigature;
        printf("max %u\n", t->nLgMax);
        for (;; row += t->cbLgEntry) {
            PLIGATURE1 lig = (PLIGATURE1)row;
            UINT c;
            if (lig->VirtualKey == 0) {
                break;
            }
            printf("%02x %u", lig->VirtualKey, lig->ModificationNumber);
            for (c = 0; c < t->nLgMax; c++) {
                printf(" %04x", lig->wch[c]);
            }
            putchar('\n');
        }
    }

    PrintKeyNames("keynames", t->pKeyNames);
    PrintKeyNames("keynames-ext", t->pKeyNamesExt);
    printf("[keynames-dead]\n");
    if (t->pKeyNamesDead) {
        WCHAR *KBD_LONG_POINTER *KBD_LONG_POINTER name;
        for (name = t->pKeyNamesDead; *name; name++) {
            PrintString(*name);
            putchar('\n');
        }
    }
    PrintResources(module);
    return 0;
}
