#include <windows.h>

extern "C" const wchar_t* g_termsrv_override = nullptr;

extern "C" {
    UINT_PTR __security_cookie = 0x2B992DDFA232;
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
