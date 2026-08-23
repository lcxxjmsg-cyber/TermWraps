# RDP 栈 Patch 面研究报告（基于现有 TermWrap provider）

> 结论先行：现有 provider 已覆盖 4+2+1 个检查点与 4 个核心策略键；**还有 3 个有价值的未覆盖门**
> （TSMF 多媒体重定向、DWM 远程化、客户端 RemoteApp），其中 TSMF 对流媒体/游戏场景价值最高。

## 0. TermWrap vs rdpwrap 覆盖对比

| 能力面 | rdpwrap | TermWrap | 说明 |
|---|---|---|---|
| 宿主/多会话/许可包装（4 核心点） | ✅ INI 逐版本 | ✅ 运行时自适配 | 两者都解锁，机制不同 |
| **重定向组件（USB/摄像头/麦克风）** | ❌ **没有** | ✅ **UmWrap+EndpWrap** | TermWrap 独有（组件层，见第 1 节） |
| SLPolicy 策略面（16 键） | ⚠️ 设计上能答更多查询（hook SLGetWindowsInformationDWORDWrapper），但属 Vista SP2 时代机制，现代构建未维护 | ⚠️ 只实现 4+SLInit | **两边都没覆盖 TSMF/DWM/RAIL**——正是本报告的机会区 |
| 维护模式 | 社区 INI 数据库 | 上游模式集 + 我们自维护 | — |

**核心差异**：rdpwrap 的 SLPolicy 是个"万能答录机"设计（hook 一个查询函数、按 INI 应答任意策略键），但现代 Windows 上该机制实际只服务 4 个偏移 + SLInit；TermWrap 是"逐个补丁点"设计，组件层（umrdp/rdpendp）反超 rdpwrap。**TSMF/DWM/RAIL 三个门两边都没维护**。

## 1. 当前已覆盖的 Patch 面（源码级盘点）

### TermWrap.dll（termsrv.dll）— 6 个补丁点 + 1 组数据

| 补丁 | 目标 | 作用 |
|---|---|---|
| DefPolicyPatch | CDefPolicy::Query | 宿主策略总闸（含 edx_ecx/eax_rcx_jmp/eax_rdi_jmp/r9d 等 10 变体） |
| LocalOnlyPatch | IsLicenseTypeLocalOnly | 许可本地化检查 |
| SingleUserPatch | IsSingleSessionPerUser(Enabled) | 单会话限制（两处位置） |
| **NonRDPPatch** | IsAllowNonRDPStack | 非 RDP 栈允许（本次盘点新发现） |
| **PropertyDevicePatch** | GetConnectionProperty 设备属性 | 设备重定向（受 fDisablePNPRedir 注册表门控） |
| SLInit 数据 | CSLQuery 成员（bServerSku/bRemoteConnAllowed/bFUSEnabled/bAppServerAllowed/bMultimonAllowed/lMaxUserSessions/ulMaxDebugSessions/bInitialized） | 策略数据直写 |

### UmWrap.dll（umrdp.dll）— 2 个许可门
- `PnpRedirectionAllowed`（PnP/USB 重定向许可）
- `CameraRedirectionAllowed`（摄像头重定向许可）

### EndpWrap.dll（rdpendp.dll）— 1 个许可门
- `TSAudioCaptureAllowed`（音频录制重定向许可）

### 注册表/策略层（Core.Redirection，非补丁）
- fDisable* 八项重定向开关；TSAppAllowList（RemoteApp 白名单绕过）；影子；60fps；防火墙等

## 2. rdpwrap SLPolicy 16 键 × 当前覆盖矩阵

| SLPolicy 键 | 覆盖状态 |
|---|---|
| AllowRemoteConnections / AllowMultipleSessions / AllowAppServerMode / AllowMultimon | ✅ TermWrap |
| MaxUserSessions / lMaxUserSessions | ✅ SLInit |
| LocalOnly / TSEasyPrintAllowed / PnpRedirectionAllowed | ✅ LocalOnlyPatch / v0.4 EasyPrint / UmWrap |
| **TSMFPluginAllowed**（多媒体重定向） | ❌ **未覆盖** |
| **UiEffects-DWMRemotingAllowed**（DWM 远程化） | ❌ **未覆盖** |
| **ClientSku-RAILAllowed**（客户端 RemoteApp） | ❌ **未覆盖** |
| **Advanced-Compression-Allowed** | ❌ 未覆盖（价值低，Win10+ 默认开） |
| ce0ad219/45344fe7/8dc86f1d MaxSessions（会话数 GUID 门） | ⚠️ 部分（SLInit 已设 lMaxUserSessions=0，这些 GUID 门是否独立生效待验证） |

## 3. 新 Patch 候选（按价值排序）

### 候选 1：TSMF 多媒体重定向（最高价值）
- **目标**：TSMF（RemoteFX 多媒体/视频重定向）在 Home/Server 上的许可门
- **场景**：RDP 会话内流畅视频播放、流媒体、游戏——正是 multiseat/远程游戏（Duo 类）刚需
- **验证路径**：符号模式在 `tsmf.dll` / `termsrv.dll` 中搜索 `TSMFPluginAllowed` 字符串引用 → 定位检查函数（与 EndpWrap 同方法论）
- **难度**：中（新 DLL 目标或 TermWrap 内新增补丁点）；**风险**：低-中（同许可灰区）

### 候选 2：UiEffects-DWMRemotingAllowed（DWM 远程化）
- **目标**：DWM 合成在 RDP 会话中的远程化许可
- **场景**：透明效果/Aero/动画在远程会话中的保真；对远程桌面体验有感知价值
- **验证路径**：termsrv.dll 中搜索该键引用；可能已被 IsAppServerInstalled/bMultimon 隐式覆盖（需验证）

### 候选 3：ClientSku-RAILAllowed（客户端 RemoteApp）
- **目标**：客户端 SKU 上 RemoteApp 会话的许可门
- **场景**：从 Home/Pro 发起/承载 RemoteApp——与现有 fDisabledAllowList + .rdp 生成器配套
- **验证路径**：termsrv.dll 中搜索键引用；可能受 AppServerMode 隐式覆盖（需验证）

### 候选 4（低价值）：Advanced-Compression-Allowed
- Win10/11 默认允许高级压缩，收益可忽略。

## 4. 方法论（全部复用现有工具链）

1. **符号定位**：`build\sym-tools\` 符号模式 → 在目标 DLL（tsmf.dll/rdpcorets.dll/termsrv.dll）中定位字符串引用函数
2. **对照目录**：`docs\pattern-variant-catalog.md` 的既有变体形态
3. **补丁实现**：新 wrapper DLL（如 TsmfWrap.dll，EndpWrap 同构）或 TermWrap 内新增补丁点
4. **验证**：测试台 + VM 矩阵（补丁后会话内实际播放验证）

## 5. 建议路线

- **第一步（验证性）**：用符号工具扫描 `tsmf.dll` / `termsrv.dll`，确认三个候选键的检查位置与当前 Home/Pro 上的实际返回值——先判断"是否真的需要补"；
- **第二步**：TSMF 优先级最高（直接服务远程游戏/流媒体），按 EndpWrap 模式做 `TsmfWrap.dll`；
- DWM/RAIL 视验证结果决定；压缩跳过。
