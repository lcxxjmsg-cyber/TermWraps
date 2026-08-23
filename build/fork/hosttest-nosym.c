#include <windows.h>
#include <stdio.h>
typedef int (__stdcall *FN)(const wchar_t*, wchar_t*, int, int);
int wmain(void) {
    HMODULE h = LoadLibraryW(L"E:\\MyProject\\PSProject\\TermWrapWrapper\\src\\bin\\selfbuilt\\x64\\RDPWrapOffsetFinder.dll");
    if (!h) { printf("load fail %u\n", GetLastError()); return 1; }
    FN fn = (FN)GetProcAddress(h, "FindRDPOffsetsNoSym");
    if (!fn) { printf("no export\n"); return 1; }
    wchar_t buf[131072];
    int hr = fn(L"C:\\WINDOWS\\System32\\termsrv.dll", buf, 131072, 0);
    printf("hr=%d\n", hr);
    wprintf(L"%s", buf);
    return 0;
}
