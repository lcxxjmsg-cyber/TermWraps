# TermWrapWrapper

自维护 RDP 多会话方案（TermWrap 独立维护分支）。

> **编码约定**：本仓库所有 `.ps1` 必须 UTF-8 带 BOM（PS 5.1 按 ANSI 读无 BOM 文件，
> 中文的 GBK 尾字节可能被误判为 `{`/`"` 等字符导致解析错乱）。新增文件后跑一次：
> `powershell -Command "Get-ChildItem -Recurse -Filter *.ps1 | % { $b=[IO.File]::ReadAllBytes($_.FullName); if($b[0]-ne239){$t=[IO.File]::ReadAllText($_.FullName);[IO.File]::WriteAllText($_.FullName,$t,(New-Object Text.UTF8Encoding $true))} }"`

## 核心机制

- **符号模式自动定位**：`RDPWrapOffsetFinder`（v1.0 EXE 形态）从微软符号服务器获取当前构建的 `termsrv.dll` PDB，按符号名定位 4 个补丁点并反汇编算出内部偏移——**任何发布 PDB 的 GA 构建都能在 1 分钟内生成完整 INI 段**，无需等社区。
- **社区只作对拍基准**：生成结果与社区 INI（sebaxakerhtc 等）逐键比对，判定 PASS/WARN/FAIL。
- 失效面收敛为：无 PDB（预览版/离线）+ 结构性代码变更（需上游 v1.0 后的新模式，历史上 ~6 个月一次）。

## 现状（2026-08-15）

本机 `termsrv.dll 10.0.26100.8328` 实测 **PASS**：符号/无符号双模式生成一致，且与 sebaxakerhtc 社区段完全一致。

## 用法

```powershell
.\tools\offset-test.ps1 -Store <符号缓存目录>          # 默认 Sym+NoSym 双模式
.\tools\offset-test.ps1 -Mode Sym                      # 仅符号模式
.\tools\offset-test.ps1 -Json -OutFile result.json     # 机器可读
```

- `-Store`：符号缓存目录（自动创建、自动经 symsrv 填充 PDB；缺省时直连 msdl）。
- 代理：自动探测系统代理并注入 `_NT_SYMBOL_PROXY`（注意 symsrv 不接受尾斜杠，脚本已处理）；`-Proxy <url>` 手动指定，`-Proxy none` 强制直连。
- `-IniDir`：社区 INI 缓存目录（默认 `%TEMP%\rdp-compat-cache`，来自 rdp-compat.ps1 的拉取），用于对拍。

## 关键调研结论

1. **OffsetFinder 官方发布只有 EXE**；官方 v1.0 不含 28000.2307 修复——我们的自建产物（master 源码）比官方新。
2. **旧 DLL 不可用**：早期 pin 的 `RDPWrapOffsetFinder_x64.dll` 在 26100 构建上崩溃；已由自建 DLL 取代（rdpwarps.ps1 同步更新）。
3. **WinHTTP 不吃系统代理**：符号下载需 `_NT_SYMBOL_PROXY`（仅符号模式需要；NoSym 离线无需）。
4. 生成结果与社区一致时即证明：**自维护管道可产出与志愿者手工逆向等价的 PatchCodes**。

## 自建管线（build/）

`.\build\build.ps1` 一键自建（DLL x64/x86 + 源码级补丁）：

- 固定 pin 三份源码：OffsetFinder master @ 60fbe8de（**比官方 v1.0 新**）、zydis、zycore，SHA256 校验 + 扁平化解压；
- fork 层（`build/fork/`）：`dllmain.cpp`（DLL 导出 + stdout 捕获 + 路径注入 + GS 符号自供）、`exeglobals.cpp`（EXE 符号自供 + x86 `__allmul`）、`msvcrt.def`（无 CRT 链接）、`patch-src.ps1`（补丁链：ExitProcess→return、override 注入、ImageBase 修正、MEMSET_DIRECT 剔除、EXE 工程静态化）；
- 产物：`src\bin\offsetfinder\`（DLL + 清单）与 `build\sym-tools\`（研究工具）。
- `build\update-rdpwarp.ps1`：查 master → 更新 pin → 重建 → 部署到 RDPWarpper + 同步哈希。

**验证结论（26100.8328）**：DLL **NoSym 模式全量正确**（离线、与社区逐键一致，rdpwarps.ps1 与全部工具的主路径）；DLL/自建 EXE 的 Sym 模式受宿主 dbghelp 上下文影响（成员符号不稳/挂起——已记录为已知限制）。**符号研究用官方 v1.0 EXE**（`build\sym-tools\`，需 Zydis.dll 同目录 + 网络符号库）。

## 目录结构

```
├─ termwrap.ps1 / termwrap.cmd   # 入口（交互菜单 / -Install / -Uninstall / -Help）
├─ src\
│  ├─ core\                  # Core.I18n / Common / Shadow / Policy / Redirection / Health / Deploy
│  ├─ ui\Menu.ps1            # 主菜单（TermWrap 状态头 + U/D 新菜单）
│  └─ bin\
│     ├─ termwrap\           # TermWrap v0.6 DLL 集（部署用，含清单）
│     ├─ offsetfinder\       # 自建 OffsetFinder DLL x64/x86（离线 NoSym，含清单）
│     └─ symbols\            # 符号缓存（gitignore，不入仓）
├─ tools\
│  ├─ offset-test.ps1        # 测试台：DLL NoSym + 社区对拍（离线）
│  └─ ini-gen.ps1            # 生成器：DLL 离线生成 + 合入 rdpwrap.ini
├─ build\
│  ├─ build.ps1 / update-rdpwarp.ps1 / patch-src.ps1
│  ├─ fork\                  # 我们的 fork 层（dllmain/exeglobals/msvcrt.def/vcxproj/hosttest）
│  ├─ sym-tools\             # 符号研究工具（官方 v1.0 EXE + dbghelp/symsrv/Zydis，gitignore）
│  └─ src\                   # 上游源码（gitignore，可重建）
└─ docs\                     # termwrap-deployment-notes / self-patch-workflow / server-role-gate-design
```
```

## 下一阶段

1. 生成器：测试台输出 → 合并进 `rdpwrap.ini`（对齐 llccd autoupdate.bat 语义：替换段→停服务→换文件→起服务）。
2. 看门狗：termsrv 版本变化检测 → 自动触发生成+换装。
3. v0.7 Release 后 fork TermWrap 自建（客户端 B 轨：重定向增值）。
4. Server 端：角色门 DISM 自动化设计稿（docs/），许可门冻结。
