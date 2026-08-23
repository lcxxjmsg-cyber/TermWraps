#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
typedef int (__stdcall *FN)(const wchar_t*, wchar_t*, int, int);
static void* g_dll = NULL;
static void* g_data = NULL;
static BOOL CALLBACK cb(HMODULE h, LPCTSTR t, LPVOID p) {
    (void)h; (void)p;
    if (t && t[0] == 't' && t[1] == 'e' && t[2] == 'r' && t[3] == 'm') { g_data = (void*)h; }
    if (t && t[0] == 'd' && t[1] == 'b' && t[2] == 'g' && t[3] == 'h') { g_dll = (void*)h; }
    return TRUE;
}
void dump(void) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, GetCurrentProcessId());
    if (snap == INVALID_HANDLE_VALUE) return;
    MODULEENTRY32W me; me.dwSize = sizeof(me);
    if (Module32FirstW(snap, &me)) do {
        if (me.szModule[0] == L't' && me.szModule[1] == L'e' && me.szModule[2] == L'r' && me.szModule[3] == L'm')
            wprintf(L"TERMSRV-DATAFILE base=%p\n", me.modBaseAddr);
        if (me.szModule[0] == L'd' && me.szModule[1] == L'b' && me.szModule[2] == L'g' && me.szModule[3] == L'h')
            wprintf(L"DBGHELP %p %s\n", me.modBaseAddr, me.szExePath);
    } while (Module32NextW(snap, &me));
    CloseHandle(snap);
}
int wmain(int argc, wchar_t** argv) {
    int noSym = (argc > 1 && argv[1][0] == L'n');
    HMODULE h = LoadLibraryW(L"E:\\MyProject\\PSProject\\TermWrapWrapper\\src\\bin\\selfbuilt\\x64\\RDPWrapOffsetFinder.dll");
    if (!h) { printf("load fail %u\n", GetLastError()); return 1; }
    FN fn = (FN)GetProcAddress(h, noSym ? "FindRDPOffsetsNoSym" : "FindRDPOffsets");
    if (!fn) { printf("no export\n"); return 1; }
    wchar_t buf[131072];
    int hr = fn(L"C:\\WINDOWS\\System32\\termsrv.dll", buf, 131072, 0);
    printf("hr=%d\n", hr);
    dump();
    wprintf(L"%s", buf);
    return 0;
}
