# TermWrap 部署机制笔记（Phase 0 原型知识）

> 来源：TermWrap-0.6.zip（SHA256 0680E261...36D1A9 已验证）+ 官方 reg 文件解码 + README。
> 用途：Core.Deploy.ps1 的"reg 等价写键"实现依据。

## 1. 产物清单

```
x64\ TermWrap.dll  UmWrap.dll  EndpWrap.dll  Zydis.dll
x86\ TermWrap.dll  Zydis.dll
```
- UmWrap/EndpWrap 仅 x64；x86 只有 TermWrap 核心。
- 部署目标：`%ProgramFiles%\RDP Wrapper\`（与 rdpwrap 同居）。
- EndpWrap.dll 与 Zydis.dll 需额外复制到 `System32`（用于音频录制重定向）。

## 2. reg 键位（核心机制 = 覆盖 ServiceDll 指针）

| 文件 | 键 | 值（REG_EXPAND_SZ） |
|---|---|---|
| Install_termwrap_only.reg | `HKLM\...\Services\TermService\Parameters` `ServiceDll` | `%ProgramFiles%\RDP Wrapper\TermWrap.dll` |
| Install_termwrap_umwrap.reg | 同上 | 同上 |
| Install_termwrap_umwrap.reg | `HKLM\...\Services\UmRdpService\Parameters` `ServiceDll` | `%ProgramFiles%\RDP Wrapper\UmWrap.dll` |
| Revert_to_default.reg | TermService ServiceDll | `%SystemRoot%\System32\termsrv.dll` |
| Revert_to_default.reg | UmRdpService ServiceDll | `%SystemRoot%\System32\umrdp.dll` |
| Revert_to_rdpwrap.reg | TermService ServiceDll | `%ProgramFiles%\RDP Wrapper\rdpwrap.dll` |
| Revert_to_rdpwrap.reg | UmRdpService ServiceDll | `%SystemRoot%\System32\umrdp.dll` |

- **无新服务创建**（不需要 sc create）——改写既有服务指针即完成安装。
- 音频录制重定向（可选）：改 `HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp\AudioEnumeratorDll`：`rdpendp.dll` → `EndpWrap.dll`。

## 3. 设计推论（对 Core.Deploy 的意义）

- **安装** = 复制 DLL 集 + 写 1-2 个 ServiceDll（PowerShell `Set-ItemProperty -Type ExpandString` 等价，不依赖 reg.exe/外部 .reg 文件）。
- **卸载** = 恢复安装前保存的 ServiceDll 原值 + 删文件（对齐 Save/Restore-RdpInstallState 思路）。
- **热启动可行性**：ServiceDll 在服务启动时读取 → 改写后 stop/start 服务即生效，理论上**无需重启系统**——待 VM 实测确认（README 官方流程要求 reboot，但机制上热重启可行）。
- **TermWrap 与 rdpwrap 互斥**：同一服务指针只能指向一个；Revert_to_rdpwrap.reg 的存在说明上游已考虑切换场景——我们的 Core.Deploy 需处理"检测到 rdpwrap 已装 → 提示切换"。
- **UmWrap 判定**：Home/Server 版才需要 UmWrap（Pro/Ent 摄像头/USB 原生可用）；部署菜单按 SKU 提示。
- **Zydis.dll**：已静态链接（自建管线），不再需要分发——依赖仅系统 msvcrt/kernel32/advapi32。
- **Watchdog 语义（TermWrap 版）**：无 INI → 健康判定 = 服务运行 + ServiceDll 指向正确 + 监听 + 握手；故障恢复 = 重写 ServiceDll + 重启服务。

## 4. 待 VM 实测项

1. 热启动（改 ServiceDll → sc stop/start）是否生效，还是必须重启；
2. UmWrap 在 Server/Home 的实际效果；
3. x86 TermWrap 在 32 位系统上的表现；
4. TermWrap 与 rdpwrap 同机切换的干净度。

