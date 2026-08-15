param(
    [string]$SrcRoot = (Join-Path $PSScriptRoot 'src')
)

$ErrorActionPreference = 'Stop'

$files = @(
    (Join-Path $SrcRoot 'offsetfinder\RDPWrapOffsetFinder\RDPWrapOffsetFinder.cpp'),
    (Join-Path $SrcRoot 'offsetfinder\RDPWrapOffsetFinder_nosym\RDPWrapOffsetFinder_nosym.cpp'),
    (Join-Path $SrcRoot 'offsetfinder\RDPWrapOffsetFinder\RDPWrapOffsetFinder.vcxproj'),
    (Join-Path $SrcRoot 'termwrap\TermWrap\TermWrap.vcxproj'),
    (Join-Path $SrcRoot 'termwrap\UmWrap\UmWrap.vcxproj'),
    (Join-Path $SrcRoot 'termwrap\EndpWrap\EndpWrap.vcxproj')
)

$overrideDecl = 'extern "C" const wchar_t* g_termsrv_override;'
$overrideUse = '    if (g_termsrv_override) lstrcpyW(szTermsrv, g_termsrv_override);'

foreach ($f in $files) {
    if (-not (Test-Path $f)) { throw "source not found: $f" }
    $c = Get-Content $f -Raw
    $c = $c -replace "`r?`n", "`r`n"
    $orig = $c

    if ($c -notmatch [regex]::Escape($overrideDecl)) {
        $c = $c.Replace('#include <Zydis/Zydis.h>', "#include <Zydis/Zydis.h>`r`n`r`n$overrideDecl")
    }
    $misplaced = "$overrideUse`r`n    if (argc >= 2) lstrcpyW(szTermsrv, argv[1]);"
    $c = $c.Replace($misplaced, '    if (argc >= 2) lstrcpyW(szTermsrv, argv[1]);')
    $afterElse = 'else lstrcpyW(szTermsrv + GetSystemDirectoryW(szTermsrv, sizeof(szTermsrv) / sizeof(WCHAR)), L"\\termsrv.dll");'
    if ($c -notmatch 'g_termsrv_override\) lstrcpyW') {
        $c = $c.Replace($afterElse, $afterElse + "`r`n    $overrideUse")
    }
    $exitCount = ([regex]::Matches($c, 'ExitProcess\(')).Count
    if ($exitCount -gt 0) {
        $c = [regex]::Replace($c, 'ExitProcess\(', 'return (')
    }

    $voidFixes = @(
        @('if (!n) return (-7);', 'if (!n) return;'),
        @('if (!h->data) return (-7);', 'if (!h->data) return;')
    )
    foreach ($fix in $voidFixes) {
        $c = $c.Replace($fix[0], $fix[1])
    }

    if ($f -match 'RDPWrapOffsetFinder\.cpp$' -and $c.Contains('symbol.Address - symbol.ModBase')) {
        $c = $c.Replace('symbol.Address - symbol.ModBase', 'symbol.Address - ImageBase')
    }

    if ($f -match 'RDPWrapOffsetFinder\.vcxproj$') {
        $c = $c.Replace('$(SolutionDir)\zydis\msvc\bin\ReleaseX86\Zydis.lib', '$(ProjectDir)..\..\zydis\msvc\bin\ReleaseX86\Zydis.lib;$(ProjectDir)..\..\zydis\msvc\bin\ReleaseX86\Zycore.lib')
        $c = $c.Replace('$(SolutionDir)\zydis\msvc\bin\ReleaseX64\Zydis.lib', '$(ProjectDir)..\..\zydis\msvc\bin\ReleaseX64\Zydis.lib;$(ProjectDir)..\..\zydis\msvc\bin\ReleaseX64\Zycore.lib')
        $c = $c.Replace('$(SolutionDir)\zydis\include', '$(ProjectDir)..\..\zydis\include')
        $c = $c.Replace('$(SolutionDir)\zydis\dependencies\zycore\include', '$(ProjectDir)..\..\zydis\dependencies\zycore\include')
        $c = $c.Replace('$(SolutionDir)\zydis\msvc', '$(ProjectDir)..\..\zydis\msvc')
        $c = $c.Replace('_HAS_EXCEPTIONS=0;_NO_CRT_STDIO_INLINE;MEMSET_DIRECT;WIN32;NDEBUG;_CONSOLE;%(PreprocessorDefinitions)', '_HAS_EXCEPTIONS=0;_NO_CRT_STDIO_INLINE;WIN32;NDEBUG;_CONSOLE;ZYDIS_STATIC_BUILD;ZYCORE_STATIC_BUILD;%(PreprocessorDefinitions)')
        $c = $c.Replace('_HAS_EXCEPTIONS=0;_NO_CRT_STDIO_INLINE;MEMSET_DIRECT;NDEBUG;_CONSOLE;%(PreprocessorDefinitions)', '_HAS_EXCEPTIONS=0;_NO_CRT_STDIO_INLINE;NDEBUG;_CONSOLE;ZYDIS_STATIC_BUILD;ZYCORE_STATIC_BUILD;%(PreprocessorDefinitions)')
        $c = $c.Replace('<PropertyGroup Condition="''$(Configuration)|$(Platform)''==''Release|Win32''" Label="Configuration">', '<PropertyGroup Condition="''$(Configuration)|$(Platform)''==''Release|Win32''" Label="Configuration">' + "`r`n" + '    <OutDir>$(ProjectDir)..\..\..\out\sym-x86\</OutDir>' + "`r`n" + '    <IntDir>$(ProjectDir)..\..\..\obj\sym-x86\</IntDir>')
        $c = $c.Replace('<PropertyGroup Condition="''$(Configuration)|$(Platform)''==''Release|x64''" Label="Configuration">', '<PropertyGroup Condition="''$(Configuration)|$(Platform)''==''Release|x64''" Label="Configuration">' + "`r`n" + '    <OutDir>$(ProjectDir)..\..\..\out\sym-x64\</OutDir>' + "`r`n" + '    <IntDir>$(ProjectDir)..\..\..\obj\sym-x64\</IntDir>')
        $c = $c.Replace('Include="msvcrt.def"', 'Include="..\..\..\fork\msvcrt.def"')
        if (-not $c.Contains('fork\exeglobals.cpp')) {
            $c = $c.Replace('<ClCompile Include="RDPWrapOffsetFinder.cpp" />', '<ClCompile Include="RDPWrapOffsetFinder.cpp" />' + "`r`n" + '    <ClCompile Include="..\..\..\fork\exeglobals.cpp" />')
        }
    }

    if ($f -match 'termwrap\\.*\\(TermWrap|UmWrap|EndpWrap)\.vcxproj$') {
        $c = $c.Replace('$(SolutionDir)\zydis\msvc\bin\ReleaseX64\Zydis.lib', '$(ProjectDir)..\..\zydis\msvc\bin\ReleaseX64\Zydis.lib;$(ProjectDir)..\..\zydis\msvc\bin\ReleaseX64\Zycore.lib')
        $c = $c.Replace('$(SolutionDir)\zydis\msvc\bin\ReleaseX86\Zydis.lib', '$(ProjectDir)..\..\zydis\msvc\bin\ReleaseX86\Zydis.lib;$(ProjectDir)..\..\zydis\msvc\bin\ReleaseX86\Zycore.lib')
        $c = $c.Replace('$(SolutionDir)\zydis\include', '$(ProjectDir)..\..\zydis\include')
        $c = $c.Replace('$(SolutionDir)\zydis\dependencies\zycore\include', '$(ProjectDir)..\..\zydis\dependencies\zycore\include')
        $c = $c.Replace('$(SolutionDir)\zydis\msvc', '$(ProjectDir)..\..\zydis\msvc')
        $c = $c.Replace('$(SolutionDir)TermWrap\x64\Release\msvcrt.lib', '$(ProjectDir)..\TermWrap\x64\Release\msvcrt.lib')
        $c = $c.Replace('NDEBUG;_CONSOLE;%(PreprocessorDefinitions)', 'NDEBUG;_CONSOLE;ZYDIS_STATIC_BUILD;ZYCORE_STATIC_BUILD;%(PreprocessorDefinitions)')
        if (-not $c.Contains('fork\termwrap-globals.cpp')) {
            $c = $c.Replace('<ClCompile Include="DllMain.cpp" />', '<ClCompile Include="DllMain.cpp" />' + "`r`n" + '    <ClCompile Include="..\..\..\fork\termwrap-globals.cpp" />')
        }
    }

    if ($c -ne $orig) {
        Set-Content -Path $f -Value $c -Encoding UTF8 -NoNewline
        Write-Host "  patched: $f (ExitProcess->return x$exitCount)"
    } else {
        Write-Host "  no changes: $f"
    }
}
Write-Host 'patch-src done'



