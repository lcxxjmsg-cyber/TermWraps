# TermWrap — Windows RDP 多会话控制器（TermWrap 版）

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![TermWrap](https://img.shields.io/badge/TermWrap-master%20%40%2028000.2307-blue.svg)](https://github.com/llccd/TermWrap)

基于 [llccd/TermWrap](https://github.com/llccd/TermWrap)（含 28000.2307 修复的 master 构建）的自维护 RDP 多会话方案。
无需 INI、无需等社区——**运行时自适配，Windows 更新后无需任何操作**。

## 特性

- 🚀 **零维护**：TermWrap 每次加载时动态反汇编 termsrv.dll 定位补丁点，新版本更新后即自动适配
- 🔧 **开箱即用**：双击 `termwrap.cmd`（或关联 .ps1 后双击脚本）自动请求管理员权限
- 🎥 **重定向增强**：UmWrap（摄像头/USB，Home/Server）、EndpWrap（音频录制）
- 🛡️ **健康自检**：Healthy/Degraded/Failed 三元状态 + 自动看门狗（服务/监听/握手）
- 🔄 **版本感知**：termsrv 变化自动检测
- 🎛️ **完整配置**：会话 / 安全 / 影子(远程控制) / 显示 / 超时 / 端口 / 防火墙 / RemoteApp / fDisable* 重定向策略
- 🌐 **8 语言**：中 / 英 / 日 / 韩 / 法 / 德 / 西 / 俄（自动检测）
- 📦 **离线可用**：二进制自带（哈希校验），部署与更新均不依赖网络

## 快速开始

### 方式一：双击 termwrap.cmd（推荐）

双击 `termwrap.cmd` → UAC 弹窗点"是" → 进入交互菜单。全部自动，无需先开管理员终端。

### 方式二：双击 termwrap.ps1

首次先导入关联（让 .ps1 可双击运行）：

```
install-ps1-assoc.reg   （双击导入，仅影响当前用户）
```

之后双击 `termwrap.ps1` 即会运行，脚本内部自动申请管理员权限。

### 方式三：命令行

```powershell
.\termwrap.ps1              # 交互菜单（自动提权）
.\termwrap.ps1 -Install     # 静默安装 + 看门狗
.\termwrap.ps1 -Uninstall   # 干净卸载
.\termwrap.ps1 -Help        # 用法说明
```

> 提示：在自动化/测试场景可用环境变量 `TERMWRAP_NO_ELEVATE=1` 跳过提权。

## 使用指南（交互菜单）

| 键 | 功能 |
|---|---|
| `1` | 安装 / 更新 TermWrap（自动改写 TermService 的 ServiceDll + 热启动验证） |
| `2`–`7` | 会话 / 安全 / 影子 / 显示 / 超时 / 端口配置 |
| `8` | 看门狗（注册 / 注销计划任务） |
| `9` | 重启 RDP 服务 |
| `U` | UmWrap / EndpWrap 增强（摄像头/USB/音频录制） |
| `D` | 重定向策略（fDisable* 八项开关） |
| `R` | 生成 RemoteApp .rdp 文件 |
| `0` | 卸载（还原 ServiceDll） |
| `E` | 退出 |

## 工作原理

TermWrap 以 `TermService\Parameters\ServiceDll` 指向的"包装 DLL"身份加载，转发真实 `termsrv.dll` 的
`ServiceMain`/`SvchostPushServiceGlobals`，加载时用 Zydis 反汇编当前构建的 termsrv.dll 并动态定位补丁点：

- `CDefPolicy::Query`（宿主策略）
- `IsTerminalTypeLocalOnly` / `IsSingleSessionPerUserEnabled`（会话限制）
- `SLGetWindowsInformationDWORDWrapper`（许可包装）

因此**没有 INI 数据库**——任何现有/未来的构建都能在首次运行时自适配；UmWrap/EndpWrap 用同一方法论补 Home/Server
被禁用的摄像头/USB/音频录制组件。

## 兼容性

- Windows Vista SP2 起（x86/x64）；UmWrap/EndpWrap 仅 x64；不支持 ARM64
- 已含 **28000.2307（26H1）修复**——比官方 v0.6 Release 更新
- 二进制自建自 master 源码（见 `src/bin/termwrap/SHA256.txt`），零第三方运行时依赖

## 目录结构

```
termwrap.ps1 / termwrap.cmd   入口（自动提权）
install-ps1-assoc.reg         可选：.ps1 双击运行关联
src/core/                     7 个核心模块（I18n/Common/Shadow/Policy/Redirection/Health/Deploy）
src/ui/Menu.ps1               交互菜单
src/bin/termwrap/             部署二进制（TermWrap/UmWrap/EndpWrap + SHA256 清单）
docs/                         termwrap-deployment-notes.md（ServiceDll 机制说明）
```

## 安全说明

- 本工具修改系统服务注册表（ServiceDll）与 RDP 行为，**请仅在自有/受管设备上使用**
- 二进制来源固定（SHA256 清单校验，部署前强校验）
- 安装失败自动回滚（ServiceDll 还原 + 文件清理）；热启动失败保留配置并提示重启
- 卸载 = 还原原始 ServiceDll + 删除文件 + 注销看门狗

## 致谢与许可

- 上游：[llccd/TermWrap](https://github.com/llccd/TermWrap)、[llccd/RDPWrapOffsetFinder](https://github.com/llccd/RDPWrapOffsetFinder)（MIT）
- 本项目包装/管理脚本与模块：MIT（见 LICENSE）
