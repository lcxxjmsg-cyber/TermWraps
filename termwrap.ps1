<#
.SYNOPSIS
    termwrap - TermWrap 版 RDP 多会话控制器
.DESCRIPTION
    基于 TermWrap 的自维护 RDP 方案（独立维护分支）。
    双击 termwrap.cmd 或关联 .ps1 后双击本脚本即可自动申请管理员权限。
.DESCRIPTION
    模块化架构：
    src/core/  Core.I18n / Core.Common / Core.Shadow / Core.Policy
               Core.Redirection / Core.Health / Core.Deploy
    src/ui/    Menu.ps1
.EXAMPLE
    .\termwrap.ps1              # 交互式菜单（自动提权）
    .\termwrap.ps1 -Install     # 静默安装 + 看门狗
    .\termwrap.ps1 -Uninstall   # 干净卸载
    .\termwrap.ps1 -Help        # 用法说明
#>
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# ===== 自动提权（UAC）=====
$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $script:IsAdmin -and -not $env:TERMWRAP_NO_ELEVATE) {
    try {
        $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
        if ($scriptPath) {
            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"")
            if ($Install) { $argList += '-Install' }
            if ($Uninstall) { $argList += '-Uninstall' }
            if ($Help) { $argList += '-Help' }
            $p = Start-Process powershell -Verb RunAs -ArgumentList $argList -PassThru -ErrorAction Stop
            $p.WaitForExit()
            exit $p.ExitCode
        }
    } catch {
        Write-Host '需要管理员权限（UAC 被取消或不可用）——请右键"以管理员身份运行"。'
        exit 1
    }
}

$script:VERSION = '0.3.0'
$script:SCRIPT_DIR = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:CORE_DIR = Join-Path $script:SCRIPT_DIR 'src\core'

foreach ($mod in @('Core.I18n.ps1', 'Core.Common.ps1', 'Core.Shadow.ps1', 'Core.Policy.ps1', 'Core.Redirection.ps1', 'Core.Health.ps1', 'Core.Deploy.ps1')) {
    $p = Join-Path $script:CORE_DIR $mod
    if (-not (Test-Path $p)) { Write-Host "缺少模块: $mod"; exit 1 }
    . $p
}
. (Join-Path $script:SCRIPT_DIR 'src\ui\Menu.ps1')

if ($Help) { Show-Help; return }
if ($Install) {
    if (-not $script:IsAdmin) { Write-Host "需要管理员权限"; exit 1 }
    $arch = if ([Environment]::Is64BitProcess) { 'x64' } else { 'x86' }
    $ok = Deploy-TermWrapBinaries -UmWrap:($arch -eq 'x64') -EndpWrap:($arch -eq 'x64')
    if ($ok) { Register-TermWrapWatchdog -Quiet; Write-Host "termwrap 安装完成" }
    exit $(if ($ok) { 0 } else { 1 })
}
if ($Uninstall) {
    if (-not $script:IsAdmin) { Write-Host "需要管理员权限"; exit 1 }
    if (Uninstall-TermWrapBinaries) { Unregister-TermWrapWatchdog }
    exit 0
}
Invoke-InteractiveMenu
