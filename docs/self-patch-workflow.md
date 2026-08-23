# 断路由自救 SOP：OffsetFinder 新模式自修补

> 场景：llccd 停更（或更新滞后），微软新 CU 改变 termsrv.dll 代码生成，
> 导致 NoSym/符号模式均无法定位补丁点。
> 本文件是"我们自己做 llccd 做的事"的标准流程。

## 1. 检测（确认真的需要修）

在目标机跑测试台，观察失败点：

```powershell
.\tools\offset-test.ps1（DLL 离线）+ .\build\sym-tools\sym-test.ps1（符号研究）
```

失败特征（判定需要新模式的信号）：

| 输出 | 含义 |
|---|---|
| `ERROR: DefPolicyPatch pattern not found` | CDefPolicy::Query 内部代码生成变了 |
| `ERROR: SingleUserPatch not found` | SingleUserPatch 的调用/比较形态变了 |
| `ERROR: LocalOnlyPatch pattern not found` | 许可本地化检查点变了 |
| `ERROR: CSLQuery_Initialize not found` | CSLQuery::Initialize 入口模式变了 |
| `ERROR: xxx not found`（符号模式） | 连符号都解析不到（罕见，PDB 缺失） |

对照排查：先确认社区 INI 是否已有该版本段（`rdp-compat.ps1 -Build <build>`）——
若社区已有 = 直接用社区段，**不需要修**；社区也没有 = 需要新模式。

## 2. 定位新代码生成（核心逆向工作）

目标：拿到新变体的"特征指令序列"，在 Patch.cpp 里加一个匹配分支。

参考现有变体（build\src\offsetfinder\RDPWrapOffsetFinder\Patch.cpp）：

| 变体 | 模式本质 |
|---|---|
| `CDefPolicy_Query_edx_ecx` / `eax_rcx` / `eax_rdi` / `edi_rcx` | 寄存器分配变化 |
| `CDefPolicy_Query_eax_rcx_jmp` / `eax_rdi_jmp` | CMP 后跟 JNZ/JMP 跳转形态 |
| `CDefPolicy_Query_r9d_rdi_jmp`（v0.6/v1.0 新增） | 用 r9d 寄存器 + jmp |

步骤：

```powershell
# a) 拿新构建的 termsrv.dll（MSU 解包或目标机复制）
# b) 用符号模式 EXE 确认函数入口仍可定位（能定位 = 只需内部模式）
.\src\bin\v1.0\x64\RDPWrapOffsetFinder.exe <termsrv路径>
# c) 反汇编目标函数，找"CMP mem, reg/imm 后跟 JZ/JNZ/JMP"的新形态：
#    Zydis 反汇编脚本（参考 build/fork/hosttest.c 的用法）
# d) 对比 Patch.cpp 里 DefPolicyPatch/SingleUserPatch/LocalOnlyPatch 的
#    现有分支（disp 0x63c/0x320、mov_base/mov_target 跟踪、JNZ 变体），
#    识别差异 → 新分支
```

工具：dumpbin（VS Build Tools）、Zydis（build/src/zydis）、社区 INI 同版本段作真值基准。

## 3. 打补丁 + 重建 + 部署

```powershell
# a) 修改 build\src\offsetfinder\RDPWrapOffsetFinder\Patch.cpp（fork 源）
#    加新分支；若 [PatchCodes] 缺新 code 定义 → 同时加进
#    rdpwarps 的 rdpwrap_templete.ini [PatchCodes]
# b) 重建（无需等上游）
.\build\build.ps1
# c) 部署 + pin 同步
.\build\update-rdpwarp.ps1
```

## 4. 验证（必须全过才算修好）

```powershell
# ① 生成正确性：输出与社区同版本段逐键一致（有社区段时）
.\tools\offset-test.ps1（DLL 离线）+ .\build\sym-tools\sym-test.ps1（符号研究）
# ② rdpwarps 集成：真实模板 + Test-RdpIniCandidate → Valid=True
#    （harness-dll.ps1）
# ③ 真机运行时：安装后 RDPConf 状态 + 多会话实测
```

## 5. 回馈上游（可选）

llccd 还在的话，把新变体提 PR 到 `llccd/RDPWrapOffsetFinder`（MIT 许可允许）。
好处：未来他的更新继续覆盖我们的 pin，减少我们 fork 的漂移。

## 边界

- **符号模式兜底**：新模式只影响"函数内部偏移定位"；符号模式仍能定位函数入口。
  若连符号都解析不到（PDB 缺失/结构重排）→ 只能纯模式匹配，成本更高。
- **频率预期**：历史 ~6 个月一次；多数 UBR 更新不触发（模式稳定）。
- **不要修的系统组件**：UmWrap/EndpWrap 的偏移不在本流程内（那是 TermWrap 项目的事）。

