# Server 端 RDS/RDSH 设计稿（冻结存档）

> 状态：**冻结**。按用户决定，Server 端许可门 hook 不实现；本文档仅为后续工作线存档。
> 相关分析见会话记录：Server 端两门分解（角色门/许可门）。

## 背景结论（已实证）

1. rdpwrap/TermWrap 均**不解决** Server 端 RDS/RDSH：
   - 角色门：RDSH 未装 → 仅 2 个并发管理会话；`Install-WindowsFeature RDS-RD-Server` 不需要 key，纯自动化可行。
   - 许可门：RDSH 装好后 120 天宽限，之后 termsrv.dll 许可检查拒绝新会话——**这是唯一真正的难点**（hook 或补丁，违反 EULA 的灰区，已冻结）。
2. TermWrap 在 Server 上的价值仅剩 UmWrap/EndpWrap（RDSH 默认把摄像头/USB/麦克风重定向锁死）。
3. Duo（DuoStream/Duo）是客户端 multiseat 方案，不解决 Server RDSH；仓库无源码（只有文档）。

## 角色门自动化设计（可实施部分，已冻结不实现）

```powershell
# 若未来解冻，Core.ServerAdapter.ps1 的骨架：
# 1) Install-WindowsFeature RDS-RD-Server, RDS-Licensing, RDS-Connection-Broker
# 2) 配置 RDSH 集合（New-RDSessionCollection）
# 3) 许可模式设置（Set-RDLicenseConfiguration）
# 4) 重定向策略（复用 Core.Redirection 的 fDisable*）
```

## 许可门（冻结，不实现）

- 已知社区方向：运行时 hook Server termsrv.dll 的许可状态检查（TermWrap 同构机制 fork 扩展）。
- 维护面：Server 分支（17763/20348/26100 Server）比客户端小；老分支模式稳定。
- 法律/合规风险显著高于客户端 SKU 限制绕过。**决策：冻结。**

## 对 TermWrapWrapper 的含义

- 项目边界 = 客户端 SKU（Vista 起）。Server 部署时：
  - 角色门 → 用户自行用官方 RDS 或后续解冻；
  - UmWrap/EndpWrap 在 Server 上可用（Core.Deploy 已按 SKU 处理，不区分 Server/Home）。
