# TermWrap 模式变体目录（自维护知识库）

> 用途：当新 Windows 构建改变 termsrv/umrdp/rdpendp 代码生成、TermWrap 模式失配时，
> 本文档是"对照基线"——新变体 = 在已知变体基础上的差异。
> 配合 docs/self-patch-workflow.md 使用。

## 1. DefPolicyPatch（CDefPolicy::Query 内部）

**匹配机制**（build 源 Patch.cpp `DefPolicyPatch`）：在函数入口后 128 字节内扫描
`CMP [reg+disp], reg/imm`（disp 0x63c 或 0x320 或 mov 跟踪）→ 后跟 JZ/JNZ/POP 分支 → 输出
`DefPolicyCode` 变体名。

**已知变体表**（模板 [PatchCodes] 全量）：

| 变体名 | PatchCodes | 特征 |
|---|---|---|
| `CDefPolicy_Query_edx_ecx` | BA000100008991200300005E90 | mov edx,1; mov [ecx+0x320],edx; pop esi |
| `CDefPolicy_Query_eax_rcx` | B80001000089813806000090 | mov eax,1; mov [rcx+0x638],eax |
| `CDefPolicy_Query_eax_rcx_jmp` | B80001000089813806000090EB | 同上 + JMP |
| `CDefPolicy_Query_eax_esi` | B80001000089862003000090 | mov eax,1; mov [esi+0x320],eax |
| `CDefPolicy_Query_eax_rdi` | B80001000089873806000090 | mov eax,1; mov [rdi+0x638],eax |
| `CDefPolicy_Query_eax_rdi_jmp` | B80001000089873806000090EB | 同上 + JMP |
| `CDefPolicy_Query_eax_ecx` | B80001000089812403000090 | mov eax,1; mov [rcx+0x324],eax |
| `CDefPolicy_Query_eax_ecx_jmp` | B800010000898120030000EB0E | mov eax,1; mov [rcx+0x320],eax + JMP |
| `CDefPolicy_Query_edi_rcx` | BF0001000089B938060000909090 | mov edi,1; mov [rcx+0x638],edi |
| `CDefPolicy_Query_r9d_rdi_jmp` | C7873806000000010000EB | mov [rdi+0x638],1 + JMP（r9d 时代新形态） |

**判定**：新构建断点报 `DefPolicyPatch pattern not found` → 反汇编 CDefPolicy::Query 开头，
找 `mov reg,1 → mov [reg+0x6xx],reg` 或 `mov [reg+0x6xx],1` 序列 → 对照上表寄存器/位移/跳转差异 → 新增条目。

## 2. SingleUserPatch（IsSingleSessionPerUserEnabled / CUtils）

**匹配机制**：扫描函数内 `CALL → memset/VerifyVersionInfoW 跳板` 后跟 `CMP [rbp/rsp+..],1` 或
`CALL [rip+..]=target2`；x86 另有 `CMP [ebp+..],1`。

**已知变体表**：

| PatchCodes | 语义 |
|---|---|
| `mov_eax_1_nop_1` = B80100000090 | mov eax,1; nop |
| `mov_eax_1_nop_2` = B8010000009090 | mov eax,1; nop; nop（当前主流） |
| `nop_3/4/7` | 覆盖原 CMP 指令 |
| `Zero` = 00 | 覆写为 0 |
| `pop_eax_add_esp_12_nop_2` = 5883C40C9090 | x86 形态 |

## 3. LocalOnlyPatch（CSLQuery::IsLicenseTypeLocalOnly）

**匹配机制**：`CALL → IsLicenseTypeLocalOnly 跳板` 后跟 TEST → JNS/JS → CMP → JZ 链，输出
`jmpshort`（EB）或 `nopjmp`（90E9）。

**变体**：仅 `jmpshort` / `nopjmp` 两种。

## 4. UmWrap / EndpWrap（低频维护）

- UmWrap（umrdp）：USB/DeviceRedirection 偏移（Server 2019 特例 + 6.2.9200 修过一次），
  SLGetWindowsInformationDWORD 变体（老 OS）。
- EndpWrap（rdpendp）：`TerminalServices-DeviceRedirection-Licenses-TSAudioCaptureAllowed`
  字符串定位 + `mov eax,1; ret`（B8 01 00 00 00 C3）——多年未变。

## 5. 历史断点与修复对照（预测性情报）

| 断点 | 修复内容 | 修复时间 |
|---|---|---|
| 22621.3374 | PropertyAddr not found（23H2 首个总挂） | 2024-06 |
| 26100.7523 | **total failure**（24H2 模式大改） | 2025-12 |
| 26100.8376 | DefPolicyPatch 修复 | 2026-05 |
| 28000.2307 | DefPolicyPatch（r9d 时代） | 2026-06/08 |

规律：约 6 个月一次；多数 UBR 更新不触发（模式稳定）；断点集中在 DefPolicy 家族。

## 6. 自维护能力矩阵

| 环节 | 依赖 llccd 吗 | 我们已有 |
|---|---|---|
| 构建任意上游提交 | 不依赖 | build.ps1（pin+补丁+MSVC） |
| 自动追踪 master | 不依赖 | update-rdpwarp.ps1（双仓库，-CheckOnly 检测） |
| 诊断断点 | 不依赖 | sym 研究工具 + 本目录 |
| 新增模式变体 | **不依赖**（MIT，改自己 fork） | self-patch-workflow.md + 本目录基线 |
| 验证修复 | 不依赖 | 测试台 + 真机/VM 矩阵 |
