# TermWraps

基于 **TermWrap** 的自维护 RDP 多会话控制器（独立维护分支）。通过改写 TermService 的 `ServiceDll` 指针加载包装 DLL，在无需修改系统文件的前提下启用「多会话远程桌面」以及可选的摄像头/USB、音频录制重定向。

> 无需 rdpwrap 的 INI，内部通过自维护的补丁面（patch surface）适配当前系统的 `termsrv.dll`。

## 功能特性

- **多会话 RDP**：同一时间段多个终端可同时登录同一主机。
- **UmWrap（x64）**：摄像头 / USB 重定向。
- **EndpWrap（x64）**：音频录制重定向。
- **自愈看门狗**：开机自启 + 每日 03:00 自动检查，异常时重写 `ServiceDll` 并重启服务。
- **无需外部文件**：一键脚本自动提权、部署、改注册表、放行防火墙、启用远程桌面、健康自检。

## 系统要求

- Windows 10/11 或 Windows Server（需含 `termsrv.dll`）。
- **管理员权限**（脚本运行时会自动申请 UAC）。
- 摄像头/USB、音频录制重定向（UmWrap/EndpWrap）仅支持 **x64**。
- 本仓库已实测适用于 `termsrv.dll 10.0.26100.8328`；其它构建可能需等待适配。

## 安装

1. 从 [Releases](https://github.com/lcxxjmsg-cyber/TermWraps/releases) 下载最新的 `termwrap-vX.Y.Z.zip` 并解压。
2. 双击 `termwrap.cmd`，或右键 `termwrap.ps1` → “使用 PowerShell 运行”。

脚本会自动申请管理员权限，再交互式完成部署：复制 DLL → 改写 `ServiceDll` → 启用远程桌面并放行防火墙 → 重启 TermService → 健康自检。

> x64 上默认一并启用 UmWrap（摄像头/USB）与 EndpWrap（音频录制重定向）；x86 仅部署 TermWrap 核心。

## 交互式菜单

启动后按提示选择：

| 按键 | 功能 |
|---|---|
| 1 | 安装 / 升级（重新部署） |
| 2 | 会话设置（最大并发、每用户单会话） |
| 3 | 安全设置（NLA、安全层） |
| 4 | 远程控制 / 影子模式 |
| 5 | 显示与会话选项（多显示器、隐藏用户、自动重连） |
| 6 | 会话超时 |
| 7 | 更改 RDP 端口 |
| 8 | 看门狗管理（注册 / 注销） |
| 9 | 重启 TermService |
| U | UmWrap / EndpWrap 部署管理 |
| D | 重定向菜单 |
| R | 生成 RemoteApp 连接文件 |
| 0 | 卸载 |
| E | 退出 |

## 命令行用法

```powershell
# 交互式菜单（自动提权）
.\termwrap.ps1

# 静默安装
.\termwrap.ps1 -Install

# 干净卸载
.\termwrap.ps1 -Uninstall

# 用法说明
.\termwrap.ps1 -Help
```

首次安装时采用「热启动」验证：改写 `ServiceDll` 后重启 TermService 并检查 RDP 监听与协议握手。若热启动未能就绪，脚本会自动回滚到原配置并提示；如需保留配置以重启系统后生效，可对部署函数使用 `-KeepOnFail`（详见源码）。

## 卸载

选择菜单「0」或运行 `.\termwrap.ps1 -Uninstall`：恢复安装前的 `ServiceDll`、删除已部署的 DLL、移除看门狗与 Defender 排除项，并还原音频重定向配置。

## 目录结构（仓库）

```
├─ termwrap.ps1 / termwrap.cmd   # 入口脚本（交互菜单 / -Install / -Uninstall / -Help）
├─ src\
│  ├─ core\                      # 核心模块（I18n / Common / Deploy / Health / Policy / Shadow / Redirection）
│  ├─ ui\Menu.ps1                # 主菜单
│  └─ bin\                       # 部署用 DLL 集与 OffsetFinder
├─ tools\                        # 偏移生成/测试工具（开发用）
├─ build\                        # 自建管线（开发用）
└─ docs\                         # 调研与设计文档（开发用）
```

## 说明

- 本工具属于自维护分支，与官方 rdpwarp 存在互斥：同一服务指针同一时刻只能指向一个包装 DLL。
- 部署涉及修改系统服务与防火墙策略，请仅在明确需要多会话 RDP 的机器上使用。
- 更多技术细节见仓库内 `docs/` 目录。
