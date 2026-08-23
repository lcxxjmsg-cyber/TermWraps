# ui/Menu.ps1 - TermWrap 主菜单 + 交互循环 + 编排函数
# 1:1 移植 Show-MainMenu 结构 + TermWrap 状态语义 + U(UmWrap/EndpWrap)/D(重定向) 新菜单

function Show-MainMenu {
    if (-not (Test-Admin)) {
        Clear-Host
        Write-Host "+----------------------------------------------------+" -ForegroundColor Red
        Write-Host "|     $(T 'admin_required')" -ForegroundColor Red
        Write-Host "+----------------------------------------------------+" -ForegroundColor Red
        Write-Host ""
        Write-Host "  $(T 'press_any_key')"; $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown"); return
    }

    $s = Get-TermWrapStatus
    Clear-Host
    Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "|          termwrap v$($script:VERSION)                  |" -ForegroundColor Cyan
    Write-Host "|     $(T 'title')" -ForegroundColor Cyan
    Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "|  termsrv.dll : $($s.TermsrvVersion.PadRight(37))" -ForegroundColor DarkGray
    Write-Host "|  $(T 'status_servicedll'): $($s.TermServiceDll)" -ForegroundColor DarkGray
    $hc = switch ($s.HealthState) { 'Healthy' { 'Green' } 'Degraded' { 'Yellow' } default { 'Red' } }
    $hl = switch ($s.HealthState) { 'Healthy' { T 'health_healthy' } 'Degraded' { T 'health_degraded' } default { T 'health_failed' } }
    Write-Host "|  $(T 'status_health'): " -NoNewline -ForegroundColor DarkGray
    Write-Host "$($hl.PadRight(10))" -NoNewline -ForegroundColor $hc
    $svcColor = if ($s.ServiceStatus -eq 'Running') { 'Green' } elseif ($s.ServiceStatus -eq 'Stopped') { 'Red' } else { 'DarkGray' }
    Write-Host "  $(T 'service'): " -NoNewline -ForegroundColor DarkGray; Write-Host "$("$($s.ServiceStatus)".PadRight(8))" -NoNewline -ForegroundColor $svcColor
    Write-Host "  $(T 'port'): $($s.Port)" -NoNewline -ForegroundColor DarkGray
    if ($s.Listener) { Write-Host "  $(T 'listening')" -NoNewline -ForegroundColor Green } else { Write-Host "  $(T 'closed')" -NoNewline -ForegroundColor Red }
    Write-Host ""
    if ($s.Installed) {
        $uc = if ($s.UmWrap) { 'Green' } else { 'DarkGray' }
        Write-Host "|  $(T 'status_umwrap'): " -NoNewline -ForegroundColor DarkGray
        Write-Host $(if ($s.UmWrap) { 'enabled' } else { '-' }) -NoNewline -ForegroundColor $uc
        Write-Host "  $(T 'wrapper'): " -NoNewline -ForegroundColor DarkGray; Write-Host 'TermWrap' -ForegroundColor Green
        Write-Host "  $(T 'watchdog'): " -NoNewline -ForegroundColor DarkGray; Write-Host $(if ($s.Watchdog) { T 'active' } else { T 'inactive' }) -ForegroundColor $(if ($s.Watchdog) { 'Green' } else { 'Yellow' })
        Write-Host "  $(T 'sessions'): $($s.Sessions.Count)" -ForegroundColor DarkGray
        if ($s.Change.Changed) { Write-Host "  [!] $(T 'status_changed'): $($s.Change.Previous) -> $($s.Change.Current)" -ForegroundColor Yellow }
        if ($s.HealthMessage -and $s.HealthState -ne 'Healthy') { Write-Host "  [!] $($s.HealthMessage)" -ForegroundColor Yellow }
    }
    Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan

    Write-Host ""
    if (-not $s.Installed) {
        Write-Host "  " -NoNewline; Write-Host "1." -NoNewline -ForegroundColor Yellow
        Write-Host " $(T 'menu_install_title')" -ForegroundColor Green
        Write-Host "     $(T 'menu_install_desc')" -ForegroundColor DarkGray
        Write-Host "  " -NoNewline; Write-Host "2." -NoNewline -ForegroundColor Yellow
        Write-Host " $(T 'menu_exit')" -ForegroundColor Gray
    } else {
        Write-Host "  " -NoNewline; Write-Host "1." -NoNewline -ForegroundColor Yellow
        Write-Host " $(T 'menu_update_title')" -ForegroundColor Green
        Write-Host "     $(T 'menu_update_desc')" -ForegroundColor DarkGray
        Write-Host "  " -NoNewline; Write-Host "2." -NoNewline -ForegroundColor Yellow
        Write-Host " $(T 'menu_session_title')" -ForegroundColor White
        Write-Host "     $(T 'menu_session_desc')" -ForegroundColor DarkGray
        Write-Host "  " -NoNewline; Write-Host "3." -NoNewline -ForegroundColor Yellow
        Write-Host " $(T 'menu_security_title')" -ForegroundColor White
        Write-Host "     $(T 'menu_security_desc')" -ForegroundColor DarkGray
        Write-Host "  " -NoNewline; Write-Host "4." -NoNewline -ForegroundColor Yellow
        Write-Host " $(T 'menu_shadow_title')" -ForegroundColor White
        Write-Host "     $(T 'menu_shadow_desc')" -ForegroundColor DarkGray
        Write-Host "  " -NoNewline; Write-Host "5." -NoNewline -ForegroundColor Yellow
        Write-Host " $(T 'menu_display_title')" -ForegroundColor White
        Write-Host "     $(T 'menu_display_desc')" -ForegroundColor DarkGray
        Write-Host "  " -NoNewline; Write-Host "6." -NoNewline -ForegroundColor Yellow
        Write-Host " $(T 'menu_timeout_title')" -ForegroundColor White
        Write-Host "     $(T 'menu_timeout_desc')" -ForegroundColor DarkGray
        Write-Host "  " -NoNewline; Write-Host "7." -NoNewline -ForegroundColor Yellow
        Write-Host " $(T 'menu_port_title')" -ForegroundColor White
        Write-Host "     $(T 'menu_port_desc')" -ForegroundColor DarkGray
        Write-Host "  " -NoNewline; Write-Host "8." -NoNewline -ForegroundColor Yellow
        Write-Host " $(T 'menu_watchdog_title')" -ForegroundColor White
        Write-Host "     $(T 'menu_watchdog_desc')" -ForegroundColor DarkGray
        Write-Host "  " -NoNewline; Write-Host "9." -NoNewline -ForegroundColor Yellow
        Write-Host " $(T 'menu_restart')" -ForegroundColor White
        Write-Host "     $(T 'menu_restart_desc')" -ForegroundColor DarkGray
        Write-Host "  " -NoNewline; Write-Host "U." -NoNewline -ForegroundColor Magenta
        Write-Host " $(T 'menu_umwrap_title')" -ForegroundColor White
        Write-Host "     $(T 'menu_umwrap_desc')" -ForegroundColor DarkGray
        Write-Host "  " -NoNewline; Write-Host "D." -NoNewline -ForegroundColor Magenta
        Write-Host " $(T 'menu_redirect_title')" -ForegroundColor White
        Write-Host "     $(T 'menu_redirect_desc')" -ForegroundColor DarkGray
        Write-Host "  " -NoNewline; Write-Host "R." -NoNewline -ForegroundColor Magenta
        Write-Host " $(T 'menu_remoteapp')" -ForegroundColor White
        Write-Host "     $(T 'menu_remoteapp_desc')" -ForegroundColor DarkGray
        Write-Host "  " -NoNewline; Write-Host "0." -NoNewline -ForegroundColor Red
        Write-Host " $(T 'menu_uninstall')" -ForegroundColor Red
        Write-Host "     $(T 'menu_uninstall_desc')" -ForegroundColor DarkGray
        Write-Host "  " -NoNewline; Write-Host "E." -NoNewline -ForegroundColor Gray
        Write-Host " $(T 'menu_exit')" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "-----------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  $($script:LANG_NAMES[$script:LANG])" -ForegroundColor Cyan
}

function Invoke-TermWrapInstall {
    Clear-Host
    Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "|  $(T 'menu_install_title')" -ForegroundColor Cyan
    Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
    $arch = if ([Environment]::Is64BitProcess) { 'x64' } else { 'x86' }
    $um = ($arch -eq 'x64')
    $end = ($arch -eq 'x64')
    $ok = Deploy-TermWrapBinaries -UmWrap:$um -EndpWrap:$end
    if ($ok) {
        Register-TermWrapWatchdog
        Write-S "$(T 'install_done_hint')"
    }
    Write-Host ""; cmd /c pause 2>&1 | Out-Null
}

function Invoke-TermWrapUpdate {
    Clear-Host
    Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "|  $(T 'menu_update_title')" -ForegroundColor Cyan
    Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
    $s = Get-TermWrapStatus
    $ok = Deploy-TermWrapBinaries -UmWrap:$s.UmWrap
    if ($ok) { Write-S "$(T 'menu_update_title') OK" }
    Write-Host ""; cmd /c pause 2>&1 | Out-Null
}

function Invoke-TermWrapUninstall {
    Clear-Host
    Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "|  $(T 'menu_uninstall')" -ForegroundColor Cyan
    Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
    if (Uninstall-TermWrapBinaries) {
        Unregister-TermWrapWatchdog
        Write-S "$(T 'uninstall_done_hint')"
    }
    Write-Host ""; cmd /c pause 2>&1 | Out-Null
}

function Show-UmWrapMenu {
    Clear-Host
    Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "|  $(T 'menu_umwrap_title')" -ForegroundColor Cyan
    Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
    $s = Get-TermWrapStatus
    $umState = if ($s.UmWrap) { T 'active' } else { '-' }
    $au = Get-RegDword $REG_AUDIO_ENUM '(default)'
    $endState = if ($au -eq 'EndpWrap.dll') { T 'active' } else { '-' }
    Write-Host "  UmWrap : $umState    EndpWrap: $endState" -ForegroundColor DarkGray
    Write-Host "  1. $(T 'umwrap_deploy')" -ForegroundColor Yellow
    Write-Host "  2. $(T 'umwrap_undeploy')" -ForegroundColor Red
    Write-Host "  3. $(T 'endpwrap_deploy')" -ForegroundColor Yellow
    Write-Host "  4. $(T 'endpwrap_undeploy')" -ForegroundColor Red
    Write-Host "  0. $(T 'back_main')" -ForegroundColor Green
    $c = Read-Host "> $(T 'sel_opt')"
    $arch = if ([Environment]::Is64BitProcess) { 'x64' } else { 'x86' }
    switch ($c) {
        "1" {
            if ($arch -ne 'x64') { Write-E "UmWrap 仅 x64"; break }
            $dll = "$env:ProgramFiles\RDP Wrapper\UmWrap.dll"
            if (-not (Test-Path $dll)) {
                if (-not (Test-Admin)) { Write-E "需要管理员"; break }
                Copy-Item (Join-Path (Get-TermWrapBinRoot) "x64\UmWrap.dll") "$env:ProgramFiles\RDP Wrapper\" -Force
            }
            if (Set-TermServiceDll -Path $script:REG_UMRDP_PARAMS -Value '%ProgramFiles%\RDP Wrapper\UmWrap.dll') {
                Restart-RdpService; Write-S "UmWrap $(T 'active')"
            }
        }
        "2" {
            if (Set-TermServiceDll -Path $script:REG_UMRDP_PARAMS -Value '%SystemRoot%\System32\umrdp.dll') {
                Restart-RdpService; Write-S "UmWrap 已停用"
            }
        }
        "3" { if (Enable-TermWrapAudioRecording) { Write-S "EndpWrap $(T 'active')" } }
        "4" {
            try {
                Set-ItemProperty -Path $script:REG_AUDIO_ENUM -Name '(default)' -Value 'rdpendp.dll' -ErrorAction Stop
                Write-S "EndpWrap 已停用（还原 rdpendp.dll）"
            } catch { Write-E "写入失败: $_" }
        }
        "0" { return }
        default { Write-E "$(T 'inv_opt')" }
    }
    Write-Host ""; cmd /c pause 2>&1 | Out-Null
}

function Invoke-InteractiveMenu {
    Select-Language
    do {
        Show-MainMenu
        $choice = Read-Host "> $(T 'sel_opt')"
        $s = Get-TermWrapStatus
        if (-not $s.Installed) {
            switch ($choice) {
                "1" { Invoke-TermWrapInstall }
                "2" { return }
                default { Write-E "$(T 'inv_opt')"; Start-Sleep 1 }
            }
        } else {
            switch ($choice) {
                "1" { Invoke-TermWrapUpdate }
                "2" { Set-RdpSessions }
                "3" { Set-RdpSecurity }
                "4" { Set-RdpShadowing }
                "5" { Set-RdpDisplay }
                "6" { Set-RdpTimeouts }
                "7" { Set-RdpPort }
                "8" {
                    Clear-Host
                    Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
                    $wdStatus = if ($s.Watchdog) { T 'active' } else { T 'inactive' }
                    Write-Host "|  $(T 'wd_title'): $wdStatus" -ForegroundColor Cyan
                    Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
                    Write-Host "|  1. $(T 'wd_reg')" -ForegroundColor Yellow
                    Write-Host "|  2. $(T 'wd_unr')" -ForegroundColor Red
                    Write-Host "|  0. $(T 'back_main')" -ForegroundColor Green
                    Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
                    $wc = Read-Host "> "
                    if ($wc -eq '1') { Register-TermWrapWatchdog }
                    elseif ($wc -eq '2') { Unregister-TermWrapWatchdog }
                    Write-Host ""; cmd /c pause 2>&1 | Out-Null
                }
                "9" { Clear-Host; Restart-RdpService; Write-S $(T 'restart_done'); Write-Host ""; cmd /c pause 2>&1 | Out-Null }
                "u" { Show-UmWrapMenu }
                "U" { Show-UmWrapMenu }
                "d" { Show-RdpRedirectionMenu }
                "D" { Show-RdpRedirectionMenu }
                "r" { New-RemoteAppFile }
                "R" { New-RemoteAppFile }
                "e" { return }
                "E" { return }
                "0" { Invoke-TermWrapUninstall }
                default { Write-E "$(T 'inv_opt')"; Start-Sleep 1 }
            }
        }
    } while ($true)
}

function Show-Help {
    Clear-Host
    Write-Host "termwrap v$($script:VERSION)" -ForegroundColor Cyan
    Write-Host "TermWrap-based RDP multi-session controller (independent branch)."
    Write-Host ""
    Write-Host "USAGE:"
    Write-Host "  .\termwrap.ps1           Interactive menu (live status)"
    Write-Host "  .\termwrap.ps1 -Install  Silent install + watchdog"
    Write-Host "  .\termwrap.ps1 -Uninstall  Clean removal"
    Write-Host "  .\termwrap.ps1 -Help     This help"
}


function Show-ConfigMenu { param($Title,$Items)
    Clear-Host
    Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "| $($Title.PadRight(50))|" -ForegroundColor Cyan
    Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
    $idx = 0
    foreach ($item in $Items) {
        $idx++
        if ($item -is [string]) {
            if ($item -eq '-') { Write-Host "|  $(''.PadRight(48))|" -ForegroundColor DarkGray }
            else { Write-Host "|  $item" -ForegroundColor DarkGray }
        } else {
            $val = if ($null -ne $item.Value) { "[$($item.Value)]" } else { "" }
            $color = if ($item.Color) { $item.Color } else { 'White' }
            Write-Host "|  " -NoNewline; Write-Host "$idx." -NoNewline -ForegroundColor Yellow
            Write-Host " $($item.Label.PadRight(20)) $val" -ForegroundColor $color
        }
    }
    Write-Host "|                                                    |" -ForegroundColor DarkGray
    Write-Host "|  0. $(T 'back_main')                                    |" -ForegroundColor Green
    Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
}
