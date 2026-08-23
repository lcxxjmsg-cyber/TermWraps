#include <windows.h>
#include <stdio.h>
#include <io.h>
#include <fcntl.h>

extern "C" const wchar_t* g_termsrv_override_sym = nullptr;
extern "C" const wchar_t* g_termsrv_override_nosym = nullptr;

extern "C" {
    UINT_PTR __security_cookie = 0x2B992DDFA232;
#if defined(_M_IX86)
    extern const IMAGE_LOAD_CONFIG_DIRECTORY32 _load_config_used = { sizeof(IMAGE_LOAD_CONFIG_DIRECTORY32), 0 };
#else
    extern const IMAGE_LOAD_CONFIG_DIRECTORY64 _load_config_used = { sizeof(IMAGE_LOAD_CONFIG_DIRECTORY64), 0 };
#endif
#if defined(_M_IX86)
    void __fastcall __security_check_cookie(UINT_PTR cookie)
#else
    void __cdecl __security_check_cookie(UINT_PTR cookie)
#endif
    {
        if (cookie != __security_cookie) __fastfail(0x43);
    }
#if defined(_M_X64)
    void __fastcall __GSHandlerCheck(void) { }
#endif
#if defined(_M_IX86)
    __declspec(naked) void __cdecl myallmul(void)
    {
        __asm {
            mov eax, DWORD PTR [esp+4]
            mov edx, DWORD PTR [esp+8]
            imul edx, DWORD PTR [esp+12]
            mov ecx, DWORD PTR [esp+8]
            imul ecx, DWORD PTR [esp+4]
            add edx, ecx
            mul DWORD PTR [esp+12]
            ret 16
        }
    }
#pragma comment(linker, "/alternatename:__allmul=_myallmul")
#endif
}

int RunOffsetFinderSym(void);
int RunOffsetFinderNoSym(void);

static int RunAndCapture(int (*fn)(void), const wchar_t* path, wchar_t* output, int bufSize, const wchar_t** overrideSlot)
{
    if (!path || !output || bufSize <= 0) return -9;
    int fds[2];
    if (_pipe(fds, 131072, _O_BINARY) != 0) return -10;
    int saved = _dup(1);
    _dup2(fds[1], 1);
    *overrideSlot = path;
    HMODULE hProbe = LoadLibraryExW(path, NULL, LOAD_LIBRARY_AS_DATAFILE);
    DWORD probeErr = hProbe ? 0 : GetLastError();
    if (hProbe) FreeLibrary(hProbe);
    int hr = fn();
    DWORD dbgLastErr = GetLastError();
    fflush(NULL);
    _dup2(saved, 1);
    _close(saved);
    _close(fds[1]);
    *overrideSlot = nullptr;
    char* buf = (char*)malloc(131072);
    if (!buf) { _close(fds[0]); output[0] = 0; return hr; }
    int n = _read(fds[0], buf, 131071);
    _close(fds[0]);
    if (n <= 0) n = 0;
    buf[n] = 0;
    int w = MultiByteToWideChar(CP_UTF8, 0, buf, n, output, bufSize - 1);
    free(buf);
    if (w < 0) w = 0;
    if (w > bufSize - 1) w = bufSize - 1;
    if (w <= 0) { output[0] = 0; }
    else { output[w] = 0; }
    if (hr < 0) {
        int dbg = wsprintfW(output + w, L" [DBG hr=%d lastErr=%u probeErr=%u path=%s]", hr, dbgLastErr, probeErr, path);
        if (w + dbg < bufSize - 1) output[w + dbg] = 0;
    }
    return hr;
}

extern "C" __declspec(dllexport) int __stdcall FindRDPOffsets(const wchar_t* path, wchar_t* output, int bufSize, int flags)
{
    (void)flags;
    return RunAndCapture(RunOffsetFinderSym, path, output, bufSize, &g_termsrv_override_sym);
}

extern "C" __declspec(dllexport) int __stdcall FindRDPOffsetsNoSym(const wchar_t* path, wchar_t* output, int bufSize, int flags)
{
    (void)flags;
    return RunAndCapture(RunOffsetFinderNoSym, path, output, bufSize, &g_termsrv_override_nosym);
}

BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD fdwReason, LPVOID lpvReserved)
{
    (void)lpvReserved;
    if (fdwReason == DLL_PROCESS_ATTACH) {
        WCHAR modPath[MAX_PATH + 1];
        DWORD n = GetModuleFileNameW(hinstDLL, modPath, MAX_PATH);
        if (n > 0) {
            WCHAR* slash = modPath;
            for (WCHAR* p = modPath; *p; p++) { if (*p == L'\\') slash = p; }
            *(slash + 1) = 0;
            WCHAR sub[MAX_PATH + 1];
            lstrcpyW(sub, modPath); lstrcatW(sub, L"dbghelp.dll");
            LoadLibraryExW(sub, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
            lstrcpyW(sub, modPath); lstrcatW(sub, L"symsrv.dll");
            LoadLibraryExW(sub, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
        }
    }
    return TRUE;
}
