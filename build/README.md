# build/ — 开发者工具链（非 App 运行部分）

> 本目录是**开发者工具**，App 用户不需要它。用于从上游源码自建 TermWrap / OffsetFinder 二进制。

## 前提

- Windows + PowerShell 5.1+
- **VS Build Tools 2026+**（含 VC 工具链、v145 toolset）：https://aka.ms/buildtools
- 网络：api.github.com（查 master）、codeload.github.com（下源码）

## 一键更新（推荐）

```powershell
# 检查两个上游（OffsetFinder + TermWrap）是否有新修复，不构建
.\build\update-rdpwarp.ps1 -CheckOnly

# 有更新时：更新 pin → 全量重建 → 部署
.\build\update-rdpwarp.ps1

# 同时更新 rdpwarps.ps1 的 OffsetFinder DLL（需 RDPWarpper 仓库在本地）
.\build\update-rdpwarp.ps1 -RdpwarpsRoot D:\path\RDPWarpper
```

## 手动构建

```powershell
.\build\build.ps1            # 全量（源码校验 → 补丁 → zydis → DLL/EXE → 部署）
```

产物落点：`src\bin\offsetfinder\`（DLL+清单）、`src\bin\termwrap\`（TermWrap/UmWrap/EndpWrap+清单）、`build\sym-tools\`（符号研究）。

## 维护模式

| 场景 | 做法 |
|---|---|
| 上游活跃 | `update-rdpwarp.ps1` 自动跟 master |
| 上游停更、新构建断点 | 按 `docs\self-patch-workflow.md` + `docs\pattern-variant-catalog.md` 自己加模式变体 → 重建 |
